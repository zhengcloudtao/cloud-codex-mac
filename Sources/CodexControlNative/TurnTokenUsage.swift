import Foundation

/// Only usage metadata is persisted; conversation contents never enter this ledger.
struct TurnTokenUsageLedger: Codable, Equatable {
    static let defaultsKey = "cloudcodex.turnTokenUsage.v1"
    typealias Tokens = ProviderUsageLedger.Tokens
    struct Record: Codable, Equatable {
        var tokens = Tokens()
        var partial = false
    }
    struct Baseline: Codable, Equatable {
        var turn: String
        var tokens: Tokens
        var observedAt: Double? = nil
    }
    var records: [String: Record] = [:]
    var baselines: [String: Baseline] = [:]

    static func preferred(_ left: Record?, _ right: Record?) -> Record? {
        guard let left else { return right }
        guard let right else { return left }
        if left.tokens.total != right.tokens.total { return left.tokens.total > right.tokens.total ? left : right }
        return left.partial ? right : left
    }

    static func key(_ thread: String, _ turn: String) -> String { thread + "\u{001F}" + turn }

    mutating func observe(thread: String, turn: String, total: Tokens, last: Tokens) {
        let previous = baselines[thread]
        // Notifications can repeat (including after a restart or turn transition).
        if previous?.tokens == total { return }
        let key = Self.key(thread, turn)
        var record = records[key] ?? Record()
        let delta: Tokens
        if let previous, total.total > previous.tokens.total {
            delta = total.subtracting(previous.tokens)
            // A gap crossing a turn boundary cannot safely be charged to this turn.
            if previous.turn != turn && delta.total != last.total {
                record.tokens.add(last)
                record.partial = true
            } else {
                record.tokens.add(delta)
            }
        } else {
            record.tokens.add(last)
            if total.total != last.total || previous != nil { record.partial = true }
        }
        records[key] = record
        baselines[thread] = Baseline(turn: turn, tokens: total, observedAt: Date().timeIntervalSince1970)
    }

    /// Only a measured delta omitted by this event is evidence of lost usage.
    /// A sticky per-turn partial flag (e.g. inherited history) is not evidence.
    func missingDeltaBaseline(_ params: [String: Any], credited: Int64) -> Double? {
        guard let thread = params["threadId"] as? String,
              let previous = baselines[thread], let observedAt = previous.observedAt,
              let usage = params["tokenUsage"] as? [String: Any],
              let json = usage["total"] as? [String: Any], let total = Tokens(json: json),
              total.total > previous.tokens.total,
              total.total - previous.tokens.total > credited else { return nil }
        return observedAt
    }

    mutating func consume(_ params: [String: Any]) {
        guard let thread = params["threadId"] as? String,
              let turn = params["turnId"] as? String, !thread.isEmpty, !turn.isEmpty,
              let usage = params["tokenUsage"] as? [String: Any],
              let totalJSON = usage["total"] as? [String: Any],
              let lastJSON = usage["last"] as? [String: Any],
              let total = Tokens(json: totalJSON), let last = Tokens(json: lastJSON) else { return }
        observe(thread: thread, turn: turn, total: total, last: last)
    }

    func record(thread: String, turn: String) -> Record? { records[Self.key(thread, turn)] }

    mutating func merge(_ history: Self) {
        for (key, value) in history.records {
            // Historical scans overlap live events. Replace, never add twice.
            if let current = records[key], current.tokens.total > value.tokens.total { continue }
            records[key] = value
        }
    }

    static func load(_ defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let ledger = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return ledger
    }
}

/// Incremental bounded line reader for both official and third-party rollout logs.
actor TurnTokenHistoryReader {
    private struct Cursor {
        var offset: UInt64 = 0
        var tail = Data()
        var skipping = false
        var turn: String?
        var ledger = TurnTokenUsageLedger()
    }
    private var cursors: [String: Cursor] = [:]

    func read(path: String, thread: String) -> TurnTokenUsageLedger {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .init() }
        defer { try? handle.close() }
        let key = thread + "\u{001F}" + path
        var cursor = cursors[key] ?? Cursor()
        do {
            let size = try handle.seekToEnd()
            if size < cursor.offset { cursor = Cursor() }
            try handle.seek(toOffset: cursor.offset)
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                cursor.offset += UInt64(chunk.count)
                cursor.tail.append(chunk)
                while let newline = cursor.tail.firstIndex(of: 10) {
                    let line = cursor.tail.prefix(upTo: newline)
                    if !cursor.skipping { Self.consume(line, thread: thread, cursor: &cursor) }
                    cursor.skipping = false
                    cursor.tail.removeSubrange(...newline)
                }
                if cursor.tail.count > 4 * 1024 * 1024 {
                    cursor.tail.removeAll()
                    cursor.skipping = true
                }
            }
            if cursors.count > 32 { cursors.removeAll() }
            cursors[key] = cursor
        } catch { return cursor.ledger }
        return cursor.ledger
    }

    private static func consume(_ data: Data.SubSequence, thread: String, cursor: inout Cursor) {
        guard let text = String(data: data, encoding: .utf8),
              text.contains("\"token_count\"") || text.contains("\"turn_context\"") || text.contains("\"task_started\""),
              let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = row["payload"] as? [String: Any] else { return }
        let type = row["type"] as? String
        if type == "turn_context" || (type == "event_msg" && payload["type"] as? String == "task_started") {
            cursor.turn = payload["turn_id"] as? String
            return
        }
        guard type == "event_msg", payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let totalJSON = info["total_token_usage"] as? [String: Any],
              let lastJSON = info["last_token_usage"] as? [String: Any],
              let total = tokens(totalJSON), let last = tokens(lastJSON) else { return }
        guard let turn = cursor.turn else {
            cursor.ledger.baselines[thread] = .init(turn: "", tokens: total)
            return
        }
        cursor.ledger.observe(thread: thread, turn: turn, total: total, last: last)
    }

    private static func tokens(_ json: [String: Any]) -> ProviderUsageLedger.Tokens? {
        ProviderUsageLedger.Tokens(json: [
            "inputTokens": json["input_tokens"] ?? NSNull(),
            "outputTokens": json["output_tokens"] ?? NSNull(),
            "totalTokens": json["total_tokens"] ?? NSNull(),
            "cachedInputTokens": json["cached_input_tokens"] ?? 0,
            "reasoningOutputTokens": json["reasoning_output_tokens"] ?? 0
        ])
    }
}
