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
        XCTAssertNotNil(model.messages.first?.startedAt)
        XCTAssertNil(model.messages.first?.completedAt)

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
        XCTAssertEqual(model.messages.first { $0.id == "turn-progress" }?.activityStatus, "已完成")
        XCTAssertNotNil(model.messages.first { $0.id == "turn-progress" }?.completedAt)
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

    func testExternallyStartedTurnShowsAndClearsProcessingState() throws {
        let model = AppModel()
        model.selectedThreadID = "thread-external"
        let activeThread = try XCTUnwrap(CodexThread(json: [
            "id": "thread-external",
            "cwd": "/tmp/project",
            "preview": "外部任务",
            "status": ["type": "active"]
        ]))
        let start = Date(timeIntervalSince1970: 1_788_500_000)
        let userMessage = ChatMessage(id: "user-external", role: .user, text: "继续处理")
        let commandMessage = ChatMessage(
            id: "command-external",
            role: .activity,
            text: "$ swift test",
            isStreaming: true,
            activityKind: .command,
            activityTitle: "执行命令",
            activityStatus: "运行中"
        )

        model.applyExternalActivitySnapshot(
            ThreadActivitySnapshot(
                thread: activeThread,
                turn: TurnRuntimeState(id: "turn-external", status: "inProgress", startedAt: start, completedAt: nil),
                messages: [userMessage, commandMessage]
            ),
            threadID: "thread-external"
        )

        XCTAssertTrue(model.isExternalThreadProcessing)
        XCTAssertFalse(model.canSend)
        let progressIndex = try XCTUnwrap(model.messages.firstIndex { $0.id == "turn-progress" })
        XCTAssertEqual(progressIndex, 1)
        XCTAssertEqual(model.messages[progressIndex].startedAt, start)
        XCTAssertEqual(model.messages[progressIndex + 1].id, "command-external")

        let idleThread = try XCTUnwrap(CodexThread(json: [
            "id": "thread-external",
            "cwd": "/tmp/project",
            "preview": "外部任务",
            "status": ["type": "idle"]
        ]))
        let assistantMessage = ChatMessage(id: "answer-external", role: .assistant, text: "已经完成")
        model.applyExternalActivitySnapshot(
            ThreadActivitySnapshot(
                thread: idleThread,
                turn: TurnRuntimeState(id: "turn-external", status: "completed", startedAt: start, completedAt: Date()),
                messages: [userMessage, commandMessage, assistantMessage]
            ),
            threadID: "thread-external"
        )

        XCTAssertFalse(model.isExternalThreadProcessing)
        XCTAssertFalse(model.messages.contains { $0.id == "turn-progress" })
        XCTAssertEqual(model.messages.last?.id, "answer-external")
    }
}
