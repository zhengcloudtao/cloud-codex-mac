import Combine
import XCTest
@testable import CloudCodex

@MainActor
final class StreamingEventTests: XCTestCase {
    func testUnchangedStatusPollDoesNotRepublishThreadList() throws {
        let model = AppModel()
        let idleThread = try XCTUnwrap(CodexThread(json: [
            "id": "thread-idle",
            "cwd": "/tmp/project",
            "status": ["type": "idle"]
        ]))
        let activeThread = try XCTUnwrap(CodexThread(json: [
            "id": "thread-active",
            "cwd": "/tmp/project",
            "status": ["type": "active"]
        ]))
        model.threads = [idleThread, activeThread]

        var publishCount = 0
        let cancellable = model.$threads.dropFirst().sink { _ in
            publishCount += 1
        }

        model.applyVisibleThreadStatuses([
            "thread-idle": "idle",
            "thread-active": "active"
        ])
        XCTAssertEqual(publishCount, 0)

        model.applyVisibleThreadStatuses([
            "thread-idle": "active",
            "thread-active": "idle"
        ])
        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(model.threads.map(\.status), ["active", "idle"])
        withExtendedLifetime(cancellable) {}
    }

    func testUnchangedExternalActivityPollDoesNotRepublishConversation() throws {
        let model = AppModel()
        let thread = try XCTUnwrap(CodexThread(json: [
            "id": "thread-idle",
            "cwd": "/tmp/project",
            "preview": "已经完成",
            "status": ["type": "idle"]
        ]))
        let existingMessage = ChatMessage(
            id: "answer",
            role: .assistant,
            text: "已经完成"
        )
        model.threads = [thread]
        model.selectedThreadID = thread.id
        model.messages = [existingMessage]

        var threadPublishCount = 0
        var messagePublishCount = 0
        var processingPublishCount = 0
        let threadCancellable = model.$threads.dropFirst().sink { _ in
            threadPublishCount += 1
        }
        let messageCancellable = model.$messages.dropFirst().sink { _ in
            messagePublishCount += 1
        }
        let processingCancellable = model.$isExternalThreadProcessing.dropFirst().sink { _ in
            processingPublishCount += 1
        }

        model.applyExternalActivitySnapshot(
            ThreadActivitySnapshot(thread: thread, turn: nil, messages: []),
            threadID: thread.id
        )

        XCTAssertEqual(threadPublishCount, 0)
        XCTAssertEqual(messagePublishCount, 0)
        XCTAssertEqual(processingPublishCount, 0)
        XCTAssertEqual(model.messages, [existingMessage])
        withExtendedLifetime((threadCancellable, messageCancellable, processingCancellable)) {}
    }

    func testTurnEventsUpdateThreadListRunningStatus() throws {
        let model = AppModel()
        let thread = try XCTUnwrap(CodexThread(json: [
            "id": "thread-1",
            "cwd": "/tmp/project",
            "preview": "正在执行的任务",
            "status": ["type": "idle"]
        ]))
        model.threads = [thread]
        model.selectedThreadID = "thread-1"

        model.handleEvent("turn/started", [
            "threadId": "thread-1",
            "turn": ["id": "turn-1"]
        ])
        XCTAssertEqual(model.threads.first?.status, "active")

        model.handleEvent("turn/completed", [
            "threadId": "thread-1",
            "turn": ["id": "turn-1", "status": "completed"]
        ])
        XCTAssertEqual(model.threads.first?.status, "idle")
    }

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

        model.handleEvent("item/reasoning/textDelta", [
            "threadId": "thread-1", "turnId": "turn-1",
            "itemId": "reasoning-live-1", "contentIndex": 0,
            "delta": "正在检查工程中的相关实现。"
        ])
        let liveReasoning = model.messages.first { $0.id == "reasoning-live-1-live" }
        XCTAssertEqual(liveReasoning?.activityTitle, "实时推理")
        XCTAssertEqual(liveReasoning?.text, "正在检查工程中的相关实现。")
        XCTAssertTrue(liveReasoning?.isStreaming == true)

        model.handleEvent("item/reasoning/summaryPartAdded", [
            "threadId": "thread-1", "turnId": "turn-1",
            "itemId": "reasoning-placeholder", "summaryIndex": 0
        ])
        let summaryPlaceholder = model.messages.first { $0.id == "reasoning-placeholder" }
        XCTAssertEqual(summaryPlaceholder?.activityTitle, "思考摘要")
        XCTAssertEqual(summaryPlaceholder?.text, "正在整理当前推理结果…")
        XCTAssertTrue(summaryPlaceholder?.isStreaming == true)

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

    func testActiveWriterFailureRollsBackOptimisticMessagesAndPreservesDraft() {
        let model = AppModel()
        model.selectedThreadID = "thread-external"
        model.isSending = true
        model.messages = [
            ChatMessage(id: "existing", role: .assistant, text: "此前回复"),
            ChatMessage(id: "local-message", role: .user, text: "继续处理"),
            ChatMessage(
                id: "turn-progress",
                role: .activity,
                text: "正在分析任务并准备执行…",
                isStreaming: true,
                activityKind: .status,
                activityTitle: "Codex 正在处理",
                activityStatus: "进行中"
            )
        ]

        let error = NSError(
            domain: "CloudCodexTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Thread is held by an ACTIVE WRITER"]
        )
        model.handleSendFailure(
            error,
            threadID: "thread-external",
            localMessageID: "local-message",
            text: "继续处理",
            outgoingAttachments: []
        )

        XCTAssertFalse(model.isSending)
        XCTAssertNil(model.activeTurnID)
        XCTAssertEqual(model.composerText, "继续处理")
        XCTAssertEqual(model.messages.map(\.id), ["existing"])
        XCTAssertFalse(model.messages.contains { $0.activityStatus == "发送失败" })
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(
            model.threadOwnershipNotice,
            "此会话已在 Codex 主应用中打开。关闭原窗口后，再点击发送即可继续。"
        )
    }

    func testActiveWriterErrorRecognitionIsCaseInsensitive() {
        let error = NSError(
            domain: "CloudCodexTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Thread is held by an ACTIVE WRITER"]
        )
        XCTAssertTrue(AppModel.isActiveWriterError(error))
    }
}
