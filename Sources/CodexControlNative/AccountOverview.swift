import Foundation
import SwiftUI

struct AccountOverview {
    struct WeeklyUsageRecommendation: Equatable {
        let title: String
        let value: String
        let detail: String
    }

    let plan: String
    let usage: RemoteUsageSnapshot
    let subscriptionPeriodEnd: Date?

    // Matches the installed official client's personal.pro/proLite tier labels.
    var planDisplayName: String {
        switch plan.lowercased() {
        case "pro": return "Pro 20×"
        case "prolite": return "Pro 5×"
        case "plus": return "Plus"
        case "free": return "Free"
        case "未提供", "unknown": return "套餐未提供"
        default: return plan
        }
    }

    static func parse(_ json: [String: Any], subscriptionPeriodEnd: Date? = nil) -> Self {
        let legacy = json["rateLimits"] as? [String: Any]
        let buckets = json["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        let plan = legacy?["planType"] as? String
            ?? buckets["codex"]?["planType"] as? String
            ?? buckets.keys.sorted().compactMap { buckets[$0]?["planType"] as? String }.first
            ?? "未提供"
        return .init(plan: plan, usage: .parse(json), subscriptionPeriodEnd: subscriptionPeriodEnd)
    }

    static func remaining(_ window: RemoteUsageSnapshot.Window?) -> String {
        guard let used = window?.usedPercent else { return "未提供" }
        return "\(Int(max(0, min(100, 100 - used))))%"
    }

    var primaryBucket: RemoteUsageSnapshot.Bucket? {
        usage.buckets.first(where: { $0.id == "codex" }) ?? usage.buckets.first
    }

    func remaining(minutes: Int) -> String {
        Self.remaining(primaryBucket?.windows.first(where: { $0.windowDurationMins == minutes }))
    }

    func compactRemaining(minutes: Int) -> String? {
        let value = remaining(minutes: minutes)
        return value == "未提供" ? nil : value
    }

    var compactResetCredits: String? {
        usage.resetCredits?.availableCount.map { "\($0) 次" }
    }

    func weeklyUsageRecommendation(now: Date = Date()) -> WeeklyUsageRecommendation? {
        guard let window = primaryBucket?.windows.first(where: { $0.windowDurationMins == 10_080 }),
              let used = window.usedPercent,
              let resetsAt = window.resetsAt,
              used.isFinite,
              resetsAt.isFinite else { return nil }

        let secondsRemaining = resetsAt - now.timeIntervalSince1970
        guard secondsRemaining > 0 else { return nil }

        let remaining = max(0, min(100, 100 - used))
        let isDueWithinOneDay = secondsRemaining <= 24 * 60 * 60
        let recommended = isDueWithinOneDay
            ? remaining
            : min(remaining, remaining * 24 * 60 * 60 / secondsRemaining)
        let value = Self.percentageLabel(recommended)
        let remainingLabel = Self.percentageLabel(remaining)

        if isDueWithinOneDay {
            return .init(
                title: "重置前建议",
                value: value,
                detail: remaining > 0
                    ? "距每周重置不足 24 小时。建议在重置前使用剩余 \(remainingLabel)，否则该部分额度会未使用。"
                    : "本周额度已经用完，等待下一次每周重置。"
            )
        }
        return .init(
            title: "24小时建议",
            value: value,
            detail: remaining > 0
                ? "按当前剩余 \(remainingLabel) 和每周重置时间计算，接下来 24 小时建议至少使用 \(value)。低于这个进度，之后需要加快使用才能在重置前用完。"
                : "本周额度已经用完，等待下一次每周重置。"
        )
    }

    private static func percentageLabel(_ value: Double) -> String {
        let roundedUp = ceil(max(0, min(100, value)) * 10) / 10
        if roundedUp.rounded() == roundedUp {
            return "\(Int(roundedUp))%"
        }
        return String(format: "%.1f%%", roundedUp)
    }
}

struct AccountOverviewRefreshIssue: Equatable {
    let title: String
    let message: String

    static func parse(_ rawError: String) -> Self {
        let error = rawError.lowercased()
        if error.contains("token_revoked")
            || error.contains("invalidated oauth token")
            || error.contains("authentication token is invalid") {
            return .init(
                title: "Codex 登录已失效",
                message: "当前显示的是上次获取的数据。请在 Codex 中重新登录，然后返回此处刷新。"
            )
        }
        if error.contains("timed out")
            || error.contains("timeout")
            || error.contains("network")
            || error.contains("connection") {
            return .init(
                title: "暂时无法刷新",
                message: "当前显示的是上次获取的数据。请检查网络连接后重试。"
            )
        }
        return .init(
            title: "套餐信息刷新失败",
            message: "当前显示的是上次获取的数据，请稍后重试。"
        )
    }
}

struct AccountOverviewView: View {
    @EnvironmentObject private var model: AppModel
    @State private var expanded = false

    var body: some View {
        Button { expanded.toggle() } label: {
            if let account = model.accountOverview {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    HStack(spacing: 12) {
                        Text(account.planDisplayName)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                        if let value = account.compactRemaining(minutes: 300) {
                            quotaColumn("5小时剩余", value: value)
                        }
                        if let value = account.compactRemaining(minutes: 10_080) {
                            quotaColumn("每周剩余", value: value)
                        }
                        if let recommendation = account.weeklyUsageRecommendation(now: context.date) {
                            quotaColumn(recommendation.title, value: recommendation.value, help: recommendation.detail)
                        }
                        if let value = account.compactResetCredits {
                            quotaColumn("可用重置", value: value)
                        }
                        Image(systemName: model.accountOverviewError == nil ? "chevron.down" : "exclamationmark.circle")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(model.accountOverviewError == nil ? Color.secondary : Color.orange)
                            // Keep the compact glyph, but give the toolbar edge a
                            // full-sized hit target instead of only the drawn pixels.
                            .frame(width: 32, height: 30)
                            .contentShape(Rectangle())
                    }
                    .lineLimit(1)
                    .contentShape(Rectangle())
                    // The toolbar supplies its own rounded container. Adding another
                    // background and stroke here produces two overlapping outlines.
                }
            } else {
                Label("套餐与额度", systemImage: "chart.bar")
            }
        }
        .buttonStyle(.plain)
        .help("查看套餐、额度及每次重置的到期时间")
        .popover(isPresented: $expanded) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("套餐与额度").font(.headline)
                    Spacer()
                    Button("刷新") { Task { await model.connectionHealth.check() } }
                        .disabled(model.connectionHealth.isChecking)
                }
                if let account = model.accountOverview {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("订阅套餐：\(account.planDisplayName)").fontWeight(.semibold)
                            Text(subscriptionPeriodLabel(account.subscriptionPeriodEnd))
                                .foregroundStyle(.secondary)
                            Divider()
                            ForEach(account.usage.buckets, id: \.id) { bucket in
                                Text(bucket.name).fontWeight(.semibold)
                                ForEach(Array(bucket.windows.enumerated()), id: \.offset) { _, window in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("\(windowName(window.windowDurationMins)) · 剩余 \(AccountOverview.remaining(window))")
                                        Text("恢复时间：\(dateLabel(window.resetsAt))").foregroundStyle(.secondary)
                                    }
                                }
                            }
                            if account.usage.buckets.isEmpty { Text("当前账号未提供额度窗口。") }
                            if let recommendation = account.weeklyUsageRecommendation() {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("\(recommendation.title)：\(recommendation.value)")
                                        .fontWeight(.semibold)
                                    Text(recommendation.detail)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            Divider()
                            Text("可用重置次数：\(account.usage.resetCredits?.availableCount.map(String.init) ?? "未提供")")
                                .fontWeight(.semibold)
                            if let expirations = account.usage.resetCredits?.expirations {
                                ForEach(Array(expirations.enumerated()), id: \.offset) { index, expiry in
                                    Text("第 \(index + 1) 次 · 到期：\(dateLabel(expiry))")
                                }
                                if expirations.isEmpty { Text("接口没有返回可用重置到期明细。") }
                                if let count = account.usage.resetCredits?.availableCount, count > expirations.count {
                                    Text("还有 \(count - expirations.count) 次未提供到期明细。")
                                }
                            } else {
                                Text("重置到期明细：接口未提供。")
                            }
                            Divider()
                            Text("更新于 \(dateLabel(account.usage.capturedAt)) · 时间按本机时区显示")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("此处只展示账号信息，不执行重置。多个额度窗口按接口返回分别列出。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                } else { Text("尚未读取到套餐或额度，请检查本机 Codex 登录和连接状态。") }
                if let error = model.accountOverviewError {
                    refreshIssueBanner(AccountOverviewRefreshIssue.parse(error))
                }
            }
            .padding(20)
            .frame(width: 460, height: 520)
        }
    }

    private func dateLabel(_ timestamp: Double?) -> String {
        guard let timestamp, timestamp.isFinite else { return "未提供" }
        return Date(timeIntervalSince1970: timestamp).formatted(date: .numeric, time: .shortened)
    }

    private func subscriptionPeriodLabel(_ date: Date?) -> String {
        guard let date else {
            return "套餐到期：本机登录信息未提供，不能用额度恢复时间代替。"
        }
        let value = date.formatted(date: .numeric, time: .shortened)
        return date <= Date() ? "套餐已于 \(value) 到期" : "套餐到期：\(value)"
    }

    private func refreshIssueBanner(_ issue: AccountOverviewRefreshIssue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.orange.opacity(0.24), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private func quotaColumn(_ title: String, value: String, help: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(minWidth: 48, alignment: .leading)
        .help(help ?? title + "：" + value)
    }

    private func windowName(_ minutes: Int?) -> String {
        switch minutes {
        case 300: return "5 小时额度"
        case 10_080: return "每周额度"
        case .some(let value): return "\(value) 分钟额度"
        case nil: return "额度窗口（周期未提供）"
        }
    }
}
