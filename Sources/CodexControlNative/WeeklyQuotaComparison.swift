import Foundation

/// Only comparison measurements are saved. Account identity stays in the in-memory baseline.
struct WeeklyQuotaComparison: Codable, Equatable {
    static let defaultsKey = "cloudcodex.weeklyQuotaComparison.v1"
    enum TokenSource: String, Codable { case account, localLogs }

    enum ReadIssue: String, Codable, LocalizedError {
        case accountMissing, accountChanged, planChanged, quotaMissing, quotaChanging
        case quotaExhausted, resetExpired, tokensMissing, timeout, connection, authentication, response, storage
        case accountTimeout, quotaTimeout, usageTimeout, startupTimeout

        var errorDescription: String? {
            switch self {
            case .accountMissing: return "账号接口暂未返回可识别的 ChatGPT 账号。"
            case .accountChanged: return "读取期间账号发生变化，需要重新建立采样起点。"
            case .planChanged: return "读取期间套餐发生变化，需要重新建立采样起点。"
            case .quotaMissing: return "额度接口暂未返回完整的每周额度。"
            case .quotaChanging: return "读取期间周额度正在变化，本次读数暂不采用。"
            case .quotaExhausted: return "每周额度已耗尽，等待额度恢复后重新采样。"
            case .resetExpired: return "当前周额度的重置时间已到，等待新的额度窗口。"
            case .tokensMissing: return "使用统计接口暂未返回累计 Token。"
            case .timeout: return "采样接口响应超时。"
            case .accountTimeout: return "账号信息读取超时。"
            case .quotaTimeout: return "周额度读取超时。"
            case .usageTimeout: return "累计 Token 用量读取超时。"
            case .startupTimeout: return "采样专用本地服务启动超时。"
            case .connection: return "本机 Codex 服务暂未连接。"
            case .authentication: return "Codex 登录已失效，请重新登录后重试。"
            case .response: return "采样接口暂时无法返回可用数据。"
            case .storage: return "本次采样结果暂时无法保存。"
            }
        }

        var requiresNewBaseline: Bool {
            [.accountChanged, .planChanged, .quotaExhausted, .resetExpired, .authentication].contains(self)
        }

        static func classify(_ error: Error) -> Self {
            if let issue = error as? Self { return issue }
            if let error = error as? CodexClientError {
                switch error {
                case .timeout(let method):
                    switch method {
                    case "account/read": return .accountTimeout
                    case "account/rateLimits/read": return .quotaTimeout
                    case "account/usage/read": return .usageTimeout
                    case "initialize": return .startupTimeout
                    default: return .timeout
                    }
                case .notRunning, .binaryNotFound, .process: return .connection
                default: break
                }
            }
            let failure = RemoteConnectionHealthSnapshot.failureKind(for: error.localizedDescription)
            if failure == "auth" { return .authentication }
            if failure == "timeout" { return .timeout }
            return .response
        }
    }

    struct Sample: Codable, Equatable, Identifiable {
        var id = UUID()
        var date = Date()
        let plan: String
        let percent: Double
        let tokens: Double?
        var dollars: Double?
        let monthlyPrice: Double?
        var automatic: Bool? = nil
        var tokenSource: TokenSource? = nil
        var costReport: CodexAPIUsagePricing.Report? = nil

        var weeklyTokens: Double? { tokens.map { $0 * 100 / percent } }
        var weeklyDollars: Double? {
            guard costReport?.lines.contains(where: \.assumedSpeed) != true else { return nil }
            return dollars.map { $0 * 100 / percent }
        }
        var tokensPerDollar: Double? {
            guard let weeklyTokens, let monthlyPrice else { return nil }
            return weeklyTokens * (365.2425 / 12 / 7) / monthlyPrice
        }

        static func make(plan: String, percent: Double, tokens: Double?, dollars: Double?, monthlyPrice: Double?) throws -> Self {
            guard !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  percent.isFinite, percent >= 1, percent <= 100,
                  tokens != nil || dollars != nil,
                  [tokens, dollars, monthlyPrice].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 > 0 }),
                  [tokens, dollars].compactMap({ $0 }).allSatisfy({ ($0 * 100 / percent).isFinite }) else {
                throw MeasurementError("请填写套餐名称、1–100 个百分点的消耗量，以及正数 Token 或美元费用；可选月费也必须为正数。")
            }
            return .init(plan: String(plan.prefix(100)), percent: percent, tokens: tokens,
                         dollars: dollars, monthlyPrice: monthlyPrice)
        }
    }

    struct Snapshot {
        let identity: String
        let plan: String
        let usedPercent: Double
        let resetsAt: Double
        let lifetimeTokens: Int64
        let date: Date
        let creditBalance: Decimal?
        var accountTokensAvailable = true

        func sample(to end: Self) throws -> Sample {
            guard identity == end.identity, plan == end.plan,
                  abs(resetsAt - end.resetsAt) <= 1,
                  end.date > date, end.date.timeIntervalSince1970 < resetsAt,
                  usedPercent >= 0, end.usedPercent < 100,
                  end.usedPercent >= usedPercent,
                  end.lifetimeTokens > lifetimeTokens else {
                throw MeasurementError("账号、套餐或重置周期已变化，额度已恢复/耗尽，或 Token 尚未增加。请重新读取起点；统计可能存在延迟。")
            }
            if let startBalance = creditBalance, let endBalance = end.creditBalance, endBalance < startBalance {
                throw MeasurementError("采样期间额外额度余额下降，请重新采样，避免将额外付费用量计入套餐。")
            }
            return try Sample.make(plan: plan, percent: end.usedPercent - usedPercent,
                                   tokens: Double(end.lifetimeTokens) - Double(lifetimeTokens),
                                   dollars: nil, monthlyPrice: nil)
        }
    }

    static func parseSnapshot(startAccount: [String: Any], before: AccountOverview,
                              usage: [String: Any], after: AccountOverview,
                              endAccount: [String: Any], now: Date = Date(), fallbackLifetimeTokens: Int64? = nil) throws -> Snapshot {
        func accountIdentity(_ json: [String: Any]) -> String? {
            guard let account = json["account"] as? [String: Any],
                  account["type"] as? String == "chatgpt",
                  let email = account["email"] as? String, !email.isEmpty else { return nil }
            return email
        }
        let insights = CodexUsageInsights.parse(account: endAccount, usage: usage)
        guard let identity = accountIdentity(startAccount), accountIdentity(endAccount) != nil else {
            throw WeeklyQuotaComparison.ReadIssue.accountMissing
        }
        guard identity == accountIdentity(endAccount) else { throw WeeklyQuotaComparison.ReadIssue.accountChanged }
        // The fresh quota response owns the plan; account/read may cache an older tier.
        guard before.plan == after.plan else { throw WeeklyQuotaComparison.ReadIssue.planChanged }
        guard let window = after.weeklyUsageWindow, let beforeWindow = before.weeklyUsageWindow,
              let used = window.usedPercent, used.isFinite,
              let reset = window.resetsAt, reset.isFinite else { throw WeeklyQuotaComparison.ReadIssue.quotaMissing }
        guard used < 100 else { throw WeeklyQuotaComparison.ReadIssue.quotaExhausted }
        guard reset > now.timeIntervalSince1970 else { throw WeeklyQuotaComparison.ReadIssue.resetExpired }
        let resetTolerance: Double = used == 0 ? 60 : 1
        guard beforeWindow.usedPercent == used, let beforeReset = beforeWindow.resetsAt,
              abs(beforeReset - reset) <= resetTolerance else { throw WeeklyQuotaComparison.ReadIssue.quotaChanging }
        guard let tokens = insights.summary.lifetimeTokens ?? fallbackLifetimeTokens, tokens >= 0 else {
            throw WeeklyQuotaComparison.ReadIssue.tokensMissing
        }
        var snapshot = Snapshot(identity: identity, plan: after.planDisplayName, usedPercent: used,
                     resetsAt: reset, lifetimeTokens: tokens, date: now,
                     creditBalance: after.creditBalance?.decimalBalance)
        snapshot.accountTokensAvailable = insights.summary.lifetimeTokens != nil
        return snapshot
    }

    struct MeasurementError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    var samples: [Sample] = []

    static func load(_ defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        let samples = value.samples.map { original in
            var sample = original
            if sample.costReport?.lines.contains(where: \.assumedSpeed) == true { sample.dollars = nil }
            return sample
        }
        return .init(samples: samples.filter {
            (try? Sample.make(plan: $0.plan, percent: $0.percent, tokens: $0.tokens,
                              dollars: $0.dollars, monthlyPrice: $0.monthlyPrice)) != nil
        })
    }
}
