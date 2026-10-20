import Foundation

/// API-equivalent token cost, not the price charged against a ChatGPT subscription.
/// Sources: https://developers.openai.com/api/docs/pricing and /models/<model>.
/// Cache partition: https://developers.openai.com/api/docs/guides/prompt-caching.
struct CodexAPIUsagePricing {
    static let revision = "2026-10-19 · 速度按任务识别 v2"
    static let sourceURL = URL(string: "https://developers.openai.com/api/docs/pricing")!

    struct Tokens: Codable, Equatable, Sendable {
        let input: Int64
        let cached: Int64
        let cacheWrite: Int64
        let output: Int64
        var ordinary: Int64 { input - cached - cacheWrite }
        var valid: Bool { input >= 0 && cached >= 0 && cacheWrite >= 0 && output >= 0
            && cached <= input && cacheWrite <= input - cached }
        var total: Double { Double(input) + Double(output) }
    }
    struct Rates: Codable, Equatable, Sendable {
        let input: Double
        let cached: Double
        let cacheWrite: Double
        let output: Double
        func cost(_ tokens: Tokens) -> Double {
            (Double(tokens.ordinary) * input + Double(tokens.cached) * cached
             + Double(tokens.cacheWrite) * cacheWrite + Double(tokens.output) * output) / 1_000_000
        }
    }
    struct Line: Codable, Equatable, Sendable {
        let model: String
        let basis: String
        var tokens: Tokens?
        var observedTokens: Double
        let rates: Rates?
        var dollars: Double?
        let issue: String?
        var assumedSpeed: Bool { basis.contains("日志未提供速度") || basis.contains("按标准价") }
        var key: String { model + "|" + basis + "|" + (issue ?? "") }
    }
    struct Report: Codable, Equatable, Sendable {
        var revision = CodexAPIUsagePricing.revision
        var lines: [Line] = []
        var knownDollars: Double { lines.filter { !$0.assumedSpeed }.compactMap(\.dollars).reduce(0, +) }
        var unpricedTokens: Double { lines.filter { $0.dollars == nil || $0.assumedSpeed }.map(\.observedTokens).reduce(0, +) }
        var complete: Bool { !lines.isEmpty && lines.allSatisfy { $0.dollars != nil && !$0.assumedSpeed } }
        mutating func add(_ line: Line) {
            if let index = lines.firstIndex(where: { $0.key == line.key && $0.rates == line.rates }) {
                var old = lines[index]
                old.observedTokens += line.observedTokens
                if let a = old.tokens, let b = line.tokens {
                    old.tokens = Tokens(input: a.input + b.input, cached: a.cached + b.cached,
                                        cacheWrite: a.cacheWrite + b.cacheWrite, output: a.output + b.output)
                } else { old.tokens = nil }
                if let a = old.dollars, let b = line.dollars { old.dollars = a + b }
                lines[index] = old
            } else { lines.append(line) }
            lines.sort { $0.key < $1.key }
        }
    }

    static func line(model: String?, tier: String?, tierSource: String = "日志记录档位", tokens: Tokens?, observedTokens: Int64) -> Line {
        let name = String((model ?? "未知模型").prefix(100))
        let long = (tokens?.input ?? 0) > 272_000
        let mode: String
        let multiplier: Double
        switch tier {
        case "default", "standard": mode = "Standard"; multiplier = 1
        case nil, "", "auto": mode = "速度未知"; multiplier = 0
        case "priority", "fast": mode = "Fast"; multiplier = 2
        case "ultrafast": mode = "Ultrafast"; multiplier = 6
        case "flex", "batch": mode = tier!.capitalized; multiplier = 0.5
        default: mode = "未知速度"; multiplier = 0
        }
        let basis = mode + (long ? " · 长上下文" : " · 短上下文")
            + " · " + (multiplier == 0 ? "缺少明确速度依据" : tierSource)
        var problem: String?
        if tokens == nil || tokens?.valid != true { problem = "分类用量缺失或本次增量与请求不一致" }
        let base: (Double, Double, Double)?
        switch name {
        case "gpt-6.1-sol": base = (2, 0.1, 10)
        case "gpt-6-sol": base = (2, 0.2, 10)
        case "gpt-6-astra": base = (10, 1, 50)
        case "gpt-6-luna": base = (0.1, 0.01, 0.5)
        case "gpt-5.6-sol": base = (4, 0.4, 20)
        case "gpt-5.6-terra": base = (2, 0.2, 12)
        case "gpt-5.6-luna": base = (0.2, 0.02, 1.2)
        default: base = nil; problem = "模型尚无已核对的价格"
        }
        if multiplier == 0 { problem = "速度未知或档位缺少价格，未按 Standard 代算" }
        // All seven supported models have verified Standard/Fast/Batch/Flex
        // rows in pricing.md. Ultrafast currently lists Astra and 6.1 Sol only.
        if mode == "Ultrafast", !["gpt-6.1-sol", "gpt-6-astra"].contains(name) {
            problem = "该模型未提供 Ultrafast 价格"
        }
        let rates: Rates? = base.map {
            Rates(input: $0.0 * multiplier * (long ? 2 : 1),
                  cached: $0.1 * multiplier * (long ? 2 : 1),
                  cacheWrite: $0.0 * 1.25 * multiplier * (long ? 2 : 1),
                  output: $0.2 * multiplier * (long ? 1.5 : 1))
        }
        return Line(model: name, basis: basis, tokens: tokens, observedTokens: Double(observedTokens),
                    rates: problem == nil ? rates : nil,
                    dollars: problem == nil ? tokens.flatMap { t in rates.map { $0.cost(t) } } : nil, issue: problem)
    }
}
