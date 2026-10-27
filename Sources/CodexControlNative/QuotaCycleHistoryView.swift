import SwiftUI

struct QuotaCycleHistoryView: View {
    let history: QuotaCycleHistory

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("额度周期记录").font(.title2.weight(.semibold))
                Text("5 小时与每周额度分别统计。从观测到剩余 100% 开始，到使用后再次观测到 100% 结束。首次读取不足 100% 时，等待下次恢复后开始。")
                    .foregroundStyle(.secondary)
                Text("Token 为本机 CloudCodex 实时收到的用量，两种额度窗口会分别记入同一笔 Token，请勿相加。额度消耗为账号采样中已用百分比的正向增量；采样间的消耗可能遗漏。关闭应用或切换账号期间不会补算 Token。")
                    .font(.callout).foregroundStyle(.secondary)
                if history.cycles.isEmpty {
                    ContentUnavailableView("等待额度恢复到 100%", systemImage: "clock.arrow.circlepath",
                                           description: Text("记录自动保存，开始统计后会显示当前周期和历史周期。"))
                }
                ForEach(history.cycles.reversed()) { cycle in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(cycle.title).font(.headline)
                            Text(cycle.endedAt == nil ? "记录中" : "已结束").foregroundStyle(.secondary)
                            Spacer()
                            if cycle.hasObservationGap {
                                Text("观测不完整").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Text("\(date(cycle.startedAt)) → \(cycle.endedAt.map(date) ?? "至今")")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: 30) {
                            Text("已记录 Token：\(cycle.tokens.formatted())")
                            Text(String(format: "已观测额度消耗：%.2f%%", cycle.consumedPercent))
                        }.monospacedDigit().textSelection(.enabled)
                        VStack(alignment: .leading, spacing: 4) {
                            if let estimate = cycle.estimatedTotalTokens {
                                Text("预估总额度：约 \(estimate.formatted(.number.precision(.fractionLength(0)))) Token")
                                    .font(.headline).monospacedDigit().textSelection(.enabled)
                            } else {
                                Text("预估总额度：等待 Token 用量和额度消耗数据")
                                    .foregroundStyle(.secondary)
                            }
                            Text("按已记录 Token ÷ 已观测额度消耗 × 100 估算，随用量更新，仅供参考，不代表固定 Token 上限。")
                                .font(.caption).foregroundStyle(.secondary)
                            if cycle.hasObservationGap {
                                Text("本周期观测不完整，估算可能存在偏差。")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        if let last = cycle.samples.last {
                            Text(String(format: "最近剩余额度：%.2f%% · %@", 100 - last.usedPercent, date(last.capturedAt)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("额度采样记录（\(cycle.samples.count)）") {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(Array(cycle.samples.enumerated()), id: \.offset) { _, sample in
                                    HStack {
                                        Text(date(sample.capturedAt))
                                        Spacer()
                                        Text(String(format: "剩余 %.2f%%", 100 - sample.usedPercent))
                                        Text("\(sample.tokens.formatted()) Token").frame(minWidth: 140, alignment: .trailing)
                                    }.font(.caption).monospacedDigit()
                                }
                            }.padding(.top, 8)
                        }
                    }
                    .padding(16)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(30)
        }
    }

    private func date(_ timestamp: Double) -> String {
        Date(timeIntervalSince1970: timestamp).formatted(date: .numeric, time: .standard)
    }
}
