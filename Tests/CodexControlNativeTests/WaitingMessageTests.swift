import XCTest
@testable import CloudCodex

@MainActor
final class WaitingMessageTests: XCTestCase {
    func testRunningConversationQueuesInOrderAndKeepsAttachments() async {
        let model = AppModel()
        model.selectedThreadID = "one"
        model.handleEvent("turn/started", ["threadId": "one", "turn": ["id": "running"]])
        model.composerText = "补充要求"
        let attachment = ComposerAttachment(url: URL(fileURLWithPath: "/tmp/example.png"))
        model.attachments = [attachment]
        XCTAssertTrue(model.canSend)
        await model.sendMessage()
        model.composerText = "下一项"
        await model.sendMessage()
        XCTAssertEqual(model.waitingMessages.map(\.text), ["补充要求", "下一项"])
        XCTAssertEqual(model.waitingMessages.first?.attachments, [attachment])
        XCTAssertEqual(model.activeTurnID, "running")
        XCTAssertEqual(model.composerText, "")
        XCTAssertTrue(model.attachments.isEmpty)
        model.selectedThreadID = "two"
        XCTAssertTrue(model.selectedWaitingMessages.isEmpty)
        model.selectedThreadID = "one"
        XCTAssertEqual(model.selectedWaitingMessages.count, 2)
        for item in model.waitingMessages { model.removeWaitingMessage(item.id) }
    }

    func testFailedDeliveryKeepsQueuedMessageAndNewDraft() async {
        let model = AppModel()
        model.selectedThreadID = "one"
        model.isExternalThreadProcessing = true
        model.composerText = "保留我"
        await model.sendMessage()
        let item = model.waitingMessages[0]
        model.composerText = "尚未发送的新草稿"
        await model.deliverWaitingMessage(item.id, steer: true)
        XCTAssertEqual(model.waitingMessages.first?.text, "保留我")
        XCTAssertNotNil(model.waitingMessages.first?.error)
        XCTAssertEqual(model.composerText, "尚未发送的新草稿")
        XCTAssertTrue(model.deliveringWaitingMessages.isEmpty)
        model.removeWaitingMessage(item.id)
    }
}
