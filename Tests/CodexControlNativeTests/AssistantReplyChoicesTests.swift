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

    func testOnlyLatestCompletedAssistantMessageCanOfferChoices() {
        XCTAssertTrue(AssistantReplyChoices.options(in: [assistant(question, streaming: true)]).isEmpty)
        XCTAssertTrue(AssistantReplyChoices.options(in: [assistant(question),
            ChatMessage(id: "user", role: .user, text: "已回答")]).isEmpty)
        XCTAssertTrue(AssistantReplyChoices.options(in: [assistant(question), assistant("处理完成")]).isEmpty)
        XCTAssertEqual(AssistantReplyChoices.options(in: [assistant(question),
            ChatMessage(id: "activity", role: .activity, text: "任务完成")]).count, 3)
    }

    func testMarkdownAndNumberedChoices() {
        XCTAssertEqual(AssistantReplyChoices.options(in: [assistant("请选择哪一种？\n1. **方案 A**\n2. 方案 B")]),
                       ["方案 A", "方案 B"])
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
