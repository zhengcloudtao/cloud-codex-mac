import XCTest
@testable import CloudCodex

@MainActor
final class SteeredMessageHistoryTests: XCTestCase {
    func testSuccessfulSteerIsVisibleWithoutWaitingForHistory() {
        let model = AppModel()
        model.selectedThreadID = "a"
        model.composerText = "尚未发送的草稿"
        let item = AppModel.WaitingMessage(threadID: "a", text: "补充要求", attachments: [],
            model: nil, effort: nil, permissions: nil, serviceTier: nil)
        model.recordSteeredMessage(item, turnID: "turn")
        model.recordSteeredMessage(item, turnID: "turn")
        XCTAssertEqual(model.messages.count, 1)
        XCTAssertEqual(model.messages.first?.text, "补充要求")
        XCTAssertEqual(model.messages.first?.role, .user)
        XCTAssertEqual(model.messages.first?.turnID, "turn")
        XCTAssertEqual(model.composerText, "尚未发送的草稿")
        model.selectedThreadID = "b"
        let background = AppModel.WaitingMessage(threadID: "a", text: "后台引导", attachments: [],
            model: nil, effort: nil, permissions: nil, serviceTier: nil)
        model.messages = []
        model.recordSteeredMessage(background, turnID: "turn")
        XCTAssertTrue(model.messages.isEmpty)
        XCTAssertEqual(model.conversationMessages(for: "a").last?.text, "后台引导")
    }

    func testSteerSurvivesLaggingHistoryAndMergesWithItsOwnConfirmedItem() {
        let original = ChatMessage(id: "original", role: .user, text: "原始提问", turnID: "turn")
        let steer = ChatMessage(id: "local-steer-one", role: .user, text: "追加要求", turnID: "turn")
        let lagging = ConversationHistory.merge(snapshot: [original], cached: [original, steer])
        XCTAssertEqual(lagging.map(\.text), ["原始提问", "追加要求"])
        let confirmed = ChatMessage(id: "confirmed-steer", role: .user, text: "追加要求", turnID: "turn")
        let merged = ConversationHistory.merge(snapshot: [original, confirmed], cached: lagging)
        XCTAssertEqual(merged.map(\.id), ["original", "confirmed-steer"])
        let repeated = ConversationHistory.merge(snapshot: [original, confirmed], cached: merged)
        XCTAssertEqual(repeated, merged)
    }
}
