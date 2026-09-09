import XCTest
@testable import CloudCodex

@MainActor
final class ConversationOutcomeTests: XCTestCase {
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
