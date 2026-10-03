import SwiftUI

struct CodexUsageInsights: Equatable {
    struct Identity: Equatable {
        let profileID: String?
        let name: String?
        let email: String?
        let username: String?
        let avatarURL: URL?
        let plan: String?

        var displayName: String {
            if let name, !name.isEmpty { return name }
            guard let email, !email.isEmpty else { return "Codex 用户" }
            return email.split(separator: "@").first.map(String.init) ?? email
        }

        var secondaryLabel: String {
            username.map { "@\($0)" } ?? email ?? "当前 Codex 账号"
        }

        var planDisplayName: String? {
            guard let plan else { return nil }
            switch plan.lowercased() {
            case "pro", "prolite": return "Pro"
            case "plus": return "Plus"
            case "free": return "Free"
            case "unknown": return nil
            default: return plan
            }
        }
    }

    struct Summary: Equatable {
        let lifetimeTokens: Int64?
        let peakDailyTokens: Int64?
        let longestRunningTurnSeconds: Int64?
        let currentStreakDays: Int64?
        let longestStreakDays: Int64?
    }

    struct DailyBucket: Equatable, Identifiable {
        let date: Date
        let tokens: Int64
        var id: Date { date }
    }

    let identity: Identity
    let summary: Summary
    let dailyBuckets: [DailyBucket]

    static func parse(
        account: [String: Any],
        usage: [String: Any],
        profile: CodexProfileReader.Profile? = nil,
        displayNameOverride: String? = nil,
        calendar: Calendar = .current
    ) -> Self {
        let accountValue = account["account"] as? [String: Any]
        let identity = Identity(
            profileID: profile?.id,
            name: displayNameOverride ?? profile?.name,
            email: profile?.email ?? accountValue?["email"] as? String,
            username: profile?.username,
            avatarURL: profile?.avatarURL,
            plan: accountValue?["planType"] as? String
        )
        let summaryValue = usage["summary"] as? [String: Any] ?? [:]
        let summary = Summary(
            lifetimeTokens: integer(summaryValue["lifetimeTokens"]),
            peakDailyTokens: integer(summaryValue["peakDailyTokens"]),
            longestRunningTurnSeconds: integer(summaryValue["longestRunningTurnSec"]),
            currentStreakDays: integer(summaryValue["currentStreakDays"]),
            longestStreakDays: integer(summaryValue["longestStreakDays"])
        )
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let buckets = (usage["dailyUsageBuckets"] as? [[String: Any]] ?? []).compactMap { row -> DailyBucket? in
            guard let rawDate = row["startDate"] as? String,
                  let date = formatter.date(from: rawDate),
                  let tokens = integer(row["tokens"]) else { return nil }
            return DailyBucket(date: calendar.startOfDay(for: date), tokens: max(0, tokens))
        }.sorted { $0.date < $1.date }
        return .init(identity: identity, summary: summary, dailyBuckets: buckets)
    }

    static func compactTokenCount(_ value: Int64?) -> String {
        guard let value else { return "未提供" }
        if value >= 100_000_000 { return String(format: "%.1f亿", Double(value) / 100_000_000) }
        if value >= 10_000 { return String(format: "%.1f万", Double(value) / 10_000) }
        return value.formatted()
    }

    static func duration(_ seconds: Int64?) -> String {
        guard let seconds else { return "未提供" }
        let hours = seconds / 3_600
        let minutes = seconds % 3_600 / 60
        if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
        if minutes > 0 { return "\(minutes) 分钟" }
        return "\(seconds) 秒"
    }

    private static func integer(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        return nil
    }
}

struct CodexUsageInsightsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var range: UsageActivityRange = .daily
    @State private var showProviderUsage = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("使用统计", systemImage: "chart.xyaxis.line")
                    .font(.headline)
                Spacer()
                Picker("统计来源", selection: $showProviderUsage) {
                    Text("Codex 账号").tag(false)
                    Text("第三方 API").tag(true)
                }.frame(width: 160)
                Button {
                    Task { await model.refreshUsageInsights() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoadingUsageInsights || showProviderUsage)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(18)

            Divider()

            Group {
                if showProviderUsage {
                    ProviderUsageView()
                } else if model.customModelProvider.enabled {
                    ContentUnavailableView("当前使用第三方 API", systemImage: "chart.bar",
                        description: Text("请选择第三方 API 查看本机用量统计；账号额度请在服务商控制台查看。"))
                } else if let insights = model.usageInsights {
                    ScrollView {
                        VStack(spacing: 30) {
                            profile(insights)
                            summary(insights.summary)
                            activity(insights)
                            Text("数据来自当前登录 Codex 的账号与使用统计接口；未返回的项目不会显示为 0。")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(30)
                    }
                } else if model.isLoadingUsageInsights {
                    ProgressView("正在读取 Codex 使用统计…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView {
                        Label("暂时无法读取使用统计", systemImage: "chart.bar.xaxis")
                    } description: {
                        Text(model.usageInsightsError ?? "请确认当前 Codex 已登录，然后重试。")
                    } actions: {
                        Button("重新读取") { Task { await model.refreshUsageInsights() } }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 940, height: 690)
        .task {
            showProviderUsage = model.customModelProvider.enabled
            if model.usageInsights == nil { await model.refreshUsageInsights() }
        }
    }

    private func profile(_ insights: CodexUsageInsights) -> some View {
        VStack(spacing: 12) {
            profileImage(insights.identity)
            Text(insights.identity.displayName)
                .font(.system(size: 32, weight: .medium))
                .textSelection(.enabled)
            HStack(spacing: 7) {
                Text(insights.identity.secondaryLabel)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let plan = insights.identity.planDisplayName {
                    Text(plan)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
    }

    @ViewBuilder
    private func profileImage(_ identity: CodexUsageInsights.Identity) -> some View {
        if let url = identity.avatarURL {
            AsyncImage(url: url) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    profileInitial(identity)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(Circle())
        } else {
            profileInitial(identity)
        }
    }

    private func profileInitial(_ identity: CodexUsageInsights.Identity) -> some View {
        Text(String(identity.displayName.prefix(1)).uppercased())
            .font(.system(size: 36, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 96, height: 96)
            .background(.cyan.gradient, in: Circle())
    }

    private func summary(_ value: CodexUsageInsights.Summary) -> some View {
        HStack(spacing: 0) {
            metric(CodexUsageInsights.compactTokenCount(value.lifetimeTokens), "累计 Token 数")
            metric(CodexUsageInsights.compactTokenCount(value.peakDailyTokens), "峰值 Token 数")
            metric(CodexUsageInsights.duration(value.longestRunningTurnSeconds), "最长任务时长")
            metric(value.currentStreakDays.map { "\($0) 天" } ?? "未提供", "当前连续天数")
            metric(value.longestStreakDays.map { "\($0) 天" } ?? "未提供", "最长连续天数")
        }
        .padding(.vertical, 16)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary))
    }

    private func metric(_ value: String, _ title: String) -> some View {
        VStack(spacing: 5) {
            Text(value).font(.title3).lineLimit(1).minimumScaleFactor(0.75)
            Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) { Divider().padding(.vertical, 2) }
    }

    private func activity(_ insights: CodexUsageInsights) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Token 活动").font(.title3.weight(.semibold))
                Spacer()
                Picker("统计范围", selection: $range) {
                    ForEach(UsageActivityRange.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
            }
            if insights.dailyBuckets.isEmpty {
                ContentUnavailableView("暂无 Token 活动", systemImage: "square.grid.3x3")
                    .frame(height: 220)
            } else {
                UsageActivityChart(buckets: insights.dailyBuckets, range: range)
            }
        }
    }
}

private enum UsageActivityRange: String, CaseIterable, Identifiable {
    case daily, weekly, cumulative
    var id: String { rawValue }
    var title: String {
        switch self { case .daily: "每日"; case .weekly: "每周"; case .cumulative: "累计" }
    }
}

private struct UsageActivityChart: View {
    private struct HoveredDay: Equatable {
        let date: Date
        let tokens: Int64
        let week: Int
        let day: Int
    }

    let buckets: [CodexUsageInsights.DailyBucket]
    let range: UsageActivityRange
    @State private var hoveredDay: HoveredDay?

    var body: some View {
        switch range {
        case .daily: heatmap
        case .weekly: bars(points: aggregate(component: .weekOfYear), cumulative: false)
        case .cumulative: bars(points: aggregate(component: .month), cumulative: true)
        }
    }

    private var heatmap: some View {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: max(Date(), buckets.last?.date ?? Date()))
        let start = calendar.date(byAdding: .day, value: -363, to: end) ?? end
        let values = Dictionary(uniqueKeysWithValues: buckets.map { (calendar.startOfDay(for: $0.date), $0.tokens) })
        let maximum = max(1, buckets.map(\.tokens).max() ?? 1)
        let weeks = (0..<52).map { week in
            (0..<7).compactMap { day in calendar.date(byAdding: .day, value: week * 7 + day, to: start) }
        }
        return VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                HStack(alignment: .top, spacing: 3) {
                    ForEach(Array(weeks.enumerated()), id: \.offset) { weekIndex, week in
                        VStack(spacing: 3) {
                            ForEach(Array(week.enumerated()), id: \.element) { dayIndex, date in
                            let tokens = values[date] ?? 0
                            RoundedRectangle(cornerRadius: 3)
                                .fill(activityColor(tokens: tokens, maximum: maximum))
                                .frame(width: 12, height: 12)
                                .contentShape(Rectangle())
                                .onHover { hovering in
                                    if hovering {
                                        hoveredDay = .init(date: date, tokens: tokens, week: weekIndex, day: dayIndex)
                                    } else if hoveredDay?.date == date {
                                        hoveredDay = nil
                                    }
                                }
                                .accessibilityLabel(dayDescription(date: date, tokens: tokens))
                            }
                        }
                    }
                }
                .padding(.top, 48)

                if let hoveredDay {
                    Text(dayDescription(date: hoveredDay.date, tokens: hoveredDay.tokens))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
                        .overlay(RoundedRectangle(cornerRadius: 11).stroke(.quaternary))
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                        .fixedSize()
                        .offset(
                            x: min(555, max(0, CGFloat(hoveredDay.week * 15) - 38)),
                            y: min(90, CGFloat(hoveredDay.day * 15))
                        )
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            HStack(spacing: 7) {
                Text(start.formatted(.dateTime.year().month(.abbreviated)))
                Spacer()
                Text(end.formatted(.dateTime.year().month(.abbreviated)))
                Text("少").foregroundStyle(.secondary)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(activityColor(tokens: Int64(level * 25), maximum: 100))
                        .frame(width: 11, height: 11)
                }
                Text("多").foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func bars(points: [(String, Int64)], cumulative: Bool) -> some View {
        let displayPoints: [(String, Int64)] = cumulative
            ? points.reduce(into: []) { result, point in
                result.append((point.0, (result.last?.1 ?? 0) + point.1))
            }
            : points
        let maximum = max(1, displayPoints.map(\.1).max() ?? 1)
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(Array(displayPoints.enumerated()), id: \.offset) { _, point in
                VStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.gradient)
                        .frame(height: max(4, 170 * CGFloat(Double(point.1) / Double(maximum))))
                        .help("\(point.0) · \(point.1.formatted()) Token")
                    Text(point.0).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 205, alignment: .bottom)
    }

    private func aggregate(component: Calendar.Component) -> [(String, Int64)] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: buckets) { bucket -> Date in
            let components: Set<Calendar.Component> = component == .weekOfYear
                ? [.calendar, .yearForWeekOfYear, .weekOfYear]
                : [.calendar, .year, .month]
            return calendar.date(from: calendar.dateComponents(components, from: bucket.date)) ?? bucket.date
        }
        let limit = component == .weekOfYear ? 12 : 12
        return grouped.keys.sorted().suffix(limit).map { date in
            let label = component == .weekOfYear
                ? date.formatted(.dateTime.month().day())
                : date.formatted(.dateTime.month(.abbreviated))
            return (label, grouped[date, default: []].reduce(0) { $0 + $1.tokens })
        }
    }

    private func activityColor(tokens: Int64, maximum: Int64) -> Color {
        guard tokens > 0 else { return Color.primary.opacity(0.07) }
        let ratio = min(1, max(0.15, Double(tokens) / Double(maximum)))
        return Color.accentColor.opacity(0.25 + ratio * 0.75)
    }

    private func dayDescription(date: Date, tokens: Int64) -> String {
        let dateText = date.formatted(.dateTime.month().day())
        return "\(dateText) 使用了 \(CodexUsageInsights.compactTokenCount(tokens)) 个 Token"
    }
}
