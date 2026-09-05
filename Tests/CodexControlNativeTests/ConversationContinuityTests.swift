import Combine
import XCTest
@testable import CloudCodex

@MainActor
final class ConversationContinuityTests: XCTestCase {
    private func thread(_ id: String, status: String = "idle") -> CodexThread {
        CodexThread(json: ["id": id, "cwd": "/tmp/project", "status": status])!
    }

    func testLaggingRefreshKeepsSelectedNewTaskAndRunningLight() {
        let model = AppModel()
        model.threads = [thread("new"), thread("old")]
        model.selectedThreadID = "new"
        model.messages = [.init(id: "question", role: .user, text: "新任务")]
        model.handleEvent("turn/started", ["threadId": "new", "turn": ["id": "turn-new"]])
        model.applyThreadListSnapshot([thread("old")])
        XCTAssertEqual(model.selectedThread?.id, "new")
        XCTAssertEqual(model.threads.first?.status, "active")
        XCTAssertTrue(model.messages.contains { $0.id == "question" })
        model.applyThreadListSnapshot([thread("new"), thread("old"), thread("discovered")])
        XCTAssertEqual(model.threads.first?.status, "active")
        XCTAssertTrue(model.threads.contains { $0.id == "discovered" })
    }

    func testUnchangedListSnapshotDoesNotRepublish() {
        let model = AppModel()
        let rows = [thread("one"), thread("two")]
        model.threads = rows
        var count = 0
        let token = model.$threads.dropFirst().sink { _ in count += 1 }
        model.applyThreadListSnapshot(rows)
        XCTAssertEqual(count, 0)
        withExtendedLifetime(token) {}
    }

    func testSelectionEchoCannotClearNewTask() {
        let model = AppModel()
        model.selectedFolder = "/tmp/project"
        model.selectedThreadID = "one"
        model.messages = [.init(id: "question", role: .user, text: "新任务")]
        model.selectFolder("/tmp/project")
        model.selectThread("one")
        XCTAssertEqual(model.selectedThreadID, "one")
        XCTAssertEqual(model.messages.map(\.id), ["question"])
    }

    func testSwitchFlushesPendingOutputAndBackgroundCompletionIsRestored() {
        let model = AppModel()
        model.threads = [thread("one"), thread("two")]
        model.selectedThreadID = "one"
        model.handleEvent("turn/started", ["threadId": "one", "turn": ["id": "turn-one"]])
        model.handleEvent("item/reasoning/summaryTextDelta", [
            "threadId": "one", "itemId": "reasoning", "delta": "**检查实现**"
        ])
        // Switch before the 500 ms flush: none of this text may be discarded.
        model.selectThread("two")
        XCTAssertTrue(model.messages.isEmpty)
        var publishes = 0
        let token = model.$messages.dropFirst().sink { _ in publishes += 1 }
        model.handleEvent("item/agentMessage/delta", [
            "threadId": "one", "turnId": "turn-one", "itemId": "answer", "delta": "已完成"
        ])
        model.handleEvent("turn/completed", [
            "threadId": "one", "turn": ["id": "turn-one", "status": "completed"]
        ])
        XCTAssertEqual(publishes, 0)
        XCTAssertFalse(model.isSending)
        model.selectThread("one")
        XCTAssertEqual(model.messages.map(\.id), ["turn-progress", "reasoning", "answer"])
        XCTAssertEqual(model.messages.first { $0.id == "reasoning" }?.text, "**检查实现**")
        XCTAssertFalse(model.messages.contains { $0.isStreaming })
        withExtendedLifetime(token) {}
        model.selectThread(nil)
    }

    func testSameItemIDInTwoThreadsNeverMixesDeltaText() {
        let model = AppModel()
        model.selectedThreadID = "one"
        model.handleEvent("item/agentMessage/delta", ["threadId": "one", "itemId": "answer", "delta": "甲"])
        model.handleEvent("item/agentMessage/delta", ["threadId": "two", "itemId": "answer", "delta": "乙"])
        model.flushPendingDeltas()
        XCTAssertEqual(model.conversationMessages(for: "one").first?.text, "甲")
        XCTAssertEqual(model.conversationMessages(for: "two").first?.text, "乙")
    }

    func testBackgroundSendFailureCannotRemoveVisibleProgress() {
        let model = AppModel()
        model.selectedThreadID = "two"
        model.messages = [.init(id: "turn-progress", role: .activity, text: "正在处理第二个任务")]
        model.rollbackOptimisticSend(threadID: "one", localMessageID: "local-one", text: "旧任务", outgoingAttachments: [])
        XCTAssertEqual(model.messages.first?.text, "正在处理第二个任务")
        XCTAssertTrue(model.composerText.isEmpty)
    }

    func testPartialSnapshotPreservesCachedActivitiesAndTheirOrder() {
        let cached: [ChatMessage] = [
            .init(id: "u", role: .user, text: "问题"),
            .init(id: "r", role: .activity, text: "完整的思考摘要", activityKind: .reasoning),
            .init(id: "c", role: .activity, text: "$ test\n测试通过", activityKind: .command),
            .init(id: "a", role: .assistant, text: "正在生成回答", isStreaming: true)
        ]
        let snapshot: [ChatMessage] = [cached[0], .init(id: "c", role: .activity, text: "$ test"),
                                       .init(id: "a", role: .assistant, text: "正在")]
        let merged = ConversationHistory.merge(snapshot: snapshot, cached: cached)
        XCTAssertEqual(merged.map(\.id), ["u", "r", "c", "a"])
        XCTAssertEqual(merged[2].text, "$ test\n测试通过")
        XCTAssertEqual(merged[3].text, "正在生成回答")
    }

    func testHistoryPagesInsertMissingOlderStepsAndAppendNewTurn() {
        let question = ChatMessage(id: "u", role: .user, text: "问题")
        let answer = ChatMessage(id: "a", role: .assistant, text: "回答")
        let reasoning = ChatMessage(id: "r", role: .activity, text: "摘要")
        let merged = ConversationHistory.merge(snapshot: [question, reasoning, answer], cached: [question, answer])
        XCTAssertEqual(merged.map(\.id), ["u", "r", "a"])
        let next = ChatMessage(id: "u2", role: .user, text: "后续问题")
        XCTAssertEqual(ConversationHistory.merge(snapshot: [next], cached: merged).map(\.id), ["u", "r", "a", "u2"])
    }

    func testConfirmedUserBubbleReplacesOnlyTheMatchingOptimisticTurn() {
        let local = ChatMessage(id: "local-one", role: .user, text: "继续", turnID: "turn-one")
        let newer = ChatMessage(id: "local-two", role: .user, text: "继续", turnID: "turn-two")
        let server = ChatMessage(id: "confirmed", role: .user, text: "继续", turnID: "turn-one")
        XCTAssertEqual(ConversationHistory.merge(snapshot: [server], cached: [local, newer]).map(\.id),
                       ["confirmed", "local-two"])
    }

    func testReasoningNamesMatchInstalledCodexComposer() {
        XCTAssertEqual(["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra", "persistent"].map(ReasoningEffortLabel.name),
                       ["无", "极低", "轻度", "中", "高", "极高", "最高", "Ultra", "持续"])
    }

    func testActivitySnapshotKeepsTurnIdentityAndExplicitRunningState() {
        let decoded = AppServerClient.parseMessages(from: [[
            "id": "turn-one", "status": "inProgress", "items": [
                ["id": "c", "type": "commandExecution", "command": "swift test", "status": "inProgress"],
                ["id": "r", "type": "reasoning", "summary": ["检查格式"]]
            ]
        ]])
        XCTAssertEqual(decoded.map(\.turnID), ["turn-one", "turn-one"])
        XCTAssertTrue(decoded[0].isStreaming)
        XCTAssertFalse(decoded[1].isStreaming)
    }
}
