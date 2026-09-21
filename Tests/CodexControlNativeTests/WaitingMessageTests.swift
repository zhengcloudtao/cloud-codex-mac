import XCTest
@testable import CloudCodex

@MainActor
final class WaitingMessageTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "CloudCodexTests.waiting.case.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    private func message(_ text: String, threadID: String = "one") -> AppModel.WaitingMessage {
        .init(threadID: threadID, text: text, attachments: [], model: nil,
              effort: nil, permissions: nil, serviceTier: nil)
    }

    func testQueueViewportShowsCompleteRowsAndCapsAtThree() {
        XCTAssertEqual(WaitingQueueLayout.viewportHeight(for: 0), 0)
        XCTAssertEqual(
            WaitingQueueLayout.viewportHeight(for: 1),
            WaitingQueueLayout.rowHeight
        )
        XCTAssertEqual(
            WaitingQueueLayout.viewportHeight(for: 3),
            WaitingQueueLayout.rowHeight * 3 + WaitingQueueLayout.rowSpacing * 2
        )
        XCTAssertEqual(
            WaitingQueueLayout.viewportHeight(for: 5),
            WaitingQueueLayout.viewportHeight(for: 3),
            "Additional queued tasks should scroll instead of clipping a partial fourth row"
        )
    }

    func testRunningConversationQueuesInOrderAndKeepsAttachments() async {
        let model = AppModel(remoteDefaults: defaults)
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
        let model = AppModel(remoteDefaults: defaults)
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

    func testWaitingMessagesCanMoveBeforeAndAfterWithinTheSameThread() {
        let model = AppModel(remoteDefaults: defaults)
        let first = message("第一条")
        let second = message("第二条")
        let third = message("第三条")
        model.waitingMessages = [first, second, third]

        XCTAssertTrue(model.moveWaitingMessage(third.id, relativeTo: first.id, placeAfter: false))
        XCTAssertEqual(model.waitingMessages.map(\.text), ["第三条", "第一条", "第二条"])

        XCTAssertTrue(model.moveWaitingMessage(third.id, relativeTo: second.id, placeAfter: true))
        XCTAssertEqual(model.waitingMessages.map(\.text), ["第一条", "第二条", "第三条"])
    }

    func testWaitingMessagesCannotMoveAcrossThreads() {
        let model = AppModel(remoteDefaults: defaults)
        let first = message("第一条", threadID: "one")
        let other = message("另一会话", threadID: "two")
        model.waitingMessages = [first, other]

        XCTAssertFalse(model.moveWaitingMessage(first.id, relativeTo: other.id, placeAfter: false))
        XCTAssertEqual(model.waitingMessages.map(\.id), [first.id, other.id])
    }

    func testWaitingMessagesRestoreAfterAppModelRestartWithOrderAndSettings() {
        let suiteName = "CloudCodexTests.waiting.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(remoteDefaults: defaults)
        let first = AppModel.WaitingMessage(threadID: "thread-a", text: "第一条",
            attachments: [ComposerAttachment(url: URL(fileURLWithPath: "/tmp/queue image.png"))],
            model: "gpt-6-astra", effort: "high", permissions: "full", serviceTier: "fast")
        let second = AppModel.WaitingMessage(threadID: "thread-a", text: "第二条", attachments: [],
            model: "gpt-5.6-sol", effort: "medium", permissions: "workspace", serviceTier: nil)
        model.waitingMessages = [first, second]
        XCTAssertTrue(model.moveWaitingMessage(second.id, relativeTo: first.id, placeAfter: false))

        let restored = AppModel(remoteDefaults: defaults)
        XCTAssertEqual(restored.waitingMessages.map(\.id), [second.id, first.id])
        XCTAssertEqual(restored.waitingMessages.map(\.text), ["第二条", "第一条"])
        XCTAssertEqual(restored.waitingMessages[1].attachments.map(\.url.path), ["/tmp/queue image.png"])
        XCTAssertEqual(restored.waitingMessages[1].model, "gpt-6-astra")
        XCTAssertEqual(restored.waitingMessages[1].effort, "high")
        XCTAssertEqual(restored.waitingMessages[1].permissions, "full")
        XCTAssertEqual(restored.waitingMessages[1].serviceTier, "fast")

        model.waitingMessages = []
        restored.waitingMessages = []
    }
}
