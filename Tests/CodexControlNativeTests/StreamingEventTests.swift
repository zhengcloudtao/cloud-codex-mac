import XCTest
@testable import CloudCodex

@MainActor
final class StreamingEventTests: XCTestCase {
    func testStreamingReasoningCommandAndFileEventsAreVisible() {
        let model = AppModel()
        model.selectedThreadID = "thread-1"

        model.handleEvent("turn/started", [
            "threadId": "thread-1",
            "turn": ["id": "turn-1"]
        ])
        XCTAssertEqual(model.activeTurnID, "turn-1")
        XCTAssertEqual(model.messages.first?.activityTitle, "Codex 正在处理")

        model.handleEvent("item/reasoning/summaryTextDelta", [
            "threadId": "thread-1", "turnId": "turn-1",
            "itemId": "reasoning-1", "delta": "先检查项目结构。"
        ])
        model.handleEvent("item/reasoning/summaryTextDelta", [
            "threadId": "thread-1", "turnId": "turn-1",
            "itemId": "reasoning-1", "delta": "再定位需要修改的文件。"
        ])
        let reasoning = model.messages.first { $0.id == "reasoning-1" }
        XCTAssertEqual(reasoning?.activityKind, .reasoning)
        XCTAssertEqual(reasoning?.text, "先检查项目结构。再定位需要修改的文件。")
        XCTAssertTrue(reasoning?.isStreaming == true)

        model.handleEvent("item/started", [
            "threadId": "thread-1", "turnId": "turn-1",
            "item": [
                "type": "commandExecution", "id": "command-1",
                "command": "swift build", "cwd": "/tmp/project",
                "status": "inProgress"
            ]
        ])
        model.handleEvent("item/commandExecution/outputDelta", [
            "threadId": "thread-1", "turnId": "turn-1",
            "itemId": "command-1", "delta": "Build complete!"
        ])
        let command = model.messages.first { $0.id == "command-1" }
        XCTAssertEqual(command?.activityKind, .command)
        XCTAssertTrue(command?.text.contains("swift build") == true)
        XCTAssertTrue(command?.text.contains("Build complete!") == true)

        model.handleEvent("item/fileChange/patchUpdated", [
            "threadId": "thread-1", "turnId": "turn-1", "itemId": "file-1",
            "changes": [["path": "/tmp/project/App.swift"]]
        ])
        let file = model.messages.first { $0.id == "file-1" }
        XCTAssertEqual(file?.activityKind, .file)
        XCTAssertEqual(file?.text, "/tmp/project/App.swift")

        model.handleEvent("item/completed", [
            "threadId": "thread-1", "turnId": "turn-1",
            "item": [
                "type": "commandExecution", "id": "command-1",
                "command": "swift build", "cwd": "/tmp/project",
                "status": "completed", "aggregatedOutput": "Build complete!",
                "exitCode": 0
            ]
        ])
        XCTAssertEqual(model.messages.first { $0.id == "command-1" }?.activityStatus, "已完成")
        XCTAssertFalse(model.messages.first { $0.id == "command-1" }?.isStreaming ?? true)

        let visibleCount = model.messages.count
        model.handleEvent("turn/completed", [
            "threadId": "thread-1", "turn": ["id": "turn-1", "status": "completed"]
        ])
        XCTAssertEqual(model.messages.count, visibleCount)
        XCTAssertFalse(model.messages.contains { $0.isStreaming })
    }

    func testLargeCommandOutputIsBounded() {
        let model = AppModel()
        model.selectedThreadID = "thread-1"
        model.handleEvent("item/commandExecution/outputDelta", [
            "threadId": "thread-1", "turnId": "turn-1",
            "itemId": "command-1", "delta": String(repeating: "x", count: 20_000)
        ])
        let output = model.messages.first { $0.id == "command-1" }?.text ?? ""
        XCTAssertLessThan(output.count, 12_100)
        XCTAssertTrue(output.hasPrefix("…已省略较早输出…"))
    }
}
