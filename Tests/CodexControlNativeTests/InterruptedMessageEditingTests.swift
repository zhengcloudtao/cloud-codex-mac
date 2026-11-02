import AppKit
import XCTest
@testable import CloudCodex

@MainActor
final class InterruptedMessageEditingTests: XCTestCase {
    func testPastedImageBelongsToEditAndCanBeRemoved() throws {
        let model = AppModel()
        let message = ChatMessage(id: "user", role: .user, text: "任务", turnID: "stopped")
        model.selectedThreadID = "thread"
        model.messages = [message]
        model.handleEvent("turn/completed", [
            "threadId": "thread", "turn": ["id": "stopped", "status": "interrupted"]
        ])
        model.beginEditingInterruptedMessage(message)
        model.interruptedMessageEditText = ""
        let pasteboard = NSPasteboard(name: .init("CloudCodexTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        pasteboard.setData(png, forType: .png)
        XCTAssertTrue(model.pasteInterruptedMessageImages(from: pasteboard))
        let attachment = try XCTUnwrap(model.interruptedMessageEdit?.attachments.first)
        defer { try? FileManager.default.removeItem(at: attachment.url) }
        XCTAssertEqual(try Data(contentsOf: attachment.url), png)
        XCTAssertEqual(attachment.userInput["type"] as? String, "localImage")
        XCTAssertTrue(model.attachments.isEmpty)
        XCTAssertTrue(model.newThreadAttachments.isEmpty)
        XCTAssertTrue(model.canSubmitInterruptedMessageEdit)
        XCTAssertTrue(model.messages[0].attachments.isEmpty)
        model.removeInterruptedMessageAttachment(attachment.id)
        XCTAssertFalse(model.canSubmitInterruptedMessageEdit)
        pasteboard.clearContents()
        pasteboard.setString("普通文字", forType: .string)
        XCTAssertFalse(model.pasteInterruptedMessageImages(from: pasteboard))
        model.cancelInterruptedMessageEdit()
        XCTAssertFalse(model.pasteInterruptedMessageImages(from: pasteboard))
    }

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

    func testBackgroundConfirmationKeepsEditorAndDraftUntilCancelled() throws {
        let model = AppModel()
        let local = ChatMessage(id: "local-question", role: .user, text: "原始问题", turnID: "stopped")
        let confirmed = ChatMessage(id: "server-question", role: .user, text: "原始问题", turnID: "stopped")
        let thread = try XCTUnwrap(CodexThread(json: ["id": "thread", "cwd": "/tmp", "status": "idle"]))
        let snapshot = ThreadActivitySnapshot(
            thread: thread,
            turn: TurnRuntimeState(id: "stopped", status: "interrupted", startedAt: nil, completedAt: nil),
            messages: [confirmed]
        )
        model.selectedThreadID = thread.id
        model.messages = [local]
        model.handleEvent("turn/completed", [
            "threadId": thread.id, "turn": ["id": "stopped", "status": "interrupted"]
        ])
        model.beginEditingInterruptedMessage(local)
        model.interruptedMessageEditText = "正在修改的草稿"
        let focusRequest = model.interruptedMessageEditFocusRequest

        for _ in 0..<3 {
            model.applyExternalActivitySnapshot(snapshot, threadID: thread.id)
            let displayed = try XCTUnwrap(model.messages.first(where: { $0.role == .user }))
            XCTAssertEqual(displayed.id, local.id)
            XCTAssertTrue(model.isEditingInterruptedMessage(displayed.id))
            XCTAssertEqual(model.interruptedMessageEditText, "正在修改的草稿")
            XCTAssertEqual(model.interruptedMessageEditFocusRequest, focusRequest)
            XCTAssertEqual(model.messages.filter { $0.role == .user }.count, 1)
        }

        model.cancelInterruptedMessageEdit()
        model.applyExternalActivitySnapshot(snapshot, threadID: thread.id)
        XCTAssertEqual(model.messages.filter { $0.role == .user }.map(\.id), [confirmed.id])
        XCTAssertTrue(model.canEditInterruptedMessage(confirmed))
        model.beginEditingInterruptedMessage(confirmed)
        XCTAssertTrue(model.isEditingInterruptedMessage(confirmed.id))
    }
}
