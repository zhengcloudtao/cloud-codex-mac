import CryptoKit
import Foundation

/// Persist only sanitized counters and an irreversible account fingerprint.
/// This state is separate from the comparison history, so a bad observation
/// can discard its baseline without losing previous estimates.
struct AutomaticWeeklyQuotaSampler: Codable, Equatable {
    static let defaultsKey = "cloudcodex.automaticWeeklyQuotaSampler.v1"
    static let enabledKey = "cloudcodex.automaticWeeklyQuotaSampler.enabled"
    static let interval: TimeInterval = 60
    static let maximumGap: TimeInterval = 15 * 60
    static let minimumPercent = 5.0

    struct Observation: Codable, Equatable {
        let fingerprint: String
        let plan: String
        let usedPercent: Double
        let resetsAt: Double
        let lifetimeTokens: Int64
        let date: Date
        let creditBalance: Decimal?

        init(_ snapshot: WeeklyQuotaComparison.Snapshot) {
            fingerprint = SHA256.hash(data: Data(snapshot.identity.utf8)).map { String(format: "%02x", $0) }.joined()
            plan = snapshot.plan
            usedPercent = snapshot.usedPercent
            resetsAt = snapshot.resetsAt
            lifetimeTokens = snapshot.lifetimeTokens
            date = snapshot.date
            creditBalance = snapshot.creditBalance
        }

        var snapshot: WeeklyQuotaComparison.Snapshot {
            .init(identity: fingerprint, plan: plan, usedPercent: usedPercent, resetsAt: resetsAt,
                  lifetimeTokens: lifetimeTokens, date: date, creditBalance: creditBalance)
        }

        var valid: Bool {
            !plan.isEmpty && usedPercent.isFinite && (0..<100).contains(usedPercent)
                && resetsAt.isFinite && resetsAt > date.timeIntervalSince1970
                && date.timeIntervalSince1970.isFinite && lifetimeTokens >= 0
        }
    }

    enum Phase: String, Codable { case waiting, baseline, collecting, settling, ready, unavailable, retrying }
    private(set) var baseline: Observation?
    private(set) var latest: Observation?
    private(set) var sampleID = UUID()
    private(set) var phase: Phase = .waiting
    private(set) var lastIssue: WeeklyQuotaComparison.ReadIssue?
    private(set) var lastAttempt: Date?
    private(set) var observedLocalTokens: Int64?
    private(set) var tokenSource: WeeklyQuotaComparison.TokenSource?

    var accountTokenDelta: Int64? {
        guard let baseline, let latest else { return nil }
        return max(0, latest.lifetimeTokens - baseline.lifetimeTokens)
    }

    var consumedPercent: Double? {
        guard let baseline, let latest else { return nil }
        return max(0, latest.usedPercent - baseline.usedPercent)
    }

    var status: String {
        switch phase {
        case .waiting: return "等待连接，自动建立采样起点。"
        case .baseline: return "已自动建立起点，正常使用即可，无需手动开始或结束。"
        case .collecting:
            if (consumedPercent ?? 0) >= Self.minimumPercent, accountTokenDelta == 0 {
                return "额度消耗已达标；正在等待本机日志的有效 Token 增量，账号统计总数不作为实时计数器。"
            }
            return "正在累积样本；周额度至少消耗 5 个百分点且观测到 Token 增加后自动计算。"
        case .settling: return "正在对齐本段额度与 Token 用量，取得有效增量后自动计算。"
        case .ready: return "已自动更新对比结果；继续使用会持续更新本段估算。"
        case .unavailable:
            return (lastIssue?.errorDescription ?? "本次采样数据暂不可用。") + " 等待重新建立起点，已有对比记录保留。"
        case .retrying:
            return (lastIssue?.errorDescription ?? "本次读取暂未完成。")
                + (baseline == nil ? " 等待首次有效读数，稍后自动重试。" : " 已保留采样起点，稍后自动重试。")
        }
    }

    mutating func readingFailed(_ issue: WeeklyQuotaComparison.ReadIssue, at date: Date = Date()) {
        if issue.requiresNewBaseline { invalidate() }
        lastIssue = issue
        lastAttempt = date
        phase = issue.requiresNewBaseline ? .unavailable : .retrying
    }

    mutating func invalidate() {
        baseline = nil
        latest = nil
        phase = .unavailable
        sampleID = UUID()
        lastIssue = nil
        observedLocalTokens = nil
        tokenSource = nil
    }

    mutating func reset() {
        invalidate()
        phase = .waiting
    }

    mutating func record(_ snapshot: WeeklyQuotaComparison.Snapshot, localTokens: Int64? = nil, costReport: CodexAPIUsagePricing.Report? = nil) -> WeeklyQuotaComparison.Sample? {
        let current = Observation(snapshot)
        guard current.valid else { invalidate(); return nil }
        // Never let a late, duplicated RPC overwrite a newer observation.
        if let latest, current.date <= latest.date { return nil }
        lastAttempt = snapshot.date
        lastIssue = nil
        guard let start = baseline, let previous = latest,
              current.fingerprint == previous.fingerprint, CodexPlanName.displayName(current.plan) == CodexPlanName.displayName(previous.plan),
              abs(current.resetsAt - previous.resetsAt) <= 1,
              current.date.timeIntervalSince(previous.date) <= Self.maximumGap,
              current.usedPercent >= previous.usedPercent,
              current.lifetimeTokens >= previous.lifetimeTokens,
              !(current.creditBalance.flatMap { end in previous.creditBalance.map { end < $0 } } ?? false) else {
            baseline = current
            latest = current
            sampleID = UUID()
            tokenSource = nil
            observedLocalTokens = nil
            phase = .baseline
            return nil
        }
        latest = current
        observedLocalTokens = localTokens
        let accountDelta = current.lifetimeTokens - start.lifetimeTokens
        let useLocal = !snapshot.accountTokensAvailable || tokenSource == .localLogs || accountDelta == 0
        let measuredTokens = useLocal ? (localTokens ?? 0) : accountDelta
        guard current.usedPercent - start.usedPercent >= Self.minimumPercent,
              measuredTokens > 0,
              current.date.timeIntervalSince(start.date) >= Self.interval else {
            phase = .collecting
            return nil
        }
        guard var sample = try? WeeklyQuotaComparison.Sample.make(plan: current.plan,
            percent: current.usedPercent - start.usedPercent, tokens: Double(measuredTokens), dollars: useLocal && costReport?.complete == true ? costReport?.knownDollars : nil, monthlyPrice: nil) else {
            invalidate()
            return nil
        }
        sample.id = sampleID
        sample.date = current.date
        sample.automatic = true
        tokenSource = useLocal ? .localLogs : .account
        sample.tokenSource = tokenSource
        sample.costReport = useLocal ? costReport : nil
        phase = .ready
        return sample
    }

    static func load(_ defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.baseline.map({ $0.valid }) ?? true,
              value.latest.map({ $0.valid }) ?? true else { return Self() }
        return value
    }
}
