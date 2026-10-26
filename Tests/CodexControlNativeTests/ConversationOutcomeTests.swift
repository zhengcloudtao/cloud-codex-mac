import XCTest
@testable import CloudCodex

@MainActor
final class ConversationOutcomeTests: XCTestCase {
    func testUnopenedRowsGetConfirmedOutcomesAndReuseCache() async {
        let model = AppModel()
        let rows = ["done", "failed", "stopped", "empty"].map {
            CodexThread(json: ["id": $0, "cwd": "/tmp", "status": ["type": "idle"], "updatedAt": 10])!
        }
        model.applyThreadListSnapshot(rows)
        model.selectedThreadID = "unrelated"
        var calls = 0
        let fetch: (String) async throws -> TurnRuntimeState? = { id in
            calls += 1
            guard id != "empty" else { return nil }
            return TurnRuntimeState(id: "turn", status: id == "done" ? "completed" : id == "failed" ? "failed" : "interrupted", startedAt: nil, completedAt: nil)
        }
        await model.refreshThreadOutcomes(rows, fetch: fetch)
        XCTAssertEqual(model.threadOutcomes["done"], .completed)
        XCTAssertEqual(model.threadOutcomes["failed"], .failed)
        XCTAssertEqual(model.threadOutcomes["stopped"], .interrupted)
        XCTAssertNil(model.threadOutcomes["empty"])
        XCTAssertEqual(model.selectedThreadID, "unrelated")
        XCTAssertTrue(model.messages.isEmpty)
        await model.refreshThreadOutcomes(rows, fetch: fetch)
        XCTAssertEqual(calls, 4)
        var changed = rows[0]
        changed.updatedAt = Date(timeIntervalSince1970: 20)
        model.applyThreadListSnapshot([changed] + Array(rows.dropFirst()))
        await model.refreshThreadOutcomes([changed], fetch: fetch)
        XCTAssertEqual(calls, 5)
    }

    func testBackgroundResultCannotOverrideNewRunningTurn() async {
        let model = AppModel()
        let thread = CodexThread(json: ["id": "a", "cwd": "/tmp", "status": ["type": "idle"]])!
        model.applyThreadListSnapshot([thread])
        await model.refreshThreadOutcomes([thread]) { _ in
            model.handleEvent("turn/started", ["threadId": "a", "turn": ["id": "new"]])
            return TurnRuntimeState(id: "old", status: "completed", startedAt: nil, completedAt: nil)
        }
        XCTAssertEqual(model.conversationOutcome(for: thread), .running)
    }

    func testLiveFailureWinsOverOlderBackgroundCompletion() async {
        let model = AppModel()
        let thread = CodexThread(json: ["id": "a", "cwd": "/tmp", "status": ["type": "idle"]])!
        model.applyThreadListSnapshot([thread])
        await model.refreshThreadOutcomes([thread]) { _ in
            model.handleEvent("turn/completed", ["threadId": "a", "turn": ["id": "new", "status": "failed"]])
            return TurnRuntimeState(id: "old", status: "completed", startedAt: nil, completedAt: nil)
        }
        XCTAssertEqual(model.threadOutcomes["a"], .failed)
    }

    func testCompletionAndNextTurnReset() {
        let model = AppModel()
        let thread = CodexThread(json: ["id": "a", "cwd": "/tmp", "status": ["type": "idle"]])!
        model.selectedThreadID = "another"
        XCTAssertNil(model.conversationOutcome(for: thread))
        model.handleEvent("turn/started", ["threadId": "a", "turn": ["id": "one"]])
        XCTAssertEqual(model.conversationOutcome(for: thread), .running)
        model.handleEvent("turn/completed", ["threadId": "a", "turn": ["id": "one", "status": "completed"]])
        XCTAssertEqual(model.conversationOutcome(for: thread), .completed)
        model.applyVisibleThreadStatuses(["a": "idle"])
        XCTAssertEqual(model.conversationOutcome(for: thread), .completed)
        model.handleEvent("turn/started", ["threadId": "a", "turn": ["id": "two"]])
        XCTAssertEqual(model.conversationOutcome(for: thread), .running)
        model.handleEvent("turn/completed", ["threadId": "a", "turn": ["id": "one", "status": "completed"]])
        XCTAssertEqual(model.conversationOutcome(for: thread), .running)
        model.handleEvent("turn/completed", ["threadId": "a", "turn": ["id": "two", "status": "interrupted"]])
        XCTAssertEqual(model.conversationOutcome(for: thread), .interrupted)
    }

    func testFailureAndUnknownAreNotSuccess() {
        for status in ["failed", "unknown"] {
            let model = AppModel()
            model.handleEvent("turn/completed", ["threadId": "a", "turn": ["id": "one", "status": status]])
            XCTAssertEqual(model.threadOutcomes["a"], status == "failed" ? .failed : nil)
        }
    }

    func testHistoricalResultRestoredFromConfirmedSnapshot() {
        let model = AppModel()
        model.selectedThreadID = "a"
        let thread = CodexThread(json: ["id": "a", "cwd": "/tmp", "status": ["type": "idle"]])!
        let snapshot = ThreadActivitySnapshot(thread: thread,
            turn: TurnRuntimeState(id: "one", status: "completed", startedAt: nil, completedAt: nil), messages: [])
        model.applyExternalActivitySnapshot(snapshot, threadID: "a")
        XCTAssertEqual(model.conversationOutcome(for: thread), .completed)
    }
}
