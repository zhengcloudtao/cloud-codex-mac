import XCTest
@testable import CloudCodex

@MainActor
final class InterruptedMessageEditingTests: XCTestCase {
    func testOnlyLatestUserMessageOfStoppedTurnCanBeEdited() {
        let model = AppModel()
        let older = ChatMessage(id: "older", role: .user, text: "较早任务", turnID: "turn-old")
        let latest = ChatMessage(
            id: "latest",
            role: .user,
            text: "暂停后修改我",
            attachments: [ChatMessageAttachment(path: "/tmp/reference.png", kind: .image)],
            turnID: "turn-stop"
        )
        model.selectedThreadID = "thread"
        model.messages = [older, latest]
        model.handleEvent("turn/completed", [
            "threadId": "thread",
            "turn": ["id": "turn-stop", "status": "interrupted"]
        ])

        XCTAssertFalse(model.canEditInterruptedMessage(older))
        XCTAssertTrue(model.canEditInterruptedMessage(latest))
        model.beginEditingInterruptedMessage(latest)
        XCTAssertTrue(model.isEditingInterruptedMessage(latest.id))
        XCTAssertEqual(model.interruptedMessageEditText, "暂停后修改我")
        XCTAssertEqual(model.interruptedMessageEdit?.attachments.map(\.url.path), ["/tmp/reference.png"])
        XCTAssertTrue(model.canSubmitInterruptedMessageEdit)

        model.cancelInterruptedMessageEdit()
        XCTAssertNil(model.interruptedMessageEdit)
        XCTAssertTrue(model.interruptedMessageEditText.isEmpty)
    }

    func testRunningAndCompletedTurnsCannotEnterStoppedEditMode() {
        let model = AppModel()
        let message = ChatMessage(id: "user", role: .user, text: "任务", turnID: "turn")
        model.selectedThreadID = "thread"
        model.messages = [message]

        model.handleEvent("turn/started", ["threadId": "thread", "turn": ["id": "turn"]])
        XCTAssertFalse(model.canEditInterruptedMessage(message))
        model.handleEvent("turn/completed", ["threadId": "thread", "turn": ["id": "turn", "status": "completed"]])
        XCTAssertFalse(model.canEditInterruptedMessage(message))
    }

    func testRevertUsesExactStoppedTurnBoundary() {
        let parameters = AppServerClient.threadRevertParameters(
            threadID: "thread-a",
            beforeTurnID: "turn-stopped"
        )
        XCTAssertEqual(parameters["threadId"] as? String, "thread-a")
        XCTAssertEqual(parameters["beforeTurnId"] as? String, "turn-stopped")
        XCTAssertEqual(parameters.count, 2)
    }
}
