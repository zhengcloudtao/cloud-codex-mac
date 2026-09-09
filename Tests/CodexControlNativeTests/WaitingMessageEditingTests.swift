import XCTest
@testable import CloudCodex

@MainActor
final class WaitingMessageEditingTests: XCTestCase {
    private func message(_ text: String) -> AppModel.WaitingMessage {
        .init(threadID: "a", text: text,
              attachments: [ComposerAttachment(url: URL(fileURLWithPath: "/tmp/edit.png"))],
              model: "test-model", effort: "high", permissions: "read-only", serviceTier: nil)
    }

    func testSavePreservesIdentityOrderAttachmentsAndComposerDraft() {
        let model = AppModel()
        let first = message("原内容")
        let second = message("第二条")
        model.waitingMessages = [first, second]
        model.composerText = "主输入框草稿"
        model.beginEditingWaitingMessage(first.id)
        model.waitingMessageEditText = " 新内容 "
        model.saveWaitingMessageEdit()
        XCTAssertEqual(model.waitingMessages.map(\.id), [first.id, second.id])
        XCTAssertEqual(model.waitingMessages[0].text, "新内容")
        XCTAssertEqual(model.waitingMessages[0].attachments, first.attachments)
        XCTAssertEqual(model.waitingMessages[0].model, first.model)
        XCTAssertEqual(model.waitingMessages[0].effort, first.effort)
        XCTAssertEqual(model.waitingMessages[0].permissions, first.permissions)
        XCTAssertEqual(model.composerText, "主输入框草稿")
        XCTAssertNil(model.editingWaitingMessageID)
    }

    func testEditingBlocksBothDeliveryPathsAndCancelRestoresOriginal() async {
        let model = AppModel()
        let item = message("原内容")
        model.waitingMessages = [item]
        model.beginEditingWaitingMessage(item.id)
        model.waitingMessageEditText = "未保存"
        await model.deliverWaitingMessage(item.id, steer: false)
        await model.deliverWaitingMessage(item.id, steer: true)
        XCTAssertNil(model.waitingMessages[0].error, "Editing must prevent requests, not fail after trying them")
        XCTAssertTrue(model.deliveringWaitingMessages.isEmpty)
        model.cancelWaitingMessageEdit()
        XCTAssertEqual(model.waitingMessages[0].text, "原内容")
        XCTAssertNil(model.editingWaitingMessageID)
    }

    func testEmptyTextRequiresAttachmentAndDeletionClosesEditor() {
        let model = AppModel()
        let item = AppModel.WaitingMessage(threadID: "a", text: "原内容", attachments: [],
            model: nil, effort: nil, permissions: nil, serviceTier: nil)
        model.waitingMessages = [item]
        model.beginEditingWaitingMessage(item.id)
        model.waitingMessageEditText = " \n "
        XCTAssertFalse(model.canSaveWaitingMessageEdit)
        model.saveWaitingMessageEdit()
        XCTAssertEqual(model.waitingMessages[0].text, "原内容")
        model.removeWaitingMessage(item.id)
        XCTAssertNil(model.editingWaitingMessageID)
        XCTAssertTrue(model.waitingMessages.isEmpty)
    }
}
