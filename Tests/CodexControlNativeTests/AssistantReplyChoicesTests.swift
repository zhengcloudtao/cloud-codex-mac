import XCTest
@testable import CloudCodex

final class AssistantReplyChoicesTests: XCTestCase {
    private let question = """
    你测试时“没加热”的具体表现是什么？如果方便，也请提供一条异常帖子的 ID 和大致加热时间，便于定位。

    - 下单成功或已扣币，但推荐量刷不到
    - 礼帽量已高很多，但曝光量和热度没增加
    - 显示加热中，但已曝光人数一直不增加
    """

    private func assistant(_ text: String, streaming: Bool = false) -> ChatMessage {
        ChatMessage(id: "reply", role: .assistant, text: text, isStreaming: streaming)
    }

    func testScreenshotQuestionBecomesThreeChoices() {
        XCTAssertEqual(AssistantReplyChoices.options(in: [assistant(question)]), [
            "下单成功或已扣币，但推荐量刷不到",
            "礼帽量已高很多，但曝光量和热度没增加",
            "显示加热中，但已曝光人数一直不增加"
        ])
    }

    func testQuestionSurvivesProgressButDisappearsAfterUserAnswer() {
        XCTAssertTrue(AssistantReplyChoices.options(in: [assistant(question, streaming: true)]).isEmpty)
        XCTAssertTrue(AssistantReplyChoices.options(in: [assistant(question),
            ChatMessage(id: "user", role: .user, text: "已回答")]).isEmpty)
        XCTAssertEqual(AssistantReplyChoices.options(in: [assistant(question), assistant("继续处理不依赖这个选择的工作")]).count, 3)
        XCTAssertEqual(AssistantReplyChoices.options(in: [assistant(question),
            ChatMessage(id: "activity", role: .activity, text: "任务完成")]).count, 3)
    }

    func testQuestionsCannotCrossTurnBoundariesOrReappearAfterDismissal() {
        var previous = assistant(question)
        previous.turnID = "old-turn"
        let next = ChatMessage(id: "next", role: .assistant, text: "新任务正在处理", turnID: "new-turn")
        XCTAssertNil(AssistantReplyChoices.question(in: [previous, next]))
        XCTAssertNil(AssistantReplyChoices.question(in: [previous], currentTurnID: "new-turn"))
        XCTAssertNil(AssistantReplyChoices.question(in: [previous], dismissed: [previous.id]))
    }

    @MainActor
    func testRunningQuestionRemainsVisibleAfterLaterProgress() {
        let defaults = UserDefaults(suiteName: "running-choices.\(UUID())")!
        let model = AppModel(remoteDefaults: defaults)
        model.selectedThreadID = "thread-1"
        model.handleEvent("turn/started", ["threadId": "thread-1", "turn": ["id": "turn-1"]])
        model.handleEvent("item/completed", ["threadId": "thread-1", "turnId": "turn-1", "item": [
            "id": "question", "type": "agentMessage",
            "text": "迁入后是否继续使用公共数据，并使用目标项目自己的登录与用户数据？目标仓库要求先确认业务范围。\n\n- 共用公共数据，用户数据归目标项目（推荐）\n- 新增专用数据接口"
        ]])
        model.handleEvent("item/completed", ["threadId": "thread-1", "turnId": "turn-1", "item": [
            "id": "progress", "type": "agentMessage", "text": "先处理不依赖该选择的界面工作。"
        ]])
        XCTAssertTrue(model.isSelectedThreadProcessing)
        XCTAssertEqual(model.assistantReplyChoices.count, 2)
        XCTAssertEqual(model.assistantReplyQuestion?.id, "question")
        model.dismissAssistantReplyQuestion("question")
        XCTAssertNil(model.assistantReplyQuestion)
    }

    func testMarkdownAndNumberedChoices() {
        XCTAssertEqual(AssistantReplyChoices.options(in: [assistant("请选择哪一种？\n1. **方案 A**\n2. 方案 B")]),
                       ["方案 A", "方案 B"])
        XCTAssertEqual(AssistantReplyChoices.options(in: [assistant("数据接口怎么选？\n- 使用 `public` 公共接口\n- 新增 `fans` 专用接口")]),
                       ["使用 public 公共接口", "新增 fans 专用接口"])
    }

    @MainActor
    func testExistingScreenshotQuestionCanBeParsedFromReadOnlyHistory() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let title = env["CLOUDCODEX_CHOICE_SMOKE_TITLE"],
              let cwd = env["CLOUDCODEX_CHOICE_SMOKE_CWD"],
              let needle = env["CLOUDCODEX_CHOICE_SMOKE_NEEDLE"] else {
            throw XCTSkip("Opt-in read-only check for a named existing conversation")
        }
        let client = AppServerClient()
        defer { client.shutdown() }
        try await client.start()
        let page = try await client.listThreads(cwd: cwd)
        let thread = try XCTUnwrap(page.threads.first { $0.displayName == title })
        let (_, history) = try await client.readThread(thread.id)
        let message = try XCTUnwrap(history.last { $0.role == .assistant && $0.text.contains(needle) && $0.text.contains("？") })
        let question = try XCTUnwrap(AssistantReplyChoices.question(in: [message]))
        XCTAssertEqual(question.options.count, 2)
        print("Read-only screenshot question: recognized \(question.options.count) options; no messages sent")
    }

    func testDoesNotOfferOrdinaryListsCodeLinksOrMultipleQuestionGroups() {
        for text in ["已完成：\n- 修复问题\n- 运行测试",
                     "怎么处理？\n```\n- A\n- B\n```",
                     "选哪个？\n- [A](https://example.com)\n- B",
                     "选哪个？\n- A\n- B\n另一个选哪个？\n- C\n- D",
                     "选哪个？\n- A\n- A"] {
            XCTAssertTrue(AssistantReplyChoices.options(in: [assistant(text)]).isEmpty, text)
        }
    }

    func testChoiceSwitchingAndDraftPreservation() {
        let options = ["A", "B"]
        XCTAssertEqual(AssistantReplyChoices.draft(selecting: "A", options: options, current: ""), "A")
        XCTAssertEqual(AssistantReplyChoices.draft(selecting: "B", options: options, current: "A"), "B")
        XCTAssertEqual(AssistantReplyChoices.draft(selecting: "B", options: options, current: "帖子 ID：123"),
                       "帖子 ID：123\nB")
        XCTAssertEqual(AssistantReplyChoices.draft(selecting: "B", options: options, current: "帖子 ID：123\nB"),
                       "帖子 ID：123\nB")
    }

    @MainActor
    func testSelectionOnlyChangesDraftAndCannotReuseStaleOptions() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "reply-choices.\(UUID())"))
        let model = AppModel(remoteDefaults: defaults)
        model.selectedThreadID = "thread-1"
        model.messages = [assistant(question)]
        let option = try XCTUnwrap(model.assistantReplyChoices.first)
        let focus = model.replyChoiceFocusRequest
        model.selectAssistantReplyChoice(option)
        XCTAssertEqual(model.composerText, option)
        XCTAssertNotEqual(model.replyChoiceFocusRequest, focus)
        XCTAssertEqual(model.messages.count, 1)
        model.messages.append(ChatMessage(id: "answered", role: .user, text: "已回答"))
        model.composerText = "保留草稿"
        model.selectAssistantReplyChoice(option)
        XCTAssertEqual(model.composerText, "保留草稿")
    }

    @MainActor
    func testStructuredRequestSuppressesOrdinaryReplyChoices() {
        let model = AppModel(remoteDefaults: UserDefaults(suiteName: "reply-request.\(UUID())")!)
        model.selectedThreadID = "thread-1"
        model.messages = [assistant(question)]
        XCTAssertEqual(model.assistantReplyChoices.count, 3)
        model.handleServerRequest(.number(1), method: "item/tool/requestUserInput", params: [
            "threadId": "thread-1", "turnId": "turn-1", "itemId": "item-1",
            "questions": [["id": "answer", "header": "选择", "question": "选哪个？",
                           "options": [["label": "A", "description": "方案 A"]]]]
        ])
        XCTAssertTrue(model.assistantReplyChoices.isEmpty)
    }
}
