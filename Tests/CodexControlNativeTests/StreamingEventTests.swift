import Combine
import XCTest
@testable import CloudCodex

@MainActor
final class StreamingEventTests: XCTestCase {
    func testOnlyInterruptTimeoutUsesForcedStopRecovery() {
        XCTAssertTrue(AppModel.isInterruptTimeout(CodexClientError.timeout("turn/interrupt")))
        XCTAssertFalse(AppModel.isInterruptTimeout(CodexClientError.timeout("thread/read")))
        XCTAssertFalse(AppModel.isInterruptTimeout(CodexClientError.server("turn/interrupt failed")))
    }

    func testLiveToolCallRecordsStartAndCompletionTimes() throws {
        let model = AppModel()
        model.selectedThreadID = "thread-tool"

        let startedItem: [String: Any] = [
            "id": "cua-call",
            "type": "dynamicToolCall",
            "namespace": "cua_repl",
            "tool": "js",
            "status": "inProgress",
            "arguments": ["code": "await cua.getApp(\"CloudCodex\")"]
        ]
        model.handleEvent("item/started", [
            "threadId": "thread-tool", "turnId": "turn-tool", "item": startedItem
        ])

        let started = try XCTUnwrap(model.messages.first { $0.id == "cua-call" })
        XCTAssertTrue(started.isStreaming)
        XCTAssertNotNil(started.startedAt)
        XCTAssertNil(started.completedAt)

        var completedItem = startedItem
        completedItem["status"] = "completed"
        model.handleEvent("item/completed", [
            "threadId": "thread-tool", "turnId": "turn-tool", "item": completedItem
        ])

        let completed = try XCTUnwrap(model.messages.first { $0.id == "cua-call" })
        XCTAssertFalse(completed.isStreaming)
        XCTAssertEqual(completed.startedAt, started.startedAt)
        XCTAssertNotNil(completed.completedAt)
    }

    func testOnlyComputerControlDynamicToolsUseBoundedTimeout() {
        XCTAssertTrue(AppModel.isComputerControlItem([
            "type": "dynamicToolCall", "namespace": "cua_repl", "tool": "js"
        ]))
        XCTAssertTrue(AppModel.isComputerControlItem([
            "type": "dynamicToolCall", "namespace": "computer-use", "tool": "run"
        ]))
        XCTAssertFalse(AppModel.isComputerControlItem([
            "type": "dynamicToolCall", "namespace": "browser", "tool": "open"
        ]))
        XCTAssertFalse(AppModel.isComputerControlItem([
            "type": "mcpToolCall", "server": "wechat", "tool": "preview"
        ]))
    }

    func testStalledComputerControlStopsTurnAndShowsSpecificReason() async throws {
        let defaults = UserDefaults(suiteName: "computer-timeout-\(UUID().uuidString)")!
        let model = AppModel(remoteDefaults: defaults, computerControlTimeoutSeconds: 0.02)
        model.selectedThreadID = "thread-cua-timeout"

        model.handleEvent("turn/started", [
            "threadId": "thread-cua-timeout",
            "turn": ["id": "turn-cua-timeout", "status": "inProgress"]
        ])
        model.handleEvent("item/started", [
            "threadId": "thread-cua-timeout",
            "turnId": "turn-cua-timeout",
            "item": [
                "id": "cua-timeout",
                "type": "dynamicToolCall",
                "namespace": "cua_repl",
                "tool": "js",
                "status": "inProgress",
                "arguments": ["code": "await cua.getApp(\"/Applications/wechatwebdevtools.app\")"]
            ]
        ])

        try await Task.sleep(nanoseconds: 100_000_000)

        let activity = try XCTUnwrap(model.messages.first { $0.id == "cua-timeout" })
        XCTAssertFalse(activity.isStreaming)
        XCTAssertEqual(activity.activityStatus, "超时")
        XCTAssertTrue(activity.text.contains("电脑控制步骤超过"))
        XCTAssertEqual(model.threadOutcomes["thread-cua-timeout"], .interrupted)
        XCTAssertFalse(model.isSending)
    }

    func testLiveCollaborationEventsExposeNamedChildTaskStatus() {
        let model = AppModel()
        model.selectedThreadID = "parent"

        model.handleEvent("item/started", [
            "threadId": "parent",
            "turnId": "turn-1",
            "item": [
                "id": "spawn",
                "type": "collabAgentToolCall",
                "tool": "spawnAgent",
                "status": "inProgress",
                "senderThreadId": "parent",
                "receiverThreadIds": ["child-xili"],
                "agentsStates": ["child-xili": ["status": "running"]]
            ]
        ])
        model.handleEvent("item/completed", [
            "threadId": "parent",
            "turnId": "turn-1",
            "item": [
                "id": "xili-finished",
                "type": "subAgentActivity",
                "agentThreadId": "child-xili",
                "agentPath": "/root/xili",
                "kind": "completed"
            ]
        ])

        let group = ConversationProcessGroup(messages: model.messages)
        XCTAssertEqual(group.childTasks, [
            CollaborationChildTask(threadID: "child-xili", name: "xili", status: "已完成", detail: "")
        ])
    }

    func testSelectedCollaborationTasksAlwaysComeFromVisibleConversation() {
        let model = AppModel()
        model.messages = [ChatMessage(
            id: "other-thread-spawn",
            role: .activity,
            text: "",
            activityKind: .collaboration,
            turnID: "other-turn",
            collaborationChildTasks: [
                CollaborationChildTask(
                    threadID: "other-child",
                    name: "round8_liuxian",
                    status: "已完成",
                    detail: ""
                )
            ]
        )]
        XCTAssertEqual(model.selectedCollaborationTasks.map(\.name), ["round8_liuxian"])

        // Switching to a conversation without collaboration must immediately
        // remove the previous conversation's persistent child-task summary.
        model.messages = [ChatMessage(id: "current-user", role: .user, text: "调整头像")]
        XCTAssertTrue(model.selectedCollaborationTasks.isEmpty)
    }

    func testUnsupportedOptionalActivityEventDoesNotShowErrorDialog() {
        let model = AppModel()

        model.handleEvent("error", [
            "error": ["message": "thread/items/list is not supported yet"]
        ])

        XCTAssertNil(model.errorMessage)
    }

    func testOtherGlobalErrorStillShowsErrorDialog() {
        let model = AppModel()

        model.handleEvent("error", [
            "error": ["message": "连接已断开"]
        ])

        XCTAssertEqual(model.errorMessage, "连接已断开")
    }

    func testModelParsesAdvertisedFastServiceTier() throws {
        let option = try XCTUnwrap(CodexModelOption(json: [
            "id": "gpt-test",
            "model": "gpt-test",
            "displayName": "GPT Test",
            "defaultReasoningEffort": "medium",
            "supportedReasoningEfforts": [
                ["reasoningEffort": "medium"]
            ],
            "defaultServiceTier": "default",
            "serviceTiers": [
                ["id": "fast", "name": "Fast", "description": "Faster responses"]
            ]
        ]))

        XCTAssertEqual(option.defaultServiceTier, "default")
        XCTAssertEqual(option.fastServiceTierID, "fast")
        XCTAssertEqual(option.serviceTiers.first?.name, "Fast")
    }

    func testThreadParsesPersistedServiceTier() throws {
        let thread = try XCTUnwrap(CodexThread(json: [
            "id": "thread-1",
            "cwd": "/tmp/project",
            "serviceTier": "priority"
        ]))

        XCTAssertEqual(thread.serviceTier, "priority")
    }

    func testTurnStartPersistsServiceTierOnThread() {
        let parameters = AppServerClient.turnStartParameters(
            threadID: "thread-1",
            text: "继续处理",
            attachments: [],
            model: "gpt-test",
            effort: "high",
            permissions: ":workspace",
            serviceTier: "fast"
        )

        XCTAssertEqual(parameters["serviceTier"] as? String, "fast")
        XCTAssertNil(parameters["serviceTierForTurn"])
        XCTAssertEqual(parameters["threadId"] as? String, "thread-1")
        XCTAssertEqual(parameters["model"] as? String, "gpt-test")
    }

    func testThreadSettingsUpdateUsesPersistentServiceTier() {
        let parameters = AppServerClient.threadServiceTierUpdateParameters(
            threadID: "thread-1",
            serviceTier: "priority"
        )

        XCTAssertEqual(parameters["threadId"] as? String, "thread-1")
        XCTAssertEqual(parameters["serviceTier"] as? String, "priority")
    }

    func testThreadSettingsNotificationKeepsSpeedMenuInSync() throws {
        let model = AppModel()
        let thread = try XCTUnwrap(CodexThread(json: [
            "id": "thread-1",
            "cwd": "/tmp/project",
            "serviceTier": "default"
        ]))
        model.selectedThreadID = thread.id
        model.applyThreadListSnapshot([thread])

        model.handleEvent("thread/settings/updated", [
            "threadId": thread.id,
            "threadSettings": ["serviceTier": "priority"]
        ])
        XCTAssertTrue(model.isFastModeEnabled)
        XCTAssertEqual(model.threads.first?.serviceTier, "priority")

        model.handleEvent("thread/settings/updated", [
            "threadId": thread.id,
            "threadSettings": ["serviceTier": "default"]
        ])
        XCTAssertFalse(model.isFastModeEnabled)
        XCTAssertEqual(model.threads.first?.serviceTier, "default")
    }

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

    func testActiveExternalSnapshotIgnoresNonVisibleThreadTimestampChanges() throws {
        let model = AppModel()
        let original = try XCTUnwrap(CodexThread(json: [
            "id": "thread-active",
            "cwd": "/tmp/project",
            "preview": "正在处理",
            "updatedAt": 1_788_500_000,
            "status": ["type": "active"]
        ]))
        let newerSnapshot = try XCTUnwrap(CodexThread(json: [
            "id": "thread-active",
            "cwd": "/tmp/project",
            "preview": "正在处理",
            "updatedAt": 1_788_500_100,
            "status": ["type": "active"]
        ]))
        model.threads = [original]
        model.selectedThreadID = original.id

        var publishCount = 0
        let cancellable = model.$threads.dropFirst().sink { _ in
            publishCount += 1
        }
        model.applyExternalActivitySnapshot(
            ThreadActivitySnapshot(
                thread: newerSnapshot,
                turn: TurnRuntimeState(
                    id: "turn-active",
                    status: "inProgress",
                    startedAt: nil,
                    completedAt: nil
                ),
                messages: []
            ),
            threadID: original.id
        )

        XCTAssertEqual(publishCount, 0)
        XCTAssertEqual(model.threads.first?.updatedAt, original.updatedAt)
        withExtendedLifetime(cancellable) {}
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
        model.flushPendingDeltas()
        let reasoning = model.messages.first { $0.id == "reasoning-1" }
        XCTAssertEqual(reasoning?.activityKind, .reasoning)
        XCTAssertEqual(reasoning?.text, "先检查项目结构。再定位需要修改的文件。")
        XCTAssertTrue(reasoning?.isStreaming == true)

        model.handleEvent("item/reasoning/textDelta", [
            "threadId": "thread-1", "turnId": "turn-1",
            "itemId": "reasoning-live-1", "contentIndex": 0,
            "delta": "正在检查工程中的相关实现。"
        ])
        model.flushPendingDeltas()
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
        XCTAssertEqual(summaryPlaceholder?.text, "")
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
        model.flushPendingDeltas()
        let command = model.messages.first { $0.id == "command-1" }
        XCTAssertEqual(command?.activityKind, .command)
        XCTAssertTrue(command?.text.contains("swift build") == true)
        XCTAssertTrue(command?.text.contains("Build complete!") == true)

        model.handleEvent("item/fileChange/patchUpdated", [
            "threadId": "thread-1", "turnId": "turn-1", "itemId": "file-1",
            "changes": [[
                "path": "/tmp/project/App.swift",
                "kind": ["type": "update"],
                "diff": "@@ -1 +1 @@\n-old\n+new"
            ]]
        ])
        let file = model.messages.first { $0.id == "file-1" }
        XCTAssertEqual(file?.activityKind, .file)
        XCTAssertEqual(file?.text, "/tmp/project/App.swift")
        XCTAssertEqual(file?.fileChanges.first?.addedLines, 1)
        XCTAssertEqual(file?.fileChanges.first?.deletedLines, 1)

        model.handleEvent("turn/diff/updated", [
            "threadId": "thread-1", "turnId": "turn-1",
            "diff": "diff --git a/App.swift b/App.swift\n--- a/App.swift\n+++ b/App.swift\n@@ -1 +1 @@\n-old\n+new"
        ])
        let aggregate = model.messages.first { $0.id == "turn-diff-turn-1" }
        XCTAssertEqual(aggregate?.fileChanges.first?.path, "App.swift")
        XCTAssertEqual(aggregate?.fileChanges.first?.addedLines, 1)

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
        model.flushPendingDeltas()
        let output = model.messages.first { $0.id == "command-1" }?.text ?? ""
        XCTAssertLessThan(output.count, 12_100)
        XCTAssertTrue(output.hasPrefix("…已省略较早输出…"))
    }

    func testHighFrequencyDeltasPublishOneConversationUpdatePerBatch() {
        let model = AppModel()
        model.selectedThreadID = "thread-1"
        var publishCount = 0
        let cancellable = model.$messages.dropFirst().sink { _ in
            publishCount += 1
        }

        for _ in 0..<100 {
            model.handleEvent("item/agentMessage/delta", [
                "threadId": "thread-1", "turnId": "turn-1",
                "itemId": "answer-1", "delta": "字"
            ])
        }

        XCTAssertEqual(publishCount, 0)
        model.flushPendingDeltas()
        XCTAssertEqual(publishCount, 1)
        XCTAssertEqual(model.messages.first?.text.count, 100)
        withExtendedLifetime(cancellable) {}
    }

    func testCompletedAssistantMessageUsesTurnCompletionTime() {
        let model = AppModel()
        model.selectedThreadID = "thread-1"
        model.handleEvent("turn/started", [
            "threadId": "thread-1",
            "turn": ["id": "turn-1"]
        ])
        model.handleEvent("item/agentMessage/delta", [
            "threadId": "thread-1", "turnId": "turn-1",
            "itemId": "answer-1", "delta": "已经完成"
        ])
        model.flushPendingDeltas()
        XCTAssertNil(model.messages.first { $0.id == "answer-1" }?.timestamp)

        model.handleEvent("item/completed", [
            "threadId": "thread-1", "turnId": "turn-1",
            "item": ["type": "agentMessage", "id": "answer-1", "text": "已经完成"]
        ])
        XCTAssertNotNil(model.messages.first { $0.id == "answer-1" }?.timestamp)

        model.handleEvent("turn/completed", [
            "threadId": "thread-1",
            "turn": ["id": "turn-1", "status": "completed", "completedAt": 1_725_524_120]
        ])
        XCTAssertEqual(
            model.messages.first { $0.id == "answer-1" }?.timestamp,
            Date(timeIntervalSince1970: 1_725_524_120)
        )
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
        XCTAssertTrue(model.isSelectedThreadProcessing)
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
        XCTAssertFalse(model.isSelectedThreadProcessing)
        XCTAssertFalse(model.messages.contains { $0.id == "turn-progress" })
        XCTAssertEqual(model.messages.last?.id, "answer-external")
    }

    func testSelectedActiveThreadShowsThinkingBeforeExternalSnapshotArrives() throws {
        let model = AppModel()
        let activeThread = try XCTUnwrap(CodexThread(json: [
            "id": "thread-active",
            "cwd": "/tmp/project",
            "preview": "正在思考",
            "status": ["type": "active"]
        ]))
        model.threads = [activeThread]
        model.selectedThreadID = activeThread.id

        XCTAssertFalse(model.isSending)
        XCTAssertFalse(model.isExternalThreadProcessing)
        XCTAssertTrue(model.isSelectedThreadProcessing)
        model.composerText = "执行中可提交到等待队列"
        XCTAssertTrue(model.canSend)
    }

    func testSwitchingAwayFromRunningThreadDoesNotShowThinkingOnIdleThread() throws {
        let model = AppModel()
        let runningThread = try XCTUnwrap(CodexThread(json: [
            "id": "thread-running",
            "cwd": "/tmp/project",
            "preview": "正在执行",
            "status": ["type": "idle"]
        ]))
        let idleThread = try XCTUnwrap(CodexThread(json: [
            "id": "thread-idle",
            "cwd": "/tmp/project",
            "preview": "已经完成",
            "status": ["type": "idle"]
        ]))
        model.threads = [runningThread, idleThread]
        model.selectedThreadID = runningThread.id

        model.handleEvent("turn/started", [
            "threadId": runningThread.id,
            "turn": ["id": "turn-running"]
        ])
        XCTAssertTrue(model.isSelectedThreadProcessing)

        model.selectThread(idleThread.id)

        XCTAssertFalse(model.isSending)
        XCTAssertFalse(model.isSelectedThreadProcessing)
        XCTAssertTrue(model.isConversationLoading)
        XCTAssertFalse(model.isLoading)
        model.applyVisibleThreadStatuses([
            runningThread.id: "idle",
            idleThread.id: "idle"
        ])
        XCTAssertEqual(model.threads.first?.status, "active")
        model.composerText = "这是另一个任务"
        XCTAssertEqual(model.threadInputAvailability, .checking)
        XCTAssertFalse(model.canSend)
    }

    func testBackgroundTurnCompletionClearsThreadScopedSendingState() throws {
        let model = AppModel()
        let runningThread = try XCTUnwrap(CodexThread(json: [
            "id": "thread-running",
            "cwd": "/tmp/project",
            "preview": "正在执行",
            "status": ["type": "idle"]
        ]))
        let idleThread = try XCTUnwrap(CodexThread(json: [
            "id": "thread-idle",
            "cwd": "/tmp/project",
            "preview": "另一个任务",
            "status": ["type": "idle"]
        ]))
        model.threads = [runningThread, idleThread]
        model.selectedThreadID = runningThread.id
        model.handleEvent("turn/started", [
            "threadId": runningThread.id,
            "turn": ["id": "turn-running"]
        ])
        model.selectThread(idleThread.id)

        model.handleEvent("turn/completed", [
            "threadId": runningThread.id,
            "turn": ["id": "turn-running", "status": "completed"]
        ])
        model.selectThread(runningThread.id)

        XCTAssertFalse(model.isSending)
        XCTAssertFalse(model.isSelectedThreadProcessing)
        XCTAssertEqual(model.threads.first?.status, "idle")
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
            AppModel.occupiedThreadMessage
        )
        XCTAssertEqual(model.threadInputAvailability, .occupied)
        XCTAssertTrue(model.isSelectedThreadOwnedElsewhere)
        XCTAssertFalse(model.canSend)
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
