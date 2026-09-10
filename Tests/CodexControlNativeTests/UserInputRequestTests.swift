import XCTest
@testable import CloudCodex

final class UserInputRequestTests: XCTestCase {
    private let params: [String: Any] = [
        "threadId": "thread-1", "turnId": "turn-1", "itemId": "item-1", "isBlocking": true,
        "questions": [[
            "id": "choice", "header": "实现方式", "question": "请选择一种方案",
            "options": [["label": "方案 A", "description": "保持兼容"]], "isOther": true
        ], [
            "id": "secret", "header": "密钥", "question": "请输入密钥",
            "options": NSNull(), "isSecret": true
        ]]
    ]

    func testParsesGPT6RequestAndPreservesInputCapabilities() throws {
        let request = try XCTUnwrap(UserInputRequest(requestID: .number(7), params: params))
        XCTAssertEqual(request.threadID, "thread-1")
        XCTAssertEqual(request.turnID, "turn-1")
        XCTAssertTrue(request.isBlocking)
        XCTAssertEqual(request.questions.count, 2)
        XCTAssertEqual(request.questions[0].options.first?.label, "方案 A")
        XCTAssertTrue(request.questions[0].allowsOther)
        XCTAssertTrue(request.questions[1].isSecret)
    }

    func testResponseUsesProtocolQuestionIDToAnswersShape() throws {
        let request = try XCTUnwrap(UserInputRequest(requestID: .string("request-a"), params: params))
        let payload = request.responsePayload(answers: ["choice": "方案 A", "secret": "private"])
        let answers = try XCTUnwrap(payload["answers"] as? [String: [String: [String]]])
        XCTAssertEqual(answers["choice"]?["answers"], ["方案 A"])
        XCTAssertEqual(answers["secret"]?["answers"], ["private"])
        XCTAssertEqual(request.id, "string:request-a")
    }

    func testTimeoutIsOneMinuteAndSkipAnswersEveryQuestion() throws {
        let receivedAt = Date(timeIntervalSince1970: 1_000)
        let request = try XCTUnwrap(UserInputRequest(requestID: .number(10), params: params, receivedAt: receivedAt))
        XCTAssertEqual(request.expiresAt, receivedAt.addingTimeInterval(60))
        let answers = try XCTUnwrap(request.skippedResponsePayload["answers"] as? [String: [String: [String]]])
        XCTAssertEqual(answers["choice"]?["answers"], ["跳过（1 分钟内未回答）"])
        XCTAssertEqual(answers["secret"]?["answers"], ["跳过（1 分钟内未回答）"])
    }

    func testRejectsMalformedRequestInsteadOfShowingBrokenForm() {
        XCTAssertNil(UserInputRequest(requestID: .number(1), params: ["threadId": "thread-1"]))
    }

    @MainActor
    func testServerRequestIsStoredOnlyForItsConversationAndAddsTimelineStatus() throws {
        let model = AppModel(remoteDefaults: UserDefaults(suiteName: "user-input.\(UUID())")!)
        model.selectedThreadID = "thread-1"
        model.handleServerRequest(.number(7), method: "item/tool/requestUserInput", params: params)
        XCTAssertEqual(model.selectedUserInputRequests.map(\.id), ["number:7"])
        XCTAssertEqual(model.conversationMessages(for: "thread-1").last?.activityStatus, "待回答")

        var other = params
        other["threadId"] = "thread-2"
        other["itemId"] = "item-2"
        model.handleServerRequest(.number(8), method: "item/tool/requestUserInput", params: other)
        XCTAssertEqual(model.selectedUserInputRequests.map(\.id), ["number:7"])
        XCTAssertEqual(model.conversationMessages(for: "thread-2").last?.activityStatus, "待回答")
    }

    @MainActor
    func testUnknownServerRequestDoesNotCreateBrokenInputCard() {
        let model = AppModel(remoteDefaults: UserDefaults(suiteName: "unknown-input.\(UUID())")!)
        model.handleServerRequest(.number(9), method: "some/new/request", params: params)
        XCTAssertTrue(model.userInputRequests.isEmpty)
    }

    @MainActor
    func testResolvedNotificationRemovesAnAutoClearedRequest() {
        let model = AppModel(remoteDefaults: UserDefaults(suiteName: "resolved-input.\(UUID())")!)
        model.selectedThreadID = "thread-1"
        model.handleServerRequest(.string("request-1"), method: "item/tool/requestUserInput", params: params)
        XCTAssertEqual(model.selectedUserInputRequests.count, 1)
        model.handleEvent("serverRequest/resolved", ["threadId": "thread-1", "requestId": "request-1"])
        XCTAssertTrue(model.selectedUserInputRequests.isEmpty)
        XCTAssertEqual(model.conversationMessages(for: "thread-1").last?.activityStatus, "已处理")
    }
}
