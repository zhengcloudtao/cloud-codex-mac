import Foundation
import SwiftUI

struct AccountOverview {
    let plan: String
    let usage: RemoteUsageSnapshot

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

    static func parse(_ json: [String: Any]) -> Self {
        let legacy = json["rateLimits"] as? [String: Any]
        let buckets = json["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        let plan = legacy?["planType"] as? String
            ?? buckets["codex"]?["planType"] as? String
            ?? buckets.keys.sorted().compactMap { buckets[$0]?["planType"] as? String }.first
            ?? "未提供"
        return .init(plan: plan, usage: .parse(json))
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
}

struct AccountOverviewView: View {
    @EnvironmentObject private var model: AppModel
    @State private var expanded = false

    var body: some View {
        Button { expanded.toggle() } label: {
            if let account = model.accountOverview {
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
                    if let value = account.compactResetCredits {
                        quotaColumn("可用重置", value: value)
                    }
                    Image(systemName: model.accountOverviewError == nil ? "chevron.down" : "exclamationmark.circle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(model.accountOverviewError == nil ? Color.secondary : Color.orange)
                }
                .lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 6)
                // The toolbar supplies its own rounded container. Adding another
                // background and stroke here produces two overlapping outlines.
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
                            Text("套餐到期：当前接口未提供，不能用额度恢复时间代替。")
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
                    Text("刷新失败，以上可能是旧数据：\(error)").font(.caption).foregroundStyle(.orange)
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

    private func quotaColumn(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
        }
        .frame(minWidth: 48, alignment: .leading)
        .help(title + "：" + value)
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
