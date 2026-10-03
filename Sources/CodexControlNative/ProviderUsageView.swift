import SwiftUI
import Charts

struct ProviderUsageView: View {
    @EnvironmentObject private var model: AppModel
    @State private var days = 7

    private var since: Date? {
        guard days != 0 else { return nil }
        let today = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .day, value: -(days - 1), to: today)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("第三方 API 用量").font(.title2.bold())
                    Spacer()
                    Picker("时间范围", selection: $days) {
                        Text("今天").tag(1)
                        Text("近 7 天").tag(7)
                        Text("近 30 天").tag(30)
                        Text("全部").tag(0)
                    }.frame(width: 180)
                }
                Text("统计本机 CloudCodex 自启用此功能后收到的用量回报，按任务开始日期归入所选范围，重启后保留。")
                    .font(.callout).foregroundStyle(.secondary)
                let summaries = model.providerUsage.summaries(since: since)
                if summaries.isEmpty {
                    ContentUnavailableView("暂无用量记录", systemImage: "chart.bar",
                        description: Text("使用第三方服务运行任务后，用量和已记录响应次数会显示在这里。"))
                } else {
                    ProviderDailyUsageChart(points: model.providerUsage.dailySummaries(since: since))
                        .id(days)
                }
                ForEach(summaries, id: \.modelAndProvider) { summary in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("\(summary.provider) · \(summary.model)").font(.headline)
                            HStack(spacing: 24) {
                                metric("已记录响应次数", summary.calls)
                                metric("任务轮次", summary.turns)
                                metric("完成", summary.completed)
                                metric("失败 / 中断", summary.failed)
                            }
                            Divider()
                            HStack(spacing: 24) {
                                token("总 Token", summary.tokens.total, known: summary.calls > 0)
                                token("输入 Token", summary.tokens.input, known: summary.calls > 0)
                                token("输出 Token", summary.tokens.output, known: summary.calls > 0)
                                token("缓存命中 Token", summary.tokens.cached, known: summary.calls > 0)
                                token("推理 Token", summary.tokens.reasoning, known: summary.calls > 0)
                            }
                            if summary.missingUsage > 0 {
                                Text("\(summary.missingUsage) 轮任务尚无用量回报，其用量未计入。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text("已记录响应次数按不同的有效累计用量更新计数，重复事件不会重复累加；一轮任务可能多次调用模型。合并回报、未回报用量的失败重试或其他客户端调用无法完整统计，实际请求数、余额及费用以服务商账单为准。缓存命中属于输入，推理属于输出，请勿重复相加。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(26)
        }
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.formatted()).font(.title3.monospacedDigit())
        }
    }
    private func token(_ title: String, _ value: Int64, known: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(known ? value.formatted() : "未回报").font(.title3.monospacedDigit()).textSelection(.enabled)
        }
    }
}

private struct ProviderDailyUsageChart: View {
    let points: [ProviderUsageLedger.DailySummary]
    @State private var metric: Metric = .total
    @State private var selectedDate: Date?

    private enum Metric: String, CaseIterable, Identifiable {
        case total = "总 Token"
        case input = "输入 Token"
        case output = "输出 Token"
        case cached = "缓存命中 Token"
        case reasoning = "推理 Token"
        case calls = "已记录响应次数"
        case turns = "任务轮次"
        var id: String { rawValue }

        func value(_ summary: ProviderUsageLedger.Summary) -> Int64 {
            switch self {
            case .total: return summary.tokens.total
            case .input: return summary.tokens.input
            case .output: return summary.tokens.output
            case .cached: return summary.tokens.cached
            case .reasoning: return summary.tokens.reasoning
            case .calls: return Int64(summary.calls)
            case .turns: return Int64(summary.turns)
            }
        }

        var isToken: Bool { self != .calls && self != .turns }
    }

    private var inspectedDate: Date? {
        guard let selectedDate else { return points.last?.date }
        return points.map(\.date).min { abs($0.timeIntervalSince(selectedDate)) < abs($1.timeIntervalSince(selectedDate)) }
    }

    private var dateDomain: ClosedRange<Date> {
        let first = points.first?.date ?? Date()
        let last = points.last?.date ?? first
        return first.addingTimeInterval(-43_200)...last.addingTimeInterval(43_200)
    }

    private var axisDayStride: Int {
        let first = points.first?.date ?? Date()
        let last = points.last?.date ?? first
        let count = Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0
        return max(1, Int(ceil(Double(count + 1) / 7)))
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("每日趋势").font(.headline)
                    Spacer()
                    Picker("统计指标", selection: $metric) {
                        ForEach(Metric.allCases) { item in Text(item.rawValue).tag(item) }
                    }.frame(width: 240)
                }
                Chart {
                    ForEach(points) { point in
                        LineMark(x: .value("日期", point.date), y: .value(metric.rawValue, metric.value(point.summary)))
                            .foregroundStyle(by: .value("模型", point.series))
                            .interpolationMethod(.linear)
                        PointMark(x: .value("日期", point.date), y: .value(metric.rawValue, metric.value(point.summary)))
                            .foregroundStyle(by: .value("模型", point.series))
                            .symbol(by: .value("模型", point.series))
                            .symbolSize(24)
                            .accessibilityLabel("\(point.date.formatted(date: .abbreviated, time: .omitted))，\(point.series)")
                            .accessibilityValue("\(metric.rawValue)：\(metric.value(point.summary).formatted())")
                    }
                    if let inspectedDate {
                        RuleMark(x: .value("日期", inspectedDate))
                            .foregroundStyle(.secondary.opacity(0.35))
                    }
                }
                .chartXScale(domain: dateDomain)
                .chartYScale(domain: .automatic(includesZero: true))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: axisDayStride)) { _ in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel(format: .dateTime.month().day())
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading)
                .chartXSelection(value: $selectedDate)
                .frame(height: 260)

                if let inspectedDate {
                    Text(inspectedDate.formatted(date: .complete, time: .omitted))
                        .font(.subheadline.bold())
                    ForEach(points.filter { $0.date == inspectedDate }) { point in
                        HStack {
                            Text(point.series).foregroundStyle(.secondary)
                            Spacer()
                            if metric.isToken && point.summary.turns > 0 && point.summary.calls == 0 {
                                Text("未回报").foregroundStyle(.secondary)
                            } else {
                                Text(metric.value(point.summary).formatted()).monospacedDigit()
                            }
                            if point.summary.missingUsage > 0 {
                                Text("\(point.summary.missingUsage) 轮未回报用量").foregroundStyle(.secondary)
                            }
                        }.font(.callout)
                    }
                }
                Text("点击或拖动图表查看每日数值。按任务开始日期统计；无记录日期显示为 0，未回报用量不计入 Token。")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
}

private extension ProviderUsageLedger.Summary {
    var modelAndProvider: String { provider + "\u{001F}" + model }
}
