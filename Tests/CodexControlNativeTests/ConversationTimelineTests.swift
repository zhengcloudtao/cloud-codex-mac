import AppKit
import SwiftUI
import XCTest
@testable import CloudCodex

final class ConversationTimelineTests: XCTestCase {
    private func activity(_ id: String, turn: String? = "turn", status: String = "已完成") -> ChatMessage {
        .init(id: id, role: .activity, text: "$ swift test\n测试通过", activityKind: .command,
              activityTitle: "执行命令", activityStatus: status, turnID: turn)
    }

    func testManyToolCallsBecomeOneProcessWithoutHidingQuestionOrAnswer() {
        let question = ChatMessage(id: "u", role: .user, text: "请检查项目", turnID: "turn")
        let answer = ChatMessage(id: "a", role: .assistant, text: "**检查完成**", turnID: "turn")
        let tools = (0..<300).map { activity("tool-\($0)") }
        let entries = ConversationTimeline.entries(from: [question] + tools + [answer])
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.first, .message(question))
        XCTAssertEqual(entries.last, .message(answer))
        guard case .process(let group) = entries[1] else { return XCTFail("missing compact log") }
        XCTAssertEqual(group.steps, tools)
        // Pagination now counts presentation entries, not hundreds of raw events.
        XCTAssertEqual(Array(entries.suffix(12)), entries)
    }

    func testRepliesAndTurnBoundariesPreserveChronologicalOrder() {
        let commentary = ChatMessage(id: "commentary", role: .assistant, text: "第一步完成", turnID: "one")
        let entries = ConversationTimeline.entries(from: [activity("c1", turn: "one"), commentary,
            activity("c2", turn: "one"), activity("c3", turn: "two")])
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[1], .message(commentary))
        XCTAssertEqual(entries.map(\.id), ["process:c1", "message:commentary", "process:c2", "process:c3"])
    }

    func testFileChangesBecomeOneTurnSummaryAfterTheAnswer() {
        let question = ChatMessage(id: "u", role: .user, text: "修改", turnID: "turn")
        var patchOne = activity("patch-one")
        patchOne.activityKind = .file
        patchOne.fileChanges = [
            .init(path: "A.swift", diff: "@@ -1 +1 @@\n-old\n+new", kind: .update)
        ]
        var patchTwo = activity("patch-two")
        patchTwo.activityKind = .file
        patchTwo.fileChanges = [
            .init(path: "B.swift", diff: "@@ -0,0 +1 @@\n+line", kind: .add)
        ]
        let answer = ChatMessage(id: "a", role: .assistant, text: "完成", turnID: "turn")

        let entries = ConversationTimeline.entries(from: [question, patchOne, activity("command"), patchTwo, answer])
        XCTAssertEqual(entries.map(\.id), ["message:u", "process:command", "message:a", "file-changes:turn"])
        guard case .fileChanges(let group) = entries.last else { return XCTFail("missing file summary") }
        XCTAssertEqual(group.changes.map(\.path), ["A.swift", "B.swift"])
        XCTAssertEqual(group.addedLines, 2)
        XCTAssertEqual(group.deletedLines, 1)
    }

    func testUserMessagesSeparateLegacyActivitiesWithoutTurnIDs() {
        let user = ChatMessage(id: "u", role: .user, text: "下一轮")
        let entries = ConversationTimeline.entries(from: [activity("legacy1", turn: nil), user, activity("legacy2", turn: nil)])
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[1], .message(user))
    }

    func testStreamingUpdatesAndAppendKeepGroupIdentityAndFullDetail() {
        var first = activity("command")
        first.text = String(repeating: "command log\n", count: 10_000)
        first.isStreaming = true
        let before = ConversationTimeline.entries(from: [first])
        first.text += "final output"
        first.isStreaming = false
        let after = ConversationTimeline.entries(from: [first, activity("reasoning")])
        XCTAssertEqual(before.first?.id, after.first?.id)
        guard case .process(let group) = after[0] else { return XCTFail() }
        XCTAssertEqual(group.steps[0].text, first.text, "presentation must not truncate stored logs")
        XCTAssertEqual(group.steps.count, 2)
    }

    func testProgressIsNotCountedAsAnExtraToolOrDuplicateFailure() {
        let progress = ChatMessage(id: "turn-progress", role: .activity, text: "发送失败", activityStatus: "发送失败")
        let entries = ConversationTimeline.entries(from: [progress, activity("command", status: "失败")])
        guard case .process(let group) = entries[0] else { return XCTFail() }
        XCTAssertEqual(group.steps.count, 1)
        XCTAssertEqual(group.failureCount, 1)
        XCTAssertTrue(group.hasFailure)
        XCTAssertEqual(group.progress?.text, "发送失败")
        XCTAssertEqual(group.status(isCurrent: false), "有失败记录")
        XCTAssertEqual(group.id, ConversationProcessGroup(messages: group.steps).id,
                       "completion removing synthetic progress must not reset expansion state")
    }

    func testChildTaskSummaryMergesGenericSpawnStateWithNamedActivity() {
        var spawn = activity("spawn")
        spawn.activityKind = .collaboration
        spawn.collaborationChildTasks = [
            .init(threadID: "child-1", name: "子任务 1", status: "执行中", detail: "")
        ]
        var finished = activity("finished")
        finished.activityKind = .collaboration
        finished.collaborationChildTasks = [
            .init(threadID: "child-1", name: "xili", status: "已完成", detail: "结果已返回")
        ]

        let group = ConversationProcessGroup(messages: [spawn, finished])
        XCTAssertEqual(group.childTasks, [
            .init(threadID: "child-1", name: "xili", status: "已完成", detail: "结果已返回")
        ])
    }

    func testChildTasksStayOnFinalProcessCardWhenCommentarySplitsOneTurn() {
        var started = activity("started", turn: "turn")
        started.activityKind = .collaboration
        started.collaborationChildTasks = [
            .init(threadID: "child-1", name: "xili", status: "执行中", detail: "")
        ]
        let commentary = ChatMessage(id: "commentary", role: .assistant, text: "继续检查", turnID: "turn")
        var completed = activity("completed", turn: "turn")
        completed.activityKind = .collaboration
        completed.collaborationChildTasks = [
            .init(threadID: "child-1", name: "xili", status: "已完成", detail: "")
        ]
        let latest = activity("latest", turn: "turn")

        let entries = ConversationTimeline.entries(from: [started, commentary, completed, latest])
        guard case .process(let first) = entries[0],
              case .process(let final) = entries[2] else { return XCTFail("missing split process cards") }
        XCTAssertEqual(first.childTasks.map(\.name), ["xili"])
        XCTAssertEqual(final.childTasks, [
            .init(threadID: "child-1", name: "xili", status: "已完成", detail: "")
        ], "the bottom process card should retain the whole turn's child-task summary")
        XCTAssertEqual(ConversationTimeline.latestChildTasks(from: [started, commentary, completed, latest]), [
            .init(threadID: "child-1", name: "xili", status: "已完成", detail: "")
        ], "the persistent bottom summary should use the latest collaboration turn")
    }

    func testThinkingUsesCurrentRuntimeStateNotHistoricalStreamingFlag() {
        var old = activity("old")
        old.isStreaming = true
        let group = ConversationProcessGroup(messages: [old])
        XCTAssertEqual(group.status(isCurrent: false), "已结束")
        XCTAssertEqual(group.status(isCurrent: true), "执行中")
        old.isStreaming = false
        XCTAssertEqual(ConversationProcessGroup(messages: [old]).status(isCurrent: true), "思考中")
    }

    func testQuietTurnFailureAndStopRemainVisibleWithoutSteps() {
        let progress = ChatMessage(id: "turn-progress", role: .activity, text: "连接失败", activityStatus: "失败")
        let failed = ConversationProcessGroup(messages: [progress])
        XCTAssertTrue(failed.hasFailure)
        XCTAssertTrue(failed.steps.isEmpty)
        XCTAssertEqual(failed.status(isCurrent: false), "有失败记录")
        var stopped = progress
        stopped.activityStatus = "已停止"
        XCTAssertEqual(ConversationProcessGroup(messages: [stopped]).status(isCurrent: false), "已停止")
    }

    func testEmptyHistoryAndLargeHistoryAreLossless() {
        XCTAssertTrue(ConversationTimeline.entries(from: []).isEmpty)
        let rows = (0..<10_000).map { activity("event-\($0)") }
        let entries = ConversationTimeline.entries(from: rows)
        XCTAssertEqual(entries.count, 1)
        guard case .process(let group) = entries[0] else { return XCTFail() }
        XCTAssertEqual(group.messages.map(\.id), rows.map(\.id))
    }

    @MainActor
    func testCollapsedAndExpandedLogHaveBoundedNativeLayout() {
        let group = ConversationProcessGroup(messages: (0..<300).map { activity("tool-\($0)") })
        let collapsed = NSHostingView(rootView: ConversationProcessView(group: group, isCurrent: false).frame(width: 600))
        let expanded = NSHostingView(rootView: ConversationProcessView(group: group, isCurrent: false, initiallyExpanded: true).frame(width: 600))
        XCTAssertLessThan(collapsed.fittingSize.height, 80)
        XCTAssertGreaterThan(expanded.fittingSize.height, 320)
        XCTAssertLessThan(expanded.fittingSize.height, 430, "300 steps must scroll inside a bounded container")
        let short = NSHostingView(rootView: ConversationProcessView(
            group: .init(messages: [activity("single")]), isCurrent: false,
            initiallyExpanded: true).frame(width: 600))
        XCTAssertLessThan(short.fittingSize.height, 180, "A single collapsed step must not reserve a tall empty viewport")
        let failure = ChatMessage(id: "turn-progress", role: .activity, text: String(repeating: "错误详情\n", count: 1_000), activityStatus: "失败")
        let failed = NSHostingView(rootView: ConversationProcessView(group: .init(messages: [failure]), isCurrent: false, initiallyExpanded: true).frame(width: 600))
        XCTAssertLessThan(failed.fittingSize.height, 260, "long connection errors also need a bounded viewport")
    }

    @MainActor
    func testOptionalProcessPreviewRender() throws {
        guard let directory = ProcessInfo.processInfo.environment["CLOUDCODEX_PROCESS_PREVIEW_DIR"] else { return }
        var rows = (0..<7).map { activity("step-\($0)") }
        rows[1].activityKind = .reasoning
        rows[1].activityTitle = "思考摘要"
        rows[3].activityKind = .file
        rows[3].activityTitle = "文件变更"
        rows[5].activityKind = .tool
        rows[5].activityTitle = "查看图片"
        let group = ConversationProcessGroup(messages: rows)
        let preview = VStack(alignment: .leading, spacing: 20) {
            Text("执行过程 · 默认收起").font(.headline)
            ConversationProcessView(group: group, isCurrent: true)
            Text("展开后 · 内部滚动").font(.headline).padding(.top, 10)
            ConversationProcessView(group: group, isCurrent: false, initiallyExpanded: true)
        }
        .padding(24)
        .frame(width: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
        let view = NSHostingView(rootView: preview)
        let size = view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("compact-process-preview.png"))
        window.contentView = nil
    }
}
