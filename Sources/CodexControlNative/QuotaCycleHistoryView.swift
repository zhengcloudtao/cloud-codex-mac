import SwiftUI

struct QuotaCycleHistoryView: View {
    let history: QuotaCycleHistory

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("额度周期记录").font(.title2.weight(.semibold))
                Text("5 小时与每周额度分别统计。首次读取有效额度即开始采样，恢复到 100% 时结束当前周期并开启新周期。中途开始的周期只统计开始记录后的用量。")
                    .foregroundStyle(.secondary)
                Text("Token 为本机 CloudCodex 实时收到的用量，两种额度窗口会分别记入同一笔 Token，请勿相加。额度消耗为账号采样中已用百分比的正向增量；采样间的消耗可能遗漏。关闭应用或切换账号期间不会补算 Token。")
                    .font(.callout).foregroundStyle(.secondary)
                if history.cycles.isEmpty {
                    ContentUnavailableView("等待获取额度数据", systemImage: "clock.arrow.circlepath",
                                           description: Text("记录自动保存，开始统计后会显示当前周期和历史周期。"))
                        .frame(maxWidth: .infinity, minHeight: 300, alignment: .center)
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
                        if cycle.startingUsedPercent > 0.001 {
                            Text(String(format: "从剩余 %.2f%% 开始采样，仅统计开始记录后的用量", 100 - cycle.startingUsedPercent))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(date(cycle.startedAt)) → \(cycle.endedAt.map(date) ?? "至今")")
                            .font(.callout).foregroundStyle(.secondary)
                        HStack(spacing: 30) {
                            Text("已记录 Token：\(cycle.tokens.formatted())")
                            Text(String(format: "采样以来额度消耗：%.2f%%", cycle.consumedPercent))
                        }.monospacedDigit().textSelection(.enabled)
                        Text(breakdownText(cycle.breakdown, total: cycle.tokens))
                            .font(.callout).monospacedDigit().textSelection(.enabled)
                        VStack(alignment: .leading, spacing: 4) {
                            if let estimate = cycle.estimatedTotalTokens {
                                Text("预估总额度：约 \(estimate.formatted(.number.precision(.fractionLength(0)))) Token")
                                    .font(.headline).monospacedDigit().textSelection(.enabled)
                            } else {
                                Text("预估总额度：等待 Token 用量和额度消耗数据")
                                    .foregroundStyle(.secondary)
                            }
                            if let input = cycle.estimatedInputTokens, let output = cycle.estimatedOutputTokens {
                                Text("预估输入：约 \(input.formatted(.number.precision(.fractionLength(0)))) · 预估输出：约 \(output.formatted(.number.precision(.fractionLength(0)))) Token")
                                    .font(.callout).monospacedDigit().textSelection(.enabled)
                            } else if cycle.unclassifiedTokens > 0 {
                                Text("存在未分类 Token，暂不估算输入／输出总额度。")
                                    .font(.caption).foregroundStyle(.secondary)
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
                                        VStack(alignment: .trailing, spacing: 3) {
                                            Text("总计 \(sample.tokens.formatted()) Token")
                                            Text(breakdownText(sample.breakdown, total: sample.tokens))
                                                .foregroundStyle(.secondary)
                                        }.frame(minWidth: 230, alignment: .trailing)
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

    private func breakdownText(_ breakdown: QuotaCycleHistory.Breakdown?, total: Int64) -> String {
        guard let breakdown else {
            return total == 0 ? "输入 0 · 输出 0 Token" : "输入／输出未记录 · 未分类 \(total.formatted()) Token"
        }
        let unknown = max(0, total - breakdown.total)
        let label = unknown > 0 ? "已分类输入" : "输入"
        return "\(label) \(breakdown.input.formatted()) · 输出 \(breakdown.output.formatted())"
            + (unknown > 0 ? " · 未分类 \(unknown.formatted())" : "") + " Token"
    }

    private func date(_ timestamp: Double) -> String {
        Date(timeIntervalSince1970: timestamp).formatted(date: .numeric, time: .standard)
    }
}
