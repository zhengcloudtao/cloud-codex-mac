import XCTest
@testable import CloudCodex

final class MessageSpeedTests: XCTestCase {
    @MainActor
    func testAcknowledgementUpdatesOnlyItsTurn() {
        let model = AppModel()
        model.selectedThreadID = "thread"
        model.messages = [
            ChatMessage(id: "old", role: .assistant, text: "old", turnID: "old", model: "gpt-test", serviceTier: "default"),
            ChatMessage(id: "new-user", role: .user, text: "hello", turnID: "new", model: "gpt-test"),
            ChatMessage(id: "new-answer", role: .assistant, text: "hello", turnID: "new", model: "gpt-test")
        ]
        model.applyTurnSpeed(threadID: "thread", turnID: "new", tier: "priority")
        XCTAssertEqual(model.messages[0].serviceTier, "default")
        XCTAssertEqual(model.messages[1].modelUsageLabel, "gpt-test · 加速")
        XCTAssertEqual(model.messages[2].modelUsageLabel, "gpt-test · 加速")
        model.applyTurnSpeed(threadID: "thread", turnID: "new", tier: "default")
        XCTAssertEqual(model.messages[1].modelUsageLabel, "gpt-test · 标准")
    }

    func testLabelsUsePerMessageTier() {
        for (tier, label) in [("default", "标准"), ("standard", "标准"), ("priority", "加速"), ("fast", "加速"), ("other", "速度未知")] {
            let message = ChatMessage(id: "a", role: .assistant, text: "answer", model: "gpt-test", reasoningEffort: "low", serviceTier: tier)
            XCTAssertEqual(message.modelUsageLabel, "gpt-test · 轻度 · " + label)
        }
        XCTAssertEqual(ChatMessage(id: "a", role: .user, text: "question", model: "gpt-test").modelUsageLabel, "gpt-test · 速度未知")
    }

    func testTurnContextTierSurvivesParsingAndHistoryMerge() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try "{\"type\":\"turn_context\",\"payload\":{\"turn_id\":\"turn\",\"model\":\"gpt-test\",\"effort\":\"low\",\"service_tier\":\"priority\"}}\n".write(to: url, atomically: true, encoding: .utf8)
        let metadata = await TurnMetadataReader().metadata(filePath: url.path, turnIDs: ["turn"])
        XCTAssertEqual(metadata["turn"]?.serviceTier, "priority")
        let messages = AppServerClient.parseMessages(from: [["id": "turn", "items": [
            ["id": "u", "type": "userMessage", "content": [["type": "text", "text": "question"]]],
            ["id": "a", "type": "agentMessage", "text": "answer"]
        ]]], metadataByTurnID: metadata)
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages.allSatisfy { $0.serviceTier == "priority" })
        var sparse = messages
        for index in sparse.indices { sparse[index].serviceTier = nil }
        let merged = ConversationHistory.merge(snapshot: sparse, cached: messages)
        XCTAssertTrue(merged.allSatisfy { $0.serviceTier == "priority" })
    }
}
