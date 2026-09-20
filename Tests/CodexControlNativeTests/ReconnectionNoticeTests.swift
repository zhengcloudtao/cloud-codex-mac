import XCTest
@testable import CloudCodex

@MainActor
final class ReconnectionNoticeTests: XCTestCase {
    func testCapacityErrorCodeAndMessageAreRetryableButOtherFailuresAreNot() {
        XCTAssertTrue(CapacityRetryPolicy.isRetryable(error: [
            "message": "Selected model is at capacity. Please try a different model.",
            "codexErrorInfo": "serverOverloaded"
        ]))
        XCTAssertTrue(CapacityRetryPolicy.isRetryable(error: [
            "message": "Server overloaded; retry later."
        ]))
        XCTAssertFalse(CapacityRetryPolicy.isRetryable(error: [
            "message": "Permission denied",
            "codexErrorInfo": "unauthorized"
        ]))
        XCTAssertEqual(CapacityRetryPolicy.delay(attempt: 1, jitter: 0.5), 10)
        XCTAssertEqual(CapacityRetryPolicy.delay(attempt: 6, jitter: 0.5), 300)
        XCTAssertEqual(CapacityRetryPolicy.delay(attempt: 20, jitter: 0.5), 300)
    }

    func testFailedCapacityTurnStaysRunningAndKeepsRetryRecord() async throws {
        let suite = "capacity-retry-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(remoteDefaults: defaults)
        model.selectedThreadID = "one"
        model.handleEvent("turn/started", ["threadId": "one", "turn": ["id": "turn-one"]])
        model.handleEvent("turn/completed", [
            "threadId": "one",
            "turn": [
                "id": "turn-one",
                "status": "failed",
                "error": [
                    "message": "Selected model is at capacity. Please try a different model.",
                    "codexErrorInfo": "serverOverloaded"
                ]
            ]
        ])

        XCTAssertTrue(model.isSending)
        XCTAssertTrue(model.selectedHasCapacityRetry)
        XCTAssertEqual(model.capacityRetryAttempt(for: "one"), 1)
        XCTAssertEqual(model.threadOutcomes["one"], .running)
        let record = try XCTUnwrap(model.messages.first { $0.id == "capacity-retry-turn-one" })
        XCTAssertEqual(record.activityTitle, "模型繁忙，持续重试")
        XCTAssertEqual(record.activityStatus, "等待重试")
        XCTAssertTrue(record.text.contains("现有回复、执行过程、错误记录和文件修改都会保留"))

        await model.cancelTurn()
        XCTAssertFalse(model.isSending)
        XCTAssertFalse(model.selectedHasCapacityRetry)
        XCTAssertEqual(model.threadOutcomes["one"], .interrupted)
    }

    func testCapacityErrorFollowedByCompletedEventSchedulesOnlyOnce() async throws {
        let suite = "capacity-retry-paired-events-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(remoteDefaults: defaults)
        model.selectedThreadID = "one"
        model.handleEvent("turn/started", ["threadId": "one", "turn": ["id": "turn-one"]])
        let error: [String: Any] = [
            "message": "Selected model is at capacity. Please try a different model.",
            "codexErrorInfo": "serverOverloaded"
        ]
        model.handleEvent("error", [
            "threadId": "one", "turnId": "turn-one", "willRetry": false, "error": error
        ])
        model.handleEvent("turn/completed", [
            "threadId": "one",
            "turn": ["id": "turn-one", "status": "failed", "error": error]
        ])

        XCTAssertTrue(model.isSending)
        XCTAssertEqual(model.capacityRetryAttempt(for: "one"), 1)
        XCTAssertEqual(model.messages.filter { $0.id == "capacity-retry-turn-one" }.count, 1)
        await model.cancelTurn()
    }

    func testCapacityRetryStateSurvivesAppModelRestartUntilStopped() async throws {
        let suite = "capacity-retry-persistence-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let original = AppModel(remoteDefaults: defaults)
        original.selectedThreadID = "one"
        original.handleEvent("turn/started", ["threadId": "one", "turn": ["id": "turn-one"]])
        original.handleEvent("turn/completed", [
            "threadId": "one",
            "turn": [
                "id": "turn-one",
                "status": "failed",
                "error": [
                    "message": "Selected model is at capacity. Please try a different model.",
                    "codexErrorInfo": "serverOverloaded"
                ]
            ]
        ])

        let restored = AppModel(remoteDefaults: defaults)
        restored.selectedThreadID = "one"
        XCTAssertTrue(restored.selectedHasCapacityRetry)
        XCTAssertEqual(restored.capacityRetryAttempt(for: "one"), 1)

        await restored.cancelTurn()
        XCTAssertNil(defaults.data(forKey: "CloudCodex.capacityRetries.v1"))
        await original.cancelTurn()
    }

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
