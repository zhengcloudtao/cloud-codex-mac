import XCTest
@testable import CloudCodex

final class RemoteHistoryTests: XCTestCase {
    func testCompleteTextChronologyCursorAndPublicContentOnly() {
        let long = String(repeating: "完整回答", count: 20000)
        let response: [String: Any] = ["nextCursor": "older-cursor", "data": [
            ["id": "new", "startedAt": 123, "items": [
                ["id": "u", "type": "userMessage", "content": [["type": "text", "text": "问题"], ["type": "image", "url": "data:image/png;base64,private"]]],
                ["id": "r", "type": "reasoning", "summary": ["公开摘要"], "content": ["private-reasoning"]],
                ["id": "tool", "type": "mcpToolCall", "tool": "search", "arguments": ["private": "secret"]],
                ["id": "a", "type": "agentMessage", "text": long]
            ]],
            ["id": "old", "items": [["id": "old-a", "type": "agentMessage", "text": "较早回答"]]]
        ]]
        let page = AppServerClient.remoteHistoryPage(response, metadata: ["new": TurnModelMetadata(model: "test-model", reasoningEffort: "high")])
        XCTAssertEqual(page.nextCursor, "older-cursor")
        XCTAssertEqual(page.messages.first?.text, "较早回答")
        XCTAssertEqual(page.messages.last?.text, long)
        XCTAssertEqual(page.messages.last?.model, "test-model")
        XCTAssertFalse(page.messages.map(\.text).joined().contains("private"))
        XCTAssertTrue(page.messages.contains { $0.role == "user" && $0.text.contains("问题") && $0.text.contains("图片附件") })
    }
}
