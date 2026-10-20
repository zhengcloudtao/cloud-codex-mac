import Foundation

/// Incremental metadata-only scan. Conversation text is neither decoded nor saved.
/// Local observations have narrower coverage than account-wide quota.
actor CodexLocalTokenUsageReader {
    struct Summary: Equatable, Sendable {
        let tokens: Int64
        let eventCount: Int
        let fileCount: Int
        var cost = CodexAPIUsagePricing.Report()
    }
    private struct Point {
        let date: Date
        let delta: Int64
        let key: String
        let cost: CodexAPIUsagePricing.Line
        let threadID: String?
        let turnID: String?
        let tier: String?
    }
    private struct Cursor {
        var offset: UInt64 = 0
        var tail = Data()
        var skippingLongLine = false
        var threadID: String?
        var turnID: String?
        var model: String?
        var tier: String?
        var provider: String?
        var previousTotal: Int64?
        var points: [Point] = []
    }
    private let home: URL
    private var cursors: [URL: Cursor] = [:]
    private let formatter = ISO8601DateFormatter()

    init(home: URL? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let home { self.home = home }
        else if let path = environment["CODEX_HOME"], !path.isEmpty { self.home = URL(fileURLWithPath: path) }
        else { self.home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex") }
    }

    func read(since: Date, through: Date) throws -> Summary {
        let files = candidateFiles(since: since, through: through)
        let tierEntries = CodexUsageTierStore.load(home: home)
        var seen: Set<String> = []
        var tokens: Int64 = 0
        var eventCount = 0
        var fileCount = 0
        var cost = CodexAPIUsagePricing.Report()
        for file in files {
            var cursor = cursors[file] ?? Cursor()
            let size = (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            if UInt64(size) < cursor.offset { cursor = Cursor() }
            if UInt64(size) > cursor.offset {
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                try handle.seek(toOffset: cursor.offset)
                while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                    cursor.offset += UInt64(chunk.count)
                    cursor.tail.append(chunk)
                    while let newline = cursor.tail.firstIndex(of: 10) {
                        let line = cursor.tail.prefix(upTo: newline)
                        if !cursor.skippingLongLine { consume(line, cursor: &cursor) }
                        cursor.skippingLongLine = false
                        cursor.tail.removeSubrange(...newline)
                    }
                    if cursor.tail.count > 4 * 1024 * 1024 {
                        cursor.tail.removeAll(keepingCapacity: false)
                        cursor.skippingLongLine = true
                    }
                }
            }
            cursor.points.removeAll { $0.date < since }
            cursors[file] = cursor
            var used = false
            for point in cursor.points where point.date > since && point.date <= through {
                guard seen.insert(point.key).inserted else { continue }
                let sum = tokens.addingReportingOverflow(point.delta)
                guard !sum.overflow else { throw CocoaError(.coderInvalidValue) }
                tokens = sum.partialValue
                let entry = point.threadID.flatMap { thread in point.turnID.flatMap { tierEntries[thread + ":" + $0] } }
                cost.add(CodexAPIUsagePricing.line(model: point.cost.model,
                    tier: point.tier ?? entry?.tier,
                    tierSource: point.tier != nil ? "日志记录档位" : (entry?.source ?? "速度未知"),
                    tokens: point.cost.tokens, observedTokens: point.delta))
                eventCount += 1
                used = true
            }
            if used { fileCount += 1 }
        }
        // Retain only files in the current measurement's bounded date range.
        let retained = Set(files)
        cursors = cursors.filter { retained.contains($0.key) }
        return .init(tokens: tokens, eventCount: eventCount, fileCount: fileCount, cost: cost)
    }

    private func consume(_ line: Data.SubSequence, cursor: inout Cursor) {
        guard line.count < 4 * 1024 * 1024,
              let text = String(data: line, encoding: .utf8),
              text.contains("\"session_meta\"") || text.contains("\"token_count\"") || text.contains("\"turn_context\"") || text.contains("\"task_started\""),
              let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let payload = row["payload"] as? [String: Any] else { return }
        if row["type"] as? String == "session_meta" {
            cursor.threadID = payload["id"] as? String
            cursor.provider = payload["model_provider"] as? String
            return
        }
        if row["type"] as? String == "turn_context" {
            cursor.turnID = payload["turn_id"] as? String
            cursor.model = payload["model"] as? String
            cursor.tier = payload["service_tier"] as? String ?? payload["serviceTier"] as? String
            if let provider = payload["model_provider"] as? String { cursor.provider = provider }
            return
        }
        if row["type"] as? String == "event_msg", payload["type"] as? String == "task_started" {
            cursor.turnID = payload["turn_id"] as? String
            cursor.tier = nil
            cursor.model = nil
            return
        }
        guard row["type"] as? String == "event_msg",
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["total_token_usage"] as? [String: Any],
              let total = integer(usage["total_tokens"]),
              let stamp = row["timestamp"] as? String, let date = parseDate(stamp) else { return }
        let previous = cursor.previousTotal
        cursor.previousTotal = total
        // First cumulative reading may contain inherited/forked history. Establish
        // its baseline instead of charging that history to this observation.
        guard cursor.provider == "openai", let previous, total > previous else { return }
        let delta = total - previous
        // Price only the request whose actual usage reconciles to the fresh delta.
        // A coalesced/missing event must not be attributed to the current model.
        var categories: CodexAPIUsagePricing.Tokens?
        if let last = info["last_token_usage"] as? [String: Any], integer(last["total_tokens"]) == delta,
           let input = integer(last["input_tokens"]), let cached = integer(last["cached_input_tokens"]),
           let output = integer(last["output_tokens"]) {
            // Older log schemas lack cache writes. Do not silently price those as zero.
            if let writes = integer(last["cache_write_input_tokens"]) {
                let value = CodexAPIUsagePricing.Tokens(input: input, cached: cached, cacheWrite: writes, output: output)
                if value.valid && value.total == Double(delta) { categories = value }
            }
        }
        let cost = CodexAPIUsagePricing.line(model: cursor.model, tier: cursor.tier,
                                             tokens: categories, observedTokens: delta)
        cursor.points.append(.init(date: date, delta: delta, key: "\(stamp)|\(total)|\(delta)", cost: cost,
                                   threadID: cursor.threadID, turnID: cursor.turnID, tier: cursor.tier))
    }

    private func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.int64Value >= 0 else { return nil }
        return number.int64Value
    }

    private func parseDate(_ value: String) -> Date? {
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func candidateFiles(since: Date, through: Date) -> [URL] {
        // Old sessions can continue today; use modification time rather than
        // their creation-date directories to select readable files.
        let directories = [home.appendingPathComponent("sessions"), home.appendingPathComponent("archived_sessions")]
        var result: Set<URL> = []
        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in enumerator where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      values.isRegularFile == true,
                      (values.contentModificationDate ?? .distantPast) >= since else { continue }
                result.insert(file.standardizedFileURL)
            }
        }
        return result.sorted { $0.path < $1.path }
    }
}
