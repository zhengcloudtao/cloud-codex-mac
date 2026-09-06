import XCTest
@testable import CloudCodex

final class RemoteTaskProgressTests: XCTestCase {
    func testPublicSummaryOnlyAndNoToolArguments() throws {
        var p = RemoteTaskProgress()
        p.consume("item/reasoning/textDelta", ["itemId": "r", "delta": "private-reasoning"])
        XCTAssertTrue(p.steps.isEmpty)
        p.consume("item/started", ["item": ["id": "r", "type": "reasoning", "content": ["private-reasoning"]]])
        p.consume("item/reasoning/summaryTextDelta", ["itemId": "r", "delta": "公开摘要"])
        p.consume("item/completed", ["item": ["id": "r", "type": "reasoning", "summary": ["公开摘要"], "content": ["private-reasoning"]]])
        p.consume("item/started", ["item": ["id": "tool", "type": "mcpToolCall", "tool": "search", "arguments": ["secret": "private-argument"]]])
        let encoded = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-"))
        XCTAssertEqual(p.steps.first?.text, "公开摘要")
    }

    func testCommandStreamsAndTerminalDoesNotRevive() {
        var p = RemoteTaskProgress()
        p.consume("item/started", ["item": ["id": "c", "type": "commandExecution", "command": "test"]])
        p.consume("item/commandExecution/outputDelta", ["itemId": "c", "delta": "PASS"])
        p.consume("item/completed", ["item": ["id": "c", "type": "commandExecution", "exitCode": 0]])
        XCTAssertTrue(p.steps[0].text.contains("PASS"))
        let before = p
        p.consume("item/commandExecution/outputDelta", ["itemId": "c", "delta": "late"])
        XCTAssertEqual(p, before)
        XCTAssertEqual(p.steps[0].status, "completed")
    }

    func testBoundedHistoryAndFinalFlush() {
        var p = RemoteTaskProgress()
        for i in 0..<100 {
            p.consume("item/agentMessage/delta", ["itemId": "m\(i)", "delta": String(repeating: "长", count: 3000)])
        }
        XCTAssertEqual(p.steps.count, 64)
        XCTAssertTrue(p.truncated)
        XCTAssertTrue(p.steps.allSatisfy { $0.text.count <= 2000 })
        let revision = p.revision
        p.consume("turn/completed", [:])
        XCTAssertGreaterThan(p.revision, revision)
        XCTAssertTrue(p.steps.allSatisfy { $0.status != "running" })
        p.consume("turn/plan/updated", ["plan": [["step": "执行测试", "status": "completed"]]])
        XCTAssertEqual(p.steps.last?.text, "- [x] 执行测试")
    }
}
