import Foundation

/// Local observations only: no prompts, responses, or credentials are stored.
struct ProviderUsageLedger: Codable, Equatable {
    static let defaultsKey = "cloudcodex.providerUsage.v1"

    struct Tokens: Codable, Equatable {
        var input: Int64 = 0
        var output: Int64 = 0
        var cached: Int64 = 0
        var reasoning: Int64 = 0
        var total: Int64 = 0

        init() {}
        init?(json: [String: Any]) {
            func number(_ name: String) -> Int64? {
                guard let value = json[name] as? NSNumber,
                      CFGetTypeID(value) != CFBooleanGetTypeID(), value.int64Value >= 0 else { return nil }
                return value.int64Value
            }
            guard let input = number("inputTokens"), let output = number("outputTokens"),
                  let cached = number("cachedInputTokens"), let reasoning = number("reasoningOutputTokens"),
                  let total = number("totalTokens") else { return nil }
            self.input = input; self.output = output; self.cached = cached
            self.reasoning = reasoning; self.total = total
        }
        func subtracting(_ other: Self) -> Self {
            var result = Self()
            result.input = max(0, input - other.input); result.output = max(0, output - other.output)
            result.cached = max(0, cached - other.cached); result.reasoning = max(0, reasoning - other.reasoning)
            result.total = max(0, total - other.total)
            return result
        }
        mutating func add(_ value: Self) {
            input += value.input; output += value.output; cached += value.cached
            reasoning += value.reasoning; total += value.total
        }
    }

    struct Entry: Codable, Equatable, Identifiable {
        let id: String
        let provider: String
        let model: String
        let startedAt: Date
        var status = "inProgress"
        var calls = 0
        var tokens = Tokens()
        var lastCumulative: Tokens?
    }

    var entries: [Entry] = []

    static func load(_ defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    mutating func consume(_ method: String, params: [String: Any],
                          configuration: ModelProviderConfiguration, now: Date = Date()) -> Bool {
        guard configuration.enabled,
              ["turn/started", "turn/completed", "thread/tokenUsage/updated"].contains(method),
              let thread = params["threadId"] as? String, !thread.isEmpty,
              let turn = params["turnId"] as? String ?? (params["turn"] as? [String: Any])?["id"] as? String,
              !turn.isEmpty else { return false }
        let id = [configuration.credentialAccount, configuration.modelID, thread, turn].joined(separator: "\u{001F}")
        let before = self
        if !entries.contains(where: { $0.id == id }) {
            let mode = configuration.service == .deepseek ? "" : (configuration.usesSubscription
                ? " · \(configuration.service?.subscriptionTitle() ?? "第三方")" : " · 按量计费")
            entries.append(Entry(id: id, provider: configuration.name + mode,
                                 model: configuration.modelID, startedAt: now))
        }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        if method == "turn/completed" {
            entries[index].status = (params["turn"] as? [String: Any])?["status"] as? String ?? "unknown"
        } else if method == "thread/tokenUsage/updated",
                  let usage = params["tokenUsage"] as? [String: Any],
                  let lastJSON = usage["last"] as? [String: Any], let last = Tokens(json: lastJSON),
                  let totalJSON = usage["total"] as? [String: Any], let total = Tokens(json: totalJSON),
                  last.total > 0 {
            let previous = entries[index].lastCumulative
            // First event may include historical tokens from other providers. Count
            // only `last`; subsequent cumulative deltas recover coalesced usage.
            if previous == nil || total.total > previous!.total {
                entries[index].tokens.add(previous.map { total.subtracting($0) } ?? last)
                entries[index].lastCumulative = total
                entries[index].calls += 1
            }
        }
        return before != self
    }

    struct Summary {
        let provider: String
        let model: String
        var turns = 0
        var calls = 0
        var completed = 0
        var failed = 0
        var missingUsage = 0
        var tokens = Tokens()
    }

    struct DailySummary: Identifiable {
        let date: Date
        let summary: Summary
        var series: String { summary.provider + " · " + summary.model }
        var id: String { "\(date.timeIntervalSince1970)\u{001F}\(summary.provider)\u{001F}\(summary.model)" }
    }

    /// Use the same task-start attribution as the totals. Include inactive days
    /// for every series so the chart does not connect across missing dates.
    func dailySummaries(since: Date? = nil, through end: Date = Date(),
                        calendar: Calendar = .current) -> [DailySummary] {
        let filtered = entries.filter { (since == nil || $0.startedAt >= since!) && $0.startedAt <= end }
        guard let earliest = filtered.map(\.startedAt).min() else { return [] }
        let start = calendar.startOfDay(for: since ?? earliest)
        let last = calendar.startOfDay(for: end)
        let series = Self(entries: filtered).summaries()
        let grouped = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.startedAt) }
        var result: [DailySummary] = []
        var date = start
        while date <= last {
            let daily = Self(entries: grouped[date] ?? []).summaries()
            for item in series {
                let value = daily.first { $0.provider == item.provider && $0.model == item.model }
                    ?? Summary(provider: item.provider, model: item.model)
                result.append(DailySummary(date: date, summary: value))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: date), next > date else { break }
            date = next
        }
        return result
    }

    func summaries(since: Date? = nil) -> [Summary] {
        var values: [String: Summary] = [:]
        for entry in entries where since == nil || entry.startedAt >= since! {
            let key = entry.provider + "\u{001F}" + entry.model
            var value = values[key] ?? Summary(provider: entry.provider, model: entry.model)
            value.turns += 1; value.calls += entry.calls
            value.completed += entry.status == "completed" ? 1 : 0
            value.failed += ["failed", "interrupted"].contains(entry.status) ? 1 : 0
            value.missingUsage += entry.calls == 0 ? 1 : 0
            value.tokens.add(entry.tokens)
            values[key] = value
        }
        return values.values.sorted { ($0.provider, $0.model) < ($1.provider, $1.model) }
    }
}
