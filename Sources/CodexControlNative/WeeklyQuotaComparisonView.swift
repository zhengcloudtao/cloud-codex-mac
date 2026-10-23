import SwiftUI

struct WeeklyQuotaComparisonSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var plan = ""
    @State private var percent = ""
    @State private var tokens = ""
    @State private var dollars = ""
    @State private var monthlyPrice = ""
    @State private var busy = false
    @State private var message: String?
    @State private var isError = false
    @State private var baselineID: UUID?
    @State private var showManualEntry = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("周额度换算与套餐对比", systemImage: "chart.bar.xaxis").font(.headline)
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("后台自动采集账号用量和周额度，推算 100% 周额度对应的 Token 容量及 API 等值美元，并保留不同套餐的结果进行比较。")
                    automaticSampling
                    comparisons
                    DisclosureGroup("手动采样或补充费用", isExpanded: $showManualEntry) {
                    GroupBox("读取当前套餐的用量差值") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("在任务结束、统计稳定后读取起点，正常使用一段时间，待统计更新后读取终点。建议至少消耗 5 个百分点；不足 1 个百分点无法保存。")
                                .foregroundStyle(.secondary)
                            HStack {
                                Button(busy ? "正在读取…" : "读取起点") { capture(start: true) }
                                    .disabled(busy || model.customModelProvider.enabled)
                                Button("读取终点并填入") { capture(start: false) }
                                    .disabled(busy || model.weeklyQuotaBaseline == nil || model.customModelProvider.enabled)
                                if model.weeklyQuotaBaseline != nil {
                                    Button("取消采样") { model.cancelWeeklyQuotaMeasurement() }
                                        .disabled(busy)
                                }
                                if busy { ProgressView().controlSize(.small) }
                            }
                            if let baseline = model.weeklyQuotaBaseline {
                                Text("起点：\(CodexPlanName.displayName(baseline.plan)) · 周已用 \(number(baseline.usedPercent))% · \(baseline.date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("手动采样读取账号累计 Token 的差值。请保持相近的模型和速度模式；接口统计可能延迟。手动起点仅在本次运行中保留。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    }
                    GroupBox("采样数据（也可手动录入）") {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                field("套餐 / 模型 / 速度备注", text: $plan, prompt: "例如 Plus · 模型 · Standard")
                                field("本段消耗（百分点）", text: $percent, prompt: "例如 10，表示从 20% 用到 30%")
                            }
                            HStack {
                                field("本段 Token 总量", text: $tokens, prompt: "可选，填写完整数字")
                                field("本段 API 等值费用（USD）", text: $dollars, prompt: "可选，例如 2.50")
                                field("套餐月费（USD）", text: $monthlyPrice, prompt: "可选，用于每美元容量比较")
                            }
                            Text("Token 与费用至少填一项，且必须对应上面同一段消耗。自动采样会按实际模型及输入、缓存、输出用量估算费用；手动录入需填入同一段的费用。所有金额统一使用美元。")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("保存到对比") { save() }.disabled(busy)
                                if let message {
                                    Text(message).foregroundStyle(isError ? Color.orange : Color.green)
                                        .font(.callout).textSelection(.enabled)
                                }
                            }
                        }.padding(8)
                    }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("换算方法").fontWeight(.semibold)
                        Text("整周估值 = 本段 Token 或费用 × 100 ÷ 本段消耗百分点。每美元容量 = 整周 Token × (365.2425 ÷ 12 ÷ 7) ÷ 月费。")
                        Text("结果是当前使用组合下的外推估算。订阅额度不是固定 Token 或现金余额；模型、速度、缓存比例、其他共享用量和统计延迟都会影响结果。采样越小，误差越大。只在本机保存对比记录，可逐条删除。")
                        Link("查看 OpenAI 官方额度与价格说明", destination: URL(string: "https://developers.openai.com/codex/pricing")!)
                    }.font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }
        }
        .frame(width: 960, height: 740)
        .onChange(of: model.weeklyQuotaComparison.samples.map(\.id)) { _, ids in
            if baselineID == nil || !ids.contains(where: { $0 == baselineID }) { baselineID = ids.first }
        }
        .task {
            model.loadWeeklyQuotaComparison()
            if plan.isEmpty { plan = model.accountOverview?.planDisplayName ?? "" }
            if baselineID == nil { baselineID = model.weeklyQuotaComparison.samples.first?.id }
        }
    }

    private var automaticSampling: some View {
        GroupBox("自动持续采样") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Toggle("后台每分钟自动采样", isOn: Binding(
                        get: { model.automaticWeeklyQuotaEnabled },
                        set: { model.setAutomaticWeeklyQuotaEnabled($0) }
                    ))
                    Spacer()
                    Button(model.isSamplingWeeklyQuota ? "正在采样…" : "立即采样") {
                        Task { await model.sampleWeeklyQuotaAutomatically() }
                    }
                    .disabled(model.isSamplingWeeklyQuota || !model.automaticWeeklyQuotaEnabled || model.customModelProvider.enabled)
                }
                if model.customModelProvider.enabled {
                    Text("当前使用第三方 API，ChatGPT 周额度采样自动暂停。")
                } else if !model.automaticWeeklyQuotaEnabled {
                    Text("自动采样已关闭，已有对比记录仍保留。")
                } else {
                    Text(model.isSamplingWeeklyQuota ? "正在读取账号、周额度和 Token 用量…" : model.automaticWeeklyQuotaSampler.status)
                    if model.isSamplingWeeklyQuota, let issue = model.automaticWeeklyQuotaSampler.lastIssue {
                        Text("上次读取：\(issue.errorDescription ?? "数据暂不可用")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let attempt = model.automaticWeeklyQuotaSampler.lastAttempt,
                       model.automaticWeeklyQuotaSampler.lastIssue != nil {
                        Text("最近尝试 \(attempt.formatted(date: .omitted, time: .standard)) · 约 1 分钟后自动重试，也可立即采样。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let latest = model.automaticWeeklyQuotaSampler.latest {
                        Text("\(CodexPlanName.displayName(latest.plan)) · 本段已消耗 \(number(model.automaticWeeklyQuotaSampler.consumedPercent ?? 0)) 个百分点 · 最近采样 \(latest.date.formatted(date: .abbreviated, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if let tokens = model.automaticWeeklyQuotaSampler.observedLocalTokens {
                        Text("本段本机日志已观测 \(tokens.formatted()) Token")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Text("无需打开此页面，应用运行时就会采集。至少消耗 5 个百分点且同一时段的本机日志 Token 有增长后自动计算并保存，不要求停止使用或等待计数不变；同一采样段持续更新一条记录。临时读取失败会保留起点。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("自动结果是本机观测估算：账号额度可能包含其他设备、云端或共享功能用量，本机日志未覆盖的部分可能导致低估。比较套餐时请保持相近的设备、模型和任务组合。费用按本机请求的实际模型和分类用量自动计价；速度按每轮任务识别；缺少依据的部分列为未计价。")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private var comparisons: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("已保存的套餐采样").font(.title3.weight(.semibold))
                Spacer()
                Picker("对比基准", selection: $baselineID) {
                    Text("请选择").tag(nil as UUID?)
                    ForEach(model.weeklyQuotaComparison.samples) { sample in
                        Text("\(CodexPlanName.displayName(sample.plan)) · \(sample.date.formatted(date: .numeric, time: .shortened))")
                            .tag(Optional(sample.id))
                    }
                }.frame(width: 370)
            }
            if model.weeklyQuotaComparison.samples.isEmpty {
                Text("正在等待有效采样。正常使用即可，达到采样条件后会自动生成记录；切换套餐后会分别保留结果。")
                    .foregroundStyle(.secondary).padding(.vertical, 16)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                    GridRow {
                        Text("套餐 / 消耗")
                        Text("整周 Token ≈")
                        Text("整周 USD ≈")
                        Text("Token / USD ≈")
                        Text("等值倍数")
                        Text("")
                    }.font(.caption).foregroundStyle(.secondary)
                    ForEach(model.weeklyQuotaComparison.samples) { sample in
                        GridRow {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(CodexPlanName.displayName(sample.plan)).lineLimit(2)
                                if sample.automatic == true {
                                    Text(sample.id == model.automaticWeeklyQuotaSampler.sampleID ? "自动采样 · 当前段" : "自动采样 · 历史段").font(.caption).foregroundStyle(.secondary)
                                }
                                if sample.tokenSource == .localLogs {
                                    Text("本机观测估算 · 可能低估").font(.caption).foregroundStyle(.secondary)
                                }
                                Text("\(number(sample.percent)) 个百分点 · \(sample.date.formatted(date: .numeric, time: .omitted))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let price = sample.monthlyPrice {
                                    Text("$\(number(price)) / 月").font(.caption).foregroundStyle(.secondary)
                                }
                                if sample.percent < 5 {
                                    Text("样本较小，误差较大").font(.caption).foregroundStyle(.orange)
                                }
                            }.frame(width: 225, alignment: .leading)
                            Text(sample.weeklyTokens.map { number($0) } ?? "—")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(weeklyCost(sample))
                                if let report = sample.costReport {
                                    Text(report.complete ? "API 等值估算" : "仅已知部分 · 未计全")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text(sample.tokensPerDollar.map { number($0) } ?? "—")
                            Text(ratio(sample))
                            HStack(spacing: 6) {
                                if sample.automatic == true {
                                    Button {
                                        plan = CodexPlanName.displayName(sample.plan)
                                        percent = String(sample.percent)
                                        tokens = sample.tokens.map { String(format: "%.0f", $0) } ?? ""
                                        dollars = sample.dollars.map { String($0) } ?? ""
                                        monthlyPrice = ""
                                        showManualEntry = true
                                        report("已复制这段实测用量，可补充同一段费用和月费后另存一条对比。", error: false)
                                    } label: { Image(systemName: "square.and.pencil") }
                                        .help("复制本段用量并补充费用")
                                }
                                Button {
                                    do {
                                        try model.removeWeeklyQuotaSample(sample.id)
                                        if baselineID == sample.id { baselineID = nil }
                                    } catch { report(error.localizedDescription, error: true) }
                                } label: { Image(systemName: "trash") }.help("删除这条采样记录")
                            }
                        }
                    }
                }.monospacedDigit().textSelection(.enabled)
                ForEach(model.weeklyQuotaComparison.samples.filter { $0.costReport != nil }) { sample in
                    costBreakdown(sample)
                }
                Text("等值倍数优先比较整周 API 等值美元；双方没有美元记录时比较 Token 容量。请使用相近的模型、速度和输入/输出/缓存比例采样，才能比较套餐差异。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func weeklyCost(_ sample: WeeklyQuotaComparison.Sample) -> String {
        if let dollars = sample.weeklyDollars { return "$" + number(dollars) }
        if let report = sample.costReport, report.knownDollars > 0 {
            return "≥ $" + number(report.knownDollars * 100 / sample.percent)
        }
        return "—"
    }

    private func costBreakdown(_ sample: WeeklyQuotaComparison.Sample) -> some View {
        DisclosureGroup("\(CodexPlanName.displayName(sample.plan)) · 本段计价明细 · \(sample.date.formatted(date: .numeric, time: .shortened))") {
            if let report = sample.costReport {
                VStack(alignment: .leading, spacing: 10) {
                    Text("本段已知费用 $\(number(report.knownDollars)) · 消耗 \(number(sample.percent)) 个百分点 · 整周 ≈ \(weeklyCost(sample))")
                    if !report.complete {
                        Text("还有 \(number(report.unpricedTokens)) Token 未计价，当前金额仅覆盖已知部分。")
                            .foregroundStyle(.orange)
                    }
                    ForEach(Array(report.lines.enumerated()), id: \.offset) { _, line in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(line.model) · \(line.basis)").fontWeight(.medium)
                            if let t = line.tokens {
                                Text("普通输入 \(t.ordinary.formatted()) · 缓存命中 \(t.cached.formatted()) · 缓存写入 \(t.cacheWrite.formatted()) · 输出 \(t.output.formatted())")
                            }
                            if let r = line.rates, let dollars = line.dollars, !line.assumedSpeed {
                                Text("单价 USD / 百万 Token：输入 \(number(r.input)) / 缓存 \(r.cached.formatted(.number.precision(.fractionLength(0...4)))) / 写入 \(r.cacheWrite.formatted(.number.precision(.fractionLength(0...4)))) / 输出 \(number(r.output))；本段 $\(dollars.formatted(.number.precision(.fractionLength(4))))")
                            } else {
                                Text("未计价 \(number(line.observedTokens)) Token：\(line.assumedSpeed ? "旧记录缺少速度依据，原 Standard 假设金额已撤回" : (line.issue ?? "缺少计价依据"))").foregroundStyle(.orange)
                            }
                        }
                    }
                    Text("价格表核对日期：\(report.revision)。输入总量已扣除缓存命中和缓存写入后按普通输入计价；推理 Token 已包含在输出中。超过 272K 输入的请求使用长上下文价格。档位来自日志或已接受的任务请求；请求档位可能被服务端降级，明细会注明是否取得实际返回档位。费用不含工具、图片生成、地区附加费，也不是订阅账单或可提现余额。")
                        .foregroundStyle(.secondary)
                    Link("OpenAI 官方 API 价格", destination: CodexAPIUsagePricing.sourceURL)
                }.font(.caption).textSelection(.enabled).padding(.vertical, 8)
            }
        }
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder)
        }.frame(maxWidth: .infinity)
    }

    private func capture(start: Bool) {
        busy = true
        message = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                if let sample = try await model.readWeeklyQuotaMeasurement(start: start) {
                    plan = CodexPlanName.displayName(sample.plan)
                    percent = String(sample.percent)
                    tokens = String(format: "%.0f", sample.tokens ?? 0)
                    dollars = ""
                    monthlyPrice = ""
                    report("已填入差值，可补充备注和费用后保存。", error: false)
                } else { report("已记录起点，使用一段时间后读取终点。", error: false) }
            } catch let error as WeeklyQuotaComparison.MeasurementError {
                report(error.localizedDescription, error: true)
            } catch {
                report("读取失败，请检查 Codex 登录和连接后重试；当前采样未保存。", error: true)
            }
        }
    }

    private func save() {
        do {
            func optionalNumber(_ text: String) throws -> Double? {
                let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if raw.isEmpty { return nil }
                guard let value = Double(raw) else {
                    throw WeeklyQuotaComparison.MeasurementError("数值格式不正确，请使用数字和小数点，不要带货币符号或千位分隔符。")
                }
                return value
            }
            let sample = try WeeklyQuotaComparison.Sample.make(
                plan: plan, percent: optionalNumber(percent) ?? 0,
                tokens: optionalNumber(tokens), dollars: optionalNumber(dollars),
                monthlyPrice: optionalNumber(monthlyPrice))
            try model.saveWeeklyQuotaSample(sample)
            if baselineID == nil { baselineID = sample.id }
            report("已保存，可继续录入其他套餐。", error: false)
        } catch { report(error.localizedDescription, error: true) }
    }

    private func report(_ text: String, error: Bool) { message = text; isError = error }
    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }
    private func ratio(_ sample: WeeklyQuotaComparison.Sample) -> String {
        guard let baseline = model.weeklyQuotaComparison.samples.first(where: { $0.id == baselineID }) else { return "—" }
        if let base = baseline.weeklyDollars, let value = sample.weeklyDollars {
            return number(value / base) + "× USD"
        }
        guard baseline.dollars == nil, sample.dollars == nil,
              baseline.costReport == nil, sample.costReport == nil,
              let baseTokens = baseline.weeklyTokens, let valueTokens = sample.weeklyTokens else { return "—" }
        return number(valueTokens / baseTokens) + "× Token"
    }
}
