import XCTest
@testable import CloudCodex

@MainActor
final class ReconnectionNoticeTests: XCTestCase {
    func testRetryStaysRunningAndUpdatesOneVisibleInlineNotice() throws {
        let model = AppModel()
        model.selectedThreadID = "one"
        model.handleEvent("turn/started", ["threadId": "one", "turn": ["id": "turn-one"]])
        for attempt in 1...3 {
            model.handleEvent("error", ["threadId": "one", "turnId": "turn-one",
                "willRetry": true, "error": ["message": "Reconnecting... \(attempt)/5"]])
        }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isSending)
        let notices = model.messages.filter { $0.id.hasPrefix("connection-notice-") }
        XCTAssertEqual(notices.count, 1)
        let notice = try XCTUnwrap(notices.first)
        XCTAssertEqual(notice.text, "Reconnecting... 3/5")
        XCTAssertTrue(ConversationTimeline.entries(from: model.messages).contains(.message(notice)))
        model.handleEvent("item/started", ["threadId": "one", "item": ["id": "step", "type": "reasoning"]])
        XCTAssertEqual(model.messages.first { $0.id == notice.id }?.activityStatus, "已恢复")
    }

    func testBackgroundTerminalErrorIsInlineAndDoesNotInterruptSelectedTask() {
        let model = AppModel()
        model.selectedThreadID = "one"
        model.handleEvent("turn/started", ["threadId": "one", "turn": ["id": "turn-one"]])
        model.handleEvent("turn/started", ["threadId": "two", "turn": ["id": "turn-two"]])
        model.handleEvent("error", ["threadId": "two", "willRetry": false,
            "error": ["message": "Connection failed"]])
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isSending)
        XCTAssertFalse(model.messages.contains { $0.id.hasPrefix("connection-notice-") })
        XCTAssertEqual(model.conversationMessages(for: "two").last?.activityStatus, "失败")
    }

    func testUnscopedRetryDoesNotFailSelectedConversation() {
        let model = AppModel()
        model.selectedThreadID = "one"
        model.handleEvent("turn/started", ["threadId": "one", "turn": ["id": "turn-one"]])
        model.handleEvent("error", ["willRetry": true, "error": ["message": "Reconnecting... 2/5"]])
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.isSending)
        XCTAssertEqual(model.connectionText, "Reconnecting... 2/5")
    }
}
