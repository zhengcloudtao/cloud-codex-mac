import XCTest
@testable import CloudCodex

final class TurnTokenUsageTests: XCTestCase {
    private func tokens(_ input: Int, _ output: Int) -> ProviderUsageLedger.Tokens {
        .init(json: ["inputTokens": input, "outputTokens": output, "totalTokens": input + output,
                     "cachedInputTokens": 0, "reasoningOutputTokens": 0])!
    }

    func testMultipleCallsAndTurnsAndRestartDoNotDoubleCount() throws {
        var ledger = TurnTokenUsageLedger()
        ledger.observe(thread: "t", turn: "a", total: tokens(100, 20), last: tokens(100, 20))
        ledger.observe(thread: "t", turn: "a", total: tokens(150, 30), last: tokens(50, 10))
        ledger = try JSONDecoder().decode(TurnTokenUsageLedger.self, from: JSONEncoder().encode(ledger))
        ledger.observe(thread: "t", turn: "a", total: tokens(150, 30), last: tokens(50, 10))
        ledger.observe(thread: "t", turn: "b", total: tokens(170, 35), last: tokens(20, 5))
        XCTAssertEqual(ledger.record(thread: "t", turn: "a")?.tokens.total, 180)
        XCTAssertEqual(ledger.record(thread: "t", turn: "b")?.tokens.total, 25)
        XCTAssertEqual(ledger.record(thread: "t", turn: "b")?.partial, false)
    }

    func testInheritedHistoryAndCrossTurnGapsAreMarkedPartial() {
        var ledger = TurnTokenUsageLedger()
        ledger.observe(thread: "t", turn: "a", total: tokens(1000, 200), last: tokens(10, 2))
        XCTAssertEqual(ledger.record(thread: "t", turn: "a")?.tokens.total, 12)
        XCTAssertEqual(ledger.record(thread: "t", turn: "a")?.partial, true)
        ledger.observe(thread: "t", turn: "b", total: tokens(2000, 400), last: tokens(20, 4))
        XCTAssertEqual(ledger.record(thread: "t", turn: "b")?.tokens.total, 24)
        XCTAssertEqual(ledger.record(thread: "t", turn: "b")?.partial, true)
    }

    func testHistoryReadsBothProvidersIncrementallyAndIgnoresDuplicateEvents() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        func event(_ total: Int, _ last: Int) -> String {
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(total),\"output_tokens\":0,\"total_tokens\":\(total)},\"last_token_usage\":{\"input_tokens\":\(last),\"output_tokens\":0,\"total_tokens\":\(last)}}}}\n"
        }
        let start = "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"a\",\"model_provider\":\"custom\"}}\n"
        try (start + event(10, 10) + event(10, 10)).write(to: url, atomically: true, encoding: .utf8)
        let reader = TurnTokenHistoryReader()
        let first = await reader.read(path: url.path, thread: "t")
        XCTAssertEqual(first.record(thread: "t", turn: "a")?.tokens.total, 10)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((event(30, 20) + "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"b\",\"model_provider\":\"openai\"}}\n" + event(35, 5)).utf8))
        try handle.close()
        let second = await reader.read(path: url.path, thread: "t")
        XCTAssertEqual(second.record(thread: "t", turn: "a")?.tokens.total, 30)
        XCTAssertEqual(second.record(thread: "t", turn: "b")?.tokens.total, 5)
        var merged = first
        merged.merge(second)
        merged.merge(second)
        XCTAssertEqual(merged.record(thread: "t", turn: "a")?.tokens.total, 30)
    }

    @MainActor
    func testOfficialUsageIsRecordedWithoutCustomProviderAndFooterOnlyOnLastAnswer() {
        let suite = "turn-token-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppModel(remoteDefaults: defaults)
        let usage: [String: Any] = ["inputTokens": 10, "outputTokens": 2, "totalTokens": 12,
                                   "cachedInputTokens": 0, "reasoningOutputTokens": 0]
        app.handleEvent("thread/tokenUsage/updated", ["threadId": "t", "turnId": "a", "tokenUsage": ["last": usage, "total": usage]])
        XCTAssertEqual(app.turnTokenUsage.record(thread: "t", turn: "a")?.tokens.total, 12)
        XCTAssertEqual(TurnTokenUsageLedger.load(defaults).record(thread: "t", turn: "a")?.tokens.total, 12)
        app.selectedThreadID = "t"
        let first = ChatMessage(id: "progress", role: .assistant, text: "Working", turnID: "a")
        let final = ChatMessage(id: "answer", role: .assistant, text: "Done", turnID: "a")
        app.messages = [first, final]
        XCTAssertFalse(app.showsTokenUsage(for: first))
        XCTAssertTrue(app.showsTokenUsage(for: final))
        XCTAssertEqual(app.tokenUsage(for: final)?.tokens.total, 12)
        app.selectedThreadID = "another"
        XCTAssertNil(app.tokenUsage(for: final))

    }
}
