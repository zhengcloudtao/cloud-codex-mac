import XCTest
@testable import CloudCodex

final class CodexLocalTokenUsageReaderTests: XCTestCase {
    private let anchor = Date().addingTimeInterval(-600)
    private func row(_ offset: Double, total: Int, provider: String? = nil) -> [String: Any] {
        if let provider { return ["type": "session_meta", "payload": ["model_provider": provider]] }
        return ["timestamp": ISO8601DateFormatter().string(from: anchor.addingTimeInterval(offset)),
                "type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["total_tokens": total]]]]
    }
    private func write(_ rows: [[String: Any]], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for row in rows { data.append(try JSONSerialization.data(withJSONObject: row)); data.append(10) }
        try data.write(to: file)
    }
    private func home() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudCodexLocalQuota-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testCountsOnlySamePeriodDeltasAndIncrementalAppendDoesNotDoubleCount() async throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("sessions/2020/01/01/old-active.jsonl")
        try write([row(0, total: 0, provider: "openai"), row(50, total: 100), row(150, total: 160), row(200, total: 200), row(200, total: 200)], to: file)
        let reader = CodexLocalTokenUsageReader(home: root)
        let since = anchor.addingTimeInterval(100), end = anchor.addingTimeInterval(300)
        let first = try await reader.read(since: since, through: end)
        XCTAssertEqual(first.tokens, 100)
        XCTAssertEqual(first.eventCount, 2)
        let second = try await reader.read(since: since, through: end)
        XCTAssertEqual(second, first)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        var appended = try JSONSerialization.data(withJSONObject: row(250, total: 250))
        try handle.write(contentsOf: appended)
        let partial = try await reader.read(since: since, through: end)
        XCTAssertEqual(partial.tokens, 100, "Unfinished JSONL rows must wait for their newline")
        appended = Data([10]); try handle.write(contentsOf: appended); try handle.close()
        let completed = try await reader.read(since: since, through: end)
        XCTAssertEqual(completed.tokens, 150)
    }

    func testArchivedCopiesAreDeduplicatedAndOtherProvidersExcluded() async throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = [row(0, total: 0, provider: "openai"), row(50, total: 100), row(150, total: 160)]
        try write(rows, to: root.appendingPathComponent("sessions/2020/01/01/a.jsonl"))
        try write(rows, to: root.appendingPathComponent("archived_sessions/a.jsonl"))
        try write([row(0, total: 0, provider: "deepseek"), row(50, total: 100), row(150, total: 900)],
                  to: root.appendingPathComponent("sessions/2020/01/01/b.jsonl"))
        let value = try await CodexLocalTokenUsageReader(home: root).read(since: anchor.addingTimeInterval(100), through: anchor.addingTimeInterval(300))
        XCTAssertEqual(value.tokens, 60)
        XCTAssertEqual(value.eventCount, 1)
    }

    func testInheritedInitialTotalsAndCounterResetsDoNotBecomeFreshUsage() async throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        try write([row(0, total: 0, provider: "openai"), row(150, total: 100000), row(160, total: 100100),
                   row(170, total: 20), row(180, total: 50)], to: root.appendingPathComponent("sessions/2020/01/01/a.jsonl"))
        let value = try await CodexLocalTokenUsageReader(home: root).read(since: anchor.addingTimeInterval(100), through: anchor.addingTimeInterval(300))
        XCTAssertEqual(value.tokens, 130)
    }

    func testProviderChangesDoNotBridgeThirdPartyUsageIntoOpenAI() async throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        try write([row(0, total: 0, provider: "openai"), row(50, total: 100), row(150, total: 150),
            ["type": "turn_context", "payload": ["model_provider": "other"]], row(160, total: 500),
            ["type": "turn_context", "payload": ["model_provider": "openai"]], row(180, total: 600)],
            to: root.appendingPathComponent("sessions/2020/01/01/a.jsonl"))
        let value = try await CodexLocalTokenUsageReader(home: root).read(since: anchor.addingTimeInterval(100), through: anchor.addingTimeInterval(300))
        XCTAssertEqual(value.tokens, 150)
    }

    func testModelSwitchesUseActualRequestCategoriesAndPreserveCostsIncrementally() async throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        func event(_ offset: Double, total: Int, input: Int, cached: Int, output: Int) -> [String: Any] {
            ["timestamp": ISO8601DateFormatter().string(from: anchor.addingTimeInterval(offset)),
             "type": "event_msg", "payload": ["type": "token_count", "info": [
                "total_token_usage": ["total_tokens": total],
                "last_token_usage": ["total_tokens": input + output, "input_tokens": input,
                    "cached_input_tokens": cached, "cache_write_input_tokens": 0,
                    "output_tokens": output, "reasoning_output_tokens": output / 2]]]]
        }
        let rows = [row(0, total: 0, provider: "openai"), row(50, total: 1000),
            ["type": "turn_context", "payload": ["model": "gpt-6.1-sol", "service_tier": "default"]],
            event(150, total: 111000, input: 100000, cached: 60000, output: 10000),
            ["type": "turn_context", "payload": ["model": "gpt-5.6-luna", "service_tier": "default"]],
            event(200, total: 122000, input: 10000, cached: 0, output: 1000)]
        try write(rows, to: root.appendingPathComponent("sessions/a.jsonl"))
        let reader = CodexLocalTokenUsageReader(home: root)
        let result = try await reader.read(since: anchor.addingTimeInterval(100), through: anchor.addingTimeInterval(300))
        XCTAssertTrue(result.cost.complete)
        XCTAssertEqual(result.cost.lines.count, 2)
        XCTAssertEqual(result.cost.knownDollars, 0.1892, accuracy: 1e-12)
        let again = try await reader.read(since: anchor.addingTimeInterval(100), through: anchor.addingTimeInterval(300))
        XCTAssertEqual(result, again)
        let trimmed = try await reader.read(since: anchor.addingTimeInterval(175), through: anchor.addingTimeInterval(300))
        XCTAssertEqual(trimmed.cost.lines.count, 1)
        XCTAssertEqual(trimmed.cost.knownDollars, 0.0032, accuracy: 1e-12)
    }

    func testTierSidecarJoinsExactTurnAndRepricesCachedEventsWithoutCurrentSwitch() async throws {
        let root = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        func usage(_ time: Double, _ total: Int) -> [String: Any] {
            ["timestamp": ISO8601DateFormatter().string(from: anchor.addingTimeInterval(time)),
             "type": "event_msg", "payload": ["type": "token_count", "info": [
                "total_token_usage": ["total_tokens": total],
                "last_token_usage": ["total_tokens": 110, "input_tokens": 100,
                    "cached_input_tokens": 0, "cache_write_input_tokens": 0, "output_tokens": 10]]]]
        }
        try write([
            ["type": "session_meta", "payload": ["id": "thread-A", "model_provider": "openai"]],
            row(50, total: 1000),
            ["type": "turn_context", "payload": ["turn_id": "turn-fast", "model": "gpt-6.1-sol"]],
            usage(150, 1110),
            ["type": "turn_context", "payload": ["turn_id": "turn-standard", "model": "gpt-6.1-sol"]],
            usage(200, 1220),
            ["type": "turn_context", "payload": ["turn_id": "other-client", "model": "gpt-6.1-sol"]],
            usage(250, 1330)], to: root.appendingPathComponent("sessions/a.jsonl"))
        let reader = CodexLocalTokenUsageReader(home: root)
        let start = anchor.addingTimeInterval(100), end = anchor.addingTimeInterval(300)
        let unknown = try await reader.read(since: start, through: end)
        XCTAssertEqual(unknown.cost.unpricedTokens, 330)
        CodexUsageTierStore.acceptedTurn(threadID: "thread-A", result: ["turn": ["id": "turn-fast"]], requested: "priority", home: root)
        // The returned API tier takes precedence over the requested Fast tier.
        CodexUsageTierStore.acceptedTurn(threadID: "thread-A", result: ["turn": ["id": "turn-standard", "response": ["service_tier": "default"]]], requested: "priority", home: root)
        let known = try await reader.read(since: start, through: end)
        XCTAssertEqual(known.tokens, 330)
        XCTAssertEqual(known.cost.unpricedTokens, 110)
        XCTAssertEqual(known.cost.knownDollars, 0.0009, accuracy: 1e-12)
        XCTAssertTrue(known.cost.lines.contains { $0.basis.contains("Fast") && $0.basis.contains("实际档未返回") })
        XCTAssertTrue(known.cost.lines.contains { $0.basis.contains("Standard") && $0.basis.contains("API 返回档位") })
        // A later acknowledgement cannot overwrite the observed downgrade.
        CodexUsageTierStore.acceptedTurn(threadID: "thread-A", result: ["turn": ["id": "turn-standard"]], requested: "priority", home: root)
        XCTAssertEqual(CodexUsageTierStore.load(home: root)["thread-A:turn-standard"]?.tier, "default")
        // Another thread's identical turn ID must not contaminate this thread.
        CodexUsageTierStore.acceptedTurn(threadID: "thread-B", result: ["turn": ["id": "other-client"]], requested: "priority", home: root)
        let isolated = try await reader.read(since: start, through: end)
        XCTAssertEqual(isolated.cost.unpricedTokens, 110)
    }


}
