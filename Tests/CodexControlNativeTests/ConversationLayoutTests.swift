import AppKit
import SwiftUI
import XCTest
@testable import CloudCodex

/// Exercises the actual three-column native layout, not only an isolated row's
/// fitting size. The fixtures never call start/selectThread or contact Codex.
@MainActor
final class ConversationLayoutTests: XCTestCase {
    func testSwitchingConversationsDoesNotResizeColumnsOrWindow() throws {
        let suiteName = "CloudCodex.ConversationLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let application = NSApplication.shared
        let originalAppearance = application.appearance
        defer { application.appearance = originalAppearance }

        let model = AppModel(remoteDefaults: defaults)
        let shortThread = try makeThread(id: "layout-short", name: "查看项目", preview: "介绍项目")
        let longThread = try makeThread(
            id: "layout-long",
            name: "shenzhen-polytechnic-3d-cocos 继续优化香蜜湖校区建筑物细节，参考 GIS 地图，并检查长标题不会改变工作区和会话列表宽度",
            preview: String(repeating: "继续优化校区建筑并验证细节", count: 8)
        )
        model.threads = [shortThread, longThread]
        model.folderCatalog = [
            WorkspaceFolder(path: shortThread.cwd, threadCount: 2, latestUpdate: .distantPast)
        ]
        model.modelOptions = [try XCTUnwrap(CodexModelOption(json: [
            "id": "gpt-6-astra", "model": "gpt-6-astra", "displayName": "GPT-6-Astra",
            "defaultReasoningEffort": "xhigh",
            "supportedReasoningEfforts": [["reasoningEffort": "xhigh"]]
        ]))]
        model.selectedModelID = "gpt-6-astra"
        model.selectedEffort = "xhigh"
        model.composerText = "仅用于布局测试，不发送"

        let contentSize = NSSize(width: 1_220, height: 780)
        let hostingView = NSHostingView(rootView: ContentView().environmentObject(model))
        // Keep this test window offscreen and never make it key or frontmost.
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -4_000, y: -4_000), size: contentSize),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.frame = NSRect(origin: .zero, size: contentSize)
        defer {
            window.contentView = nil
            window.close()
        }

        settleLayout(hostingView)
        let splitView = try threeColumnSplitView(in: hostingView)
        let baseline = splitView.arrangedSubviews.map { $0.frame.width }
        let originalWindowWidth = window.frame.width
        XCTAssertEqual(baseline.count, 3)
        XCTAssertGreaterThan(baseline[0], 150, "The workspace column must actually be laid out")
        XCTAssertGreaterThan(baseline[1], 250, "The conversation list must actually be laid out")
        XCTAssertGreaterThan(baseline[2], 350, "The detail column must actually be laid out")

        let shortMessages: [ChatMessage] = [
            .init(id: "short-question", role: .user, text: "介绍项目"),
            .init(id: "short-answer", role: .assistant, text: "这是项目介绍。")
        ]
        selectFixture(shortThread, messages: shortMessages, model: model)
        assertStableLayout("short conversation", hostingView: hostingView, window: window,
                           baseline: baseline, originalWindowWidth: originalWindowWidth)

        // 75 Chinese characters used to qualify as a 'compact' bubble even
        // though its unwrapped intrinsic width exceeded the entire detail pane.
        let longQuestion = String(repeating: "继续优化校园建筑细节并验证结果", count: 5)
        XCTAssertEqual(longQuestion.count, 75)
        let longMessages: [ChatMessage] = [
            .init(id: "long-question", role: .user, text: longQuestion),
            .init(id: "long-answer", role: .assistant, text: "```swift\n" +
                  String(repeating: "long_unbroken_identifier_", count: 30) + "\n```\n\n" +
                  "| 文件 | 结果 |\n| --- | --- |\n| " + String(repeating: "目录/", count: 45) + " | 完成 |")
        ]
        selectFixture(longThread, messages: longMessages, model: model)
        assertStableLayout("long title, single-line question and wide Markdown", hostingView: hostingView,
                           window: window, baseline: baseline, originalWindowWidth: originalWindowWidth)

        var activeThread = longThread
        activeThread.status = "active"
        model.applyExternalActivitySnapshot(
            ThreadActivitySnapshot(
                thread: activeThread,
                turn: TurnRuntimeState(id: "layout-turn", status: "inProgress", startedAt: nil, completedAt: nil),
                messages: []
            ),
            threadID: activeThread.id
        )
        assertStableLayout("running-state composer and process indicator", hostingView: hostingView,
                           window: window, baseline: baseline, originalWindowWidth: originalWindowWidth)

        selectFixture(shortThread, messages: shortMessages, model: model)
        assertStableLayout("switch back to short conversation", hostingView: hostingView, window: window,
                           baseline: baseline, originalWindowWidth: originalWindowWidth)

        // No intermediate layout pass: stale async selection/layout callbacks
        // must not apply an earlier conversation's minimum size afterward.
        selectFixture(longThread, messages: longMessages, model: model)
        selectFixture(shortThread, messages: shortMessages, model: model)
        assertStableLayout("rapid long-to-short switch", hostingView: hostingView, window: window,
                           baseline: baseline, originalWindowWidth: originalWindowWidth)
    }

    private func makeThread(id: String, name: String, preview: String) throws -> CodexThread {
        try XCTUnwrap(CodexThread(json: [
            "id": id, "cwd": "/workspace/school", "name": name, "preview": preview,
            "model": "gpt-6-astra", "reasoningEffort": "xhigh", "updatedAt": 1_788_500_000,
            "status": "idle"
        ]))
    }

    private func selectFixture(_ thread: CodexThread, messages: [ChatMessage], model: AppModel) {
        // Direct fixture assignment intentionally bypasses all asynchronous
        // app-server reads; this regression concerns SwiftUI/AppKit layout only.
        model.isExternalThreadProcessing = false
        model.selectedThreadID = thread.id
        model.messages = messages
    }

    private func settleLayout(_ view: NSView) {
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        view.layoutSubtreeIfNeeded()
    }

    private func threeColumnSplitView(in view: NSView) throws -> NSSplitView {
        let splits = descendants(of: view).compactMap { $0 as? NSSplitView }
        return try XCTUnwrap(
            splits.first { $0.isVertical && $0.arrangedSubviews.count == 3 },
            "Expected the real three-column NavigationSplitView; found child counts \(splits.map { $0.arrangedSubviews.count })"
        )
    }

    private func assertStableLayout(
        _ phase: String, hostingView: NSView, window: NSWindow,
        baseline: [CGFloat], originalWindowWidth: CGFloat,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        settleLayout(hostingView)
        guard let splitView = try? threeColumnSplitView(in: hostingView) else {
            XCTFail("Missing three-column split after \(phase)", file: file, line: line)
            return
        }
        XCTAssertEqual(window.frame.width, originalWindowWidth, accuracy: 0.5,
                       "Window resized after \(phase)", file: file, line: line)
        for (index, column) in splitView.arrangedSubviews.enumerated() {
            XCTAssertEqual(column.frame.width, baseline[index], accuracy: 0.5,
                           "Column \(index) resized after \(phase)", file: file, line: line)
            XCTAssertGreaterThanOrEqual(column.frame.minX, -0.5,
                                        "Column moved outside split after \(phase)", file: file, line: line)
            XCTAssertLessThanOrEqual(column.frame.maxX, splitView.bounds.maxX + 0.5,
                                     "Column overflowed split after \(phase)", file: file, line: line)
        }

        // SwiftUI exposes some controls as virtual accessibility elements, so
        // this additionally checks the native buttons that exist in the detail
        // subtree without incorrectly requiring every SwiftUI button to be one.
        let detail = splitView.arrangedSubviews[2]
        for button in descendants(of: detail).compactMap({ $0 as? NSButton })
            where !button.isHiddenOrHasHiddenAncestor && button.bounds.width > 0 {
            let frame = button.convert(button.bounds, to: detail)
            XCTAssertGreaterThanOrEqual(frame.minX, detail.bounds.minX - 0.5,
                                        "Button overflowed detail left edge after \(phase)", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, detail.bounds.maxX + 0.5,
                                     "Button overflowed detail right edge after \(phase)", file: file, line: line)
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}
