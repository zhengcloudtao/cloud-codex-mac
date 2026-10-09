import Foundation
import SwiftUI

struct AccountOverview {
    struct WeeklyPaceStatus: Equatable {
        enum State: Equatable { case ahead, onTrack, behind }

        let state: State
        let compactLabel: String
        let label: String
        let detail: String
    }

    struct WeeklyUsageRecommendation: Equatable {
        let title: String
        let value: String
        let detail: String
    }

    let plan: String
    let usage: RemoteUsageSnapshot
    let subscriptionPeriodEnd: Date?
    var creditBalance: CreditBalance? = nil

    struct CreditBalance: Equatable {
        let balance: String?
        let unlimited: Bool

        var decimalBalance: Decimal? {
            guard let balance,
                  let value = Decimal(string: balance, locale: Locale(identifier: "en_US_POSIX")),
                  !value.isNaN, value >= 0 else { return nil }
            return value
        }

        var displayValue: String {
            if unlimited { return "无限额" }
            guard let value = decimalBalance else { return "未提供" }
            let formatter = NumberFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 1
            formatter.maximumFractionDigits = 1
            formatter.roundingMode = .halfUp
            return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "未提供"
        }
    }

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
        let credits = buckets["codex"]?["credits"] as? [String: Any]
            ?? legacy?["credits"] as? [String: Any]
        let creditBalance = credits.map {
            CreditBalance(balance: $0["balance"] as? String, unlimited: $0["unlimited"] as? Bool ?? false)
        }
        return .init(plan: plan, usage: .parse(json), subscriptionPeriodEnd: subscriptionPeriodEnd,
                     creditBalance: creditBalance)
    }

    static func remaining(_ window: RemoteUsageSnapshot.Window?) -> String {
        guard let used = window?.usedPercent else { return "未提供" }
        return String(format: "%.2f%%", max(0, min(100, 100 - used)))
    }

    var primaryBucket: RemoteUsageSnapshot.Bucket? {
        usage.buckets.first(where: { $0.id == "codex" }) ?? usage.buckets.first
    }

    var weeklyUsageWindow: RemoteUsageSnapshot.Window? {
        primaryBucket?.windows.first(where: { $0.windowDurationMins == 10_080 })
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
        guard let window = weeklyUsageWindow,
              let used = window.usedPercent,
              let resetsAt = window.resetsAt,
              let windowDurationMins = window.windowDurationMins,
              windowDurationMins > 0,
              used.isFinite,
              resetsAt.isFinite else { return nil }

        let secondsRemaining = resetsAt - now.timeIntervalSince1970
        guard secondsRemaining > 0 else { return nil }

        let remaining = max(0, min(100, 100 - used))
        let isDueWithinOneDay = secondsRemaining <= 24 * 60 * 60
        let weeklyBaseline = Double(100 * 24 * 60) / Double(windowDurationMins)
        let resetCatchUp = remaining * 24 * 60 * 60 / secondsRemaining
        let recommended = isDueWithinOneDay
            ? remaining
            : min(remaining, max(weeklyBaseline, resetCatchUp))
        let value = Self.percentageLabel(recommended)
        let remainingLabel = Self.percentageLabel(remaining)
        let baselineLabel = Self.percentageLabel(weeklyBaseline)

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
                ? "每周总额度按 7 天计算，基础保底速度为 \(baselineLabel)/24小时；同时根据当前剩余 \(remainingLabel) 和重置时间计算追赶速度，采用两者中更高的 \(value)，降低额度提前重置时未使用完的风险。"
                : "本周额度已经用完，等待下一次每周重置。"
        )
    }

    func weeklyPaceStatus(now: Date = Date()) -> WeeklyPaceStatus? {
        guard let window = weeklyUsageWindow,
              let used = window.usedPercent,
              let resetsAt = window.resetsAt,
              let durationMinutes = window.windowDurationMins,
              durationMinutes > 0,
              used.isFinite,
              resetsAt.isFinite else { return nil }

        let durationSeconds = Double(durationMinutes * 60)
        let secondsRemaining = resetsAt - now.timeIntervalSince1970
        guard secondsRemaining > 0, secondsRemaining <= durationSeconds else { return nil }

        let actualRemaining = max(0, min(100, 100 - used))
        let expectedRemaining = max(0, min(100, secondsRemaining / durationSeconds * 100))
        let difference = actualRemaining - expectedRemaining
        let actualLabel = Self.percentageLabel(actualRemaining)
        let expectedLabel = Self.percentageLabel(expectedRemaining)

        if difference > 0.5 {
            let gap = Self.percentageLabel(difference)
            return .init(
                state: .behind,
                compactLabel: "追赶",
                label: "需追赶 \(gap)",
                detail: "当前剩余 \(actualLabel)，按本周已过去的时间，理想剩余约 \(expectedLabel)。当前少用了 \(gap)。"
            )
        }
        if difference < -0.5 {
            let lead = Self.percentageLabel(-difference)
            return .init(
                state: .ahead,
                compactLabel: "超前",
                label: "已超前 \(lead)",
                detail: "当前剩余 \(actualLabel)，按本周已过去的时间，理想剩余约 \(expectedLabel)。当前已多使用 \(lead)，进度处于超前状态。"
            )
        }
        return .init(
            state: .onTrack,
            compactLabel: "正常",
            label: "进度正常",
            detail: "当前剩余 \(actualLabel)，与按本周已过去时间计算的理想剩余 \(expectedLabel) 基本一致。"
        )
    }

    private static func percentageLabel(_ value: Double) -> String {
        let roundedUp = ceil(max(0, min(100, value)) * 10) / 10
        if roundedUp.rounded() == roundedUp {
            return "\(Int(roundedUp))%"
        }
        return String(format: "%.1f%%", roundedUp)
    }

    static func consumptionRateLabel(_ value: Double) -> String {
        String(format: "%.1f%%/30分钟", max(0, min(100, value)))
    }

    static func compactConsumptionRateLabel(_ value: Double) -> String {
        String(format: "%.1f%%", max(0, min(100, value)))
    }

    static func quotaResetCountdown(resetsAt: Double?, now: Date = Date()) -> String? {
        guard let resetsAt, resetsAt.isFinite else { return nil }

        let secondsRemaining = resetsAt - now.timeIntervalSince1970
        guard secondsRemaining > 0 else { return "已到恢复时间，等待额度刷新" }

        let totalMinutes = Int(ceil(secondsRemaining / 60))
        let days = totalMinutes / (24 * 60)
        let hours = totalMinutes % (24 * 60) / 60
        let minutes = totalMinutes % 60

        var components: [String] = []
        if days > 0 { components.append("\(days)天") }
        if days > 0 || hours > 0 { components.append("\(hours)小时") }
        components.append("\(minutes)分钟")
        return "还有 \(components.joined(separator: " "))恢复"
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

struct ResetCreditUsePresentation: Equatable {
    let message: String
    let isError: Bool

    static func outcome(_ value: String) -> Self {
        switch value {
        case "reset":
            return .init(message: "重置成功，额度信息已刷新。", isError: false)
        case "alreadyRedeemed":
            return .init(message: "这次重置已经使用，额度信息已刷新。", isError: false)
        case "nothingToReset":
            return .init(message: "当前额度无需重置，Codex 没有执行重置。", isError: true)
        case "noCredit":
            return .init(message: "这次重置已不可用，请刷新后选择其他次数。", isError: true)
        case "expired":
            return .init(message: "这次重置已经过期，请刷新额度信息。", isError: true)
        default:
            return .init(message: "无法使用这次重置，请刷新后重试。", isError: true)
        }
    }

    static func unavailableReason(
        for credit: RemoteUsageSnapshot.ResetCredit,
        now: Date = Date()
    ) -> String? {
        guard credit.resetType == "codexRateLimits" else { return "这条记录不能重置 Codex 额度" }
        guard let expiresAt = credit.expiresAt, expiresAt.isFinite else { return "接口未提供截止时间" }
        guard expiresAt > now.timeIntervalSince1970 else { return "这条记录已经过期" }
        return nil
    }
}

struct AccountOverviewView: View {
    @EnvironmentObject private var model: AppModel
    @State private var expanded = false
    @State private var pendingResetCredit: RemoteUsageSnapshot.ResetCredit?

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
                            if let pace = account.weeklyPaceStatus(now: context.date) {
                                quotaColumn(
                                    "每周剩余",
                                    value: value,
                                    status: pace.compactLabel,
                                    help: pace.detail,
                                    valueColor: paceColor(pace.state)
                                )
                                .layoutPriority(2)
                            } else {
                                quotaColumn("每周剩余", value: value)
                            }
                        }
                        if account.weeklyUsageWindow?.usedPercent != nil {
                            if let rate = model.recentThirtyMinuteConsumptionRate {
                                quotaColumn(
                                    "30分钟消耗",
                                    value: AccountOverview.compactConsumptionRateLabel(rate),
                                    help: "最近 30 分钟消耗了每周总额度的 \(AccountOverview.consumptionRateLabel(rate))。"
                                )
                            } else {
                                quotaColumn("30分钟消耗", value: "采集中", help: "需要连续采集满 30 分钟后显示。")
                            }
                        }
                        if let value = account.compactResetCredits {
                            quotaColumn("可用重置", value: value)
                        }
                        if let credits = account.creditBalance {
                            quotaColumn("剩余额度", value: credits.displayValue, help: "当前额度余额")
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
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        VStack(alignment: .leading, spacing: 12) {
                                Text("订阅套餐：\(account.planDisplayName)").fontWeight(.semibold)
                                Divider()
                                if let credits = account.creditBalance {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("剩余额度：\(credits.displayValue)").fontWeight(.semibold)
                                        Text("当前余额").foregroundStyle(.secondary)
                                    }
                                    Divider()
                                }
                                ForEach(account.usage.buckets, id: \.id) { bucket in
                                    Text(bucket.name).fontWeight(.semibold)
                                    ForEach(Array(bucket.windows.enumerated()), id: \.offset) { _, window in
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("\(windowName(window.windowDurationMins)) · 剩余 \(AccountOverview.remaining(window))")
                                            Text("恢复时间：\(dateLabel(window.resetsAt))").foregroundStyle(.secondary)
                                            if let countdown = AccountOverview.quotaResetCountdown(
                                                resetsAt: window.resetsAt,
                                                now: context.date
                                            ) {
                                                Text(countdown)
                                                    .font(.caption.weight(.medium))
                                                    .foregroundStyle(.secondary)
                                                    .monospacedDigit()
                                            }
                                        }
                                    }
                                }
                                if account.usage.buckets.isEmpty { Text("当前账号未提供额度窗口。") }
                                if let pace = account.weeklyPaceStatus(now: context.date) {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text("每周使用进度：\(pace.label)")
                                            .fontWeight(.semibold)
                                            .foregroundStyle(paceColor(pace.state))
                                        Text(pace.detail)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(paceColor(pace.state).opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                if account.weeklyUsageWindow?.usedPercent != nil {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("最近 30 分钟消耗速度")
                                            .fontWeight(.semibold)
                                        if let rate = model.recentThirtyMinuteConsumptionRate {
                                            Text(AccountOverview.consumptionRateLabel(rate))
                                                .font(.title3.weight(.semibold))
                                                .monospacedDigit()
                                            Text("表示最近 30 分钟消耗的每周总额度百分比；额度恢复或重置后会重新采集。")
                                                .foregroundStyle(.secondary)
                                        } else {
                                            Text("正在采集，需要连续获得满 30 分钟的额度数据。")
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                Divider()
                                Text("可用重置次数：\(account.usage.resetCredits?.availableCount.map(String.init) ?? "未提供")")
                                    .fontWeight(.semibold)
                                if let credits = account.usage.resetCredits?.credits {
                                    ForEach(Array(credits.enumerated()), id: \.element.ref) { index, credit in
                                        HStack(spacing: 12) {
                                            Text("第 \(index + 1) 次 · 到期：\(dateLabel(credit.expiresAt))")
                                            Spacer(minLength: 8)
                                            if model.resetCreditInProgressRef == credit.ref {
                                                ProgressView()
                                                    .controlSize(.small)
                                                    .frame(width: 78, height: 28)
                                            } else {
                                                Button {
                                                    pendingResetCredit = credit
                                                } label: {
                                                    Label("使用", systemImage: "arrow.clockwise")
                                                        .font(.caption.weight(.semibold))
                                                        .frame(width: 58)
                                                }
                                                .buttonStyle(.bordered)
                                                .buttonBorderShape(.roundedRectangle(radius: 7))
                                                .controlSize(.regular)
                                                .tint(.accentColor)
                                                .disabled(
                                                    model.resetCreditInProgressRef != nil
                                                        || ResetCreditUsePresentation.unavailableReason(for: credit) != nil
                                                )
                                                .help(ResetCreditUsePresentation.unavailableReason(for: credit) ?? "使用这次额度重置")
                                            }
                                        }
                                        .padding(.trailing, 12)
                                    }
                                    if credits.isEmpty { Text("接口没有返回可选择的重置明细。") }
                                    if let count = account.usage.resetCredits?.availableCount, count > credits.count {
                                        Text("还有 \(count - credits.count) 次缺少可安全使用的明细。")
                                    }
                                } else {
                                    Text("重置明细：接口未提供，不能执行重置。")
                                }
                                if let message = model.resetCreditStatusMessage {
                                    Text(message)
                                        .font(.caption)
                                        .foregroundStyle(model.resetCreditStatusIsError ? Color.orange : Color.green)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Divider()
                                Text("更新于 \(dateLabel(account.usage.capturedAt)) · 时间按本机时区显示")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("使用重置前会再次确认；多个额度窗口按接口返回分别列出。")
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
            .frame(width: 460)
            .fixedSize(horizontal: false, vertical: true)
        }
        .alert(
            "确认使用重置次数？",
            isPresented: Binding(
                get: { pendingResetCredit != nil },
                set: { if !$0 { pendingResetCredit = nil } }
            ),
            presenting: pendingResetCredit
        ) { credit in
            Button("确认使用", role: .destructive) {
                pendingResetCredit = nil
                Task { await model.consumeResetCredit(credit) }
            }
            Button("取消", role: .cancel) { pendingResetCredit = nil }
        } message: { credit in
            Text("将使用截止时间为 \(dateLabel(credit.expiresAt)) 的这次重置。此操作会立即修改当前 Codex 额度，且不能撤销。")
        }
    }

    private func dateLabel(_ timestamp: Double?) -> String {
        guard let timestamp, timestamp.isFinite else { return "未提供" }
        return Date(timeIntervalSince1970: timestamp).formatted(date: .numeric, time: .shortened)
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

    private func quotaColumn(
        _ title: String,
        value: String,
        status: String? = nil,
        help: String? = nil,
        valueColor: Color = .primary
    ) -> some View {
        let fallbackHelp = title + "：" + value + (status.map { " · \($0)" } ?? "")
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            CompactQuotaValue(value: value, status: status, color: valueColor)
        }
        .frame(minWidth: 48, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .help(help ?? fallbackHelp)
    }

    private func paceColor(_ state: AccountOverview.WeeklyPaceStatus.State) -> Color {
        switch state {
        case .ahead: return .green
        case .onTrack: return .blue
        case .behind: return .orange
        }
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

private struct CompactQuotaValue: View {
    let value: String
    let status: String?
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
                .fixedSize(horizontal: true, vertical: false)
            if let status {
                Text(status)
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(color.opacity(0.12), in: Capsule())
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
