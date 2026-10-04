import AppKit
import SwiftUI
import XCTest
@testable import CloudCodex

/// Exercises the actual three-column native layout, not only an isolated row's
/// fitting size. The fixtures never call start/selectThread or contact Codex.
@MainActor
final class ConversationLayoutTests: XCTestCase {
    func testReplyHeightRemainsTightDuringLiveColumnResize() throws {
        let suite = "CloudCodex.TextTailTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(remoteDefaults: defaults)
        let thread = try makeThread(id: "text-height", name: "文本布局验证", preview: "本地测试")
        model.threads = [thread]
        model.selectedThreadID = thread.id
        let generated = (0..<30).map { "- 第 \($0) 项验证已通过，\(String(repeating: "宽度变化后文字高度应该准确。", count: 4))" }.joined(separator: "\n")
        let markdown = try ProcessInfo.processInfo.environment["CLOUDCODEX_TEXT_LAYOUT_FIXTURE"]
            .map { try String(contentsOfFile: $0, encoding: .utf8) } ?? generated
        model.messages = [.init(id: "long-answer", role: .assistant, text: markdown)]
        let host = NSHostingView(rootView: ContentView().environmentObject(model))
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 1220, height: 780),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for width: CGFloat in [1220, 1550, 2100, 1220] {
            window.setContentSize(CGSize(width: width, height: 780))
            host.frame = try XCTUnwrap(window.contentView).bounds
            settleLayout(host)
            let scroll = try timelineScrollView(in: host)
            let text = try XCTUnwrap(descendants(of: try XCTUnwrap(scroll.documentView))
                .compactMap { $0 as? ReliableSelectableNSTextView }.first)
            let manager = try XCTUnwrap(text.layoutManager)
            let container = try XCTUnwrap(text.textContainer)
            manager.ensureLayout(for: container)
            let used = ceil(manager.usedRect(for: container).height)
            let fresh = ReliableSelectableNSTextView()
            fresh.setAttributedStringIfNeeded(MarkdownTextDocument.appKitAttributed(from: MarkdownBlockParser.parse(markdown)))
            let expected = fresh.measuredAttributedSize(width: text.bounds.width).height
            XCTAssertEqual(try XCTUnwrap(text.superview).bounds.height, expected, accuracy: 2)
            XCTAssertEqual(text.bounds.height, expected, accuracy: 2)
            XCTAssertEqual(used, expected, accuracy: 2)
        }
    }

    func testNativeHistoryPrependKeepsReadingPositionAndScrollReusesTextLayout() throws {
        let suite = "CloudCodex.ScrollPerformanceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(remoteDefaults: defaults)
        let thread = try makeThread(id: "scroll-performance", name: "滚动性能测试", preview: "本地测试")
        model.threads = [thread]
        model.selectedThreadID = thread.id
        let historyFixture = try ProcessInfo.processInfo.environment["CLOUDCODEX_TEXT_LAYOUT_FIXTURE"]
            .map { try String(contentsOfFile: $0, encoding: .utf8) }
        model.messages = (0..<40).map { index in
            .init(id: "reply-\(index)", role: .assistant,
                  text: "第 \(index) 段\n\n" + (historyFixture ?? String(repeating: "长回复上滑时保留阅读位置，并复用文本排版。\n", count: 12)))
        }
        let size = CGSize(width: 1220, height: 780)
        let host = NSHostingView(rootView: ContentView().environmentObject(model))
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: size.width, height: size.height),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        defer { window.contentView = nil; window.close() }
        settleLayout(host)
        let scroll = try timelineScrollView(in: host)
        let document = try XCTUnwrap(scroll.documentView)
        let clip = scroll.contentView
        let trigger = try XCTUnwrap(descendants(of: document).compactMap { $0 as? MessageHistoryProbeView }
            .first { $0.role == .trigger })
        let controller = try XCTUnwrap(trigger.controller)
        let originalFrame = try XCTUnwrap(controller.viewportFrame(of: trigger))
        let delta = 40 - originalFrame.minY
        let origin = clip.bounds.origin
        clip.scroll(to: CGPoint(x: origin.x, y: origin.y + (clip.isFlipped ? -delta : delta)))
        scroll.reflectScrolledClipView(clip)
        let anchorText = try XCTUnwrap(descendants(of: document).compactMap { $0 as? ReliableSelectableNSTextView }
            .first { $0.string.hasPrefix("第 28 段") })
        let before = try XCTUnwrap(controller.viewportFrame(of: anchorText)).minY
        settleLayout(host)
        XCTAssertEqual(controller.timeline.rebuildCount, 1)
        XCTAssertNotNil(descendants(of: document).compactMap { $0 as? ReliableSelectableNSTextView }
            .first { $0.string.hasPrefix("第 16 段") }, "Reaching the native preload band must add older history")
        let after = try XCTUnwrap(controller.viewportFrame(of: anchorText)).minY
        XCTAssertEqual(after, before, accuracy: 2, "Loading older messages must keep the old reply in place")

        let textViews = descendants(of: document).compactMap { $0 as? ReliableSelectableNSTextView }
        for text in textViews {
            let manager = try XCTUnwrap(text.layoutManager)
            let container = try XCTUnwrap(text.textContainer)
            manager.ensureLayout(for: container)
            XCTAssertEqual(text.bounds.height, ceil(manager.usedRect(for: container).height), accuracy: 2)
        }
        let initialMeasurements = textViews.map(\.attributedLayoutMeasurementCount)
        let initialBuilds = controller.timeline.rebuildCount
        let started = Date()
        for step in 0..<120 {
            let y = clip.bounds.origin.y + (step.isMultiple(of: 2) ? 2 : -2)
            clip.scroll(to: CGPoint(x: clip.bounds.origin.x, y: y))
            scroll.reflectScrolledClipView(clip)
            host.layoutSubtreeIfNeeded()
        }
        print("Native conversation: 120 scroll steps in \(Date().timeIntervalSince(started) * 1000) ms")
        XCTAssertEqual(textViews.map(\.attributedLayoutMeasurementCount), initialMeasurements,
                       "Scrolling unchanged replies must not measure their text again")
        XCTAssertEqual(controller.timeline.rebuildCount, initialBuilds)

        anchorText.setSelectedRange(NSRange(location: 0, length: 3))
        let positionBeforePolling = try XCTUnwrap(controller.viewportFrame(of: anchorText)).minY
        for index in 0..<20 {
            model.composerText = "无关的输入状态刷新 \(index)"
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(textViews.map(\.attributedLayoutMeasurementCount), initialMeasurements)
        XCTAssertEqual(anchorText.selectedRange(), NSRange(location: 0, length: 3))
        XCTAssertEqual(try XCTUnwrap(controller.viewportFrame(of: anchorText)).minY,
                       positionBeforePolling, accuracy: 2)
        XCTAssertEqual(controller.timeline.rebuildCount, initialBuilds)

        let readingOffset = try XCTUnwrap(controller.viewportFrame(of: anchorText)).minY
        model.messages[model.messages.count - 1].text += String(repeating: "\n后台生成的新内容", count: 12)
        settleLayout(host)
        XCTAssertEqual(try XCTUnwrap(controller.viewportFrame(of: anchorText)).minY,
                       readingOffset, accuracy: 2,
                       "An update below the viewport must not pull the reader away from older content")
        XCTAssertEqual(controller.timeline.rebuildCount, initialBuilds + 1)

        // These rows were absent initially and were created by history preload.
        // Their width must participate in the Markdown input snapshot, even
        // though their stored text and IDs stay unchanged across a resize.
        for width: CGFloat in [1550, 1220] {
            window.setContentSize(CGSize(width: width, height: 780))
            host.frame = try XCTUnwrap(window.contentView).bounds
            settleLayout(host)
            let older = try XCTUnwrap(descendants(of: document).compactMap { $0 as? ReliableSelectableNSTextView }
                .first { $0.string.hasPrefix("第 16 段") })
            let fresh = ReliableSelectableNSTextView()
            fresh.setAttributedStringIfNeeded(older.attributedString())
            let expected = fresh.measuredAttributedSize(width: older.bounds.width).height
            XCTAssertEqual(older.bounds.height, expected, accuracy: 2,
                           "A newly loaded old reply must shrink to its final content width")
            XCTAssertEqual(try XCTUnwrap(older.superview).bounds.height, expected, accuracy: 2)
            XCTAssertEqual(anchorText.selectedRange(), NSRange(location: 0, length: 3))
        }

    }

    func testResizableColumnWidthsStayWithinUsableBounds() {
        XCTAssertEqual(
            MainColumnLayout.clamped(100, to: MainColumnLayout.workspaceRange),
            MainColumnLayout.workspaceRange.lowerBound
        )
        XCTAssertEqual(
            MainColumnLayout.clamped(900, to: MainColumnLayout.workspaceRange),
            MainColumnLayout.workspaceRange.upperBound
        )
        XCTAssertEqual(
            MainColumnLayout.clamped(375, to: MainColumnLayout.threadListRange),
            375
        )
        XCTAssertLessThan(EmbeddedBrowserLayout.minimumWidth, EmbeddedBrowserLayout.idealWidth)
        XCTAssertLessThan(EmbeddedBrowserLayout.idealWidth, EmbeddedBrowserLayout.maximumWidth)
    }

    func testDetailOnlyTimelineTracksLiveWindowWidth() throws {
        let suiteName = "CloudCodex.DetailOnlyLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(remoteDefaults: defaults)
        let thread = try makeThread(
            id: "detail-only-layout",
            name: "支持解绑并重新绑定远程控制",
            preview: "验证窗口左右拖动时消息区实时自适应"
        )
        model.threads = [thread]
        model.selectedThreadID = thread.id
        model.messages = [
            .init(id: "detail-question", role: .user, text: "左右拖动的时候需要处理，不能不变"),
            .init(id: "detail-answer", role: .assistant,
                  text: String(repeating: "详情区必须随窗口宽度变化，滚动条不能停留在旧位置。", count: 12))
        ]

        let initialSize = NSSize(width: 1_220, height: 780)
        let hostingView = NSHostingView(
            rootView: ContentView(initialColumnVisibility: .detailOnly).environmentObject(model)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -4_000, y: -4_000), size: initialSize),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        hostingView.frame = NSRect(origin: .zero, size: initialSize)
        defer {
            window.contentView = nil
            window.close()
        }

        settleLayout(hostingView)
        let initialTimeline = try timelineScrollView(in: hostingView)
        let initialWidth = initialTimeline.contentView.bounds.width
        let initialFrame = initialTimeline.convert(initialTimeline.bounds, to: hostingView)
        XCTAssertLessThanOrEqual(
            hostingView.bounds.maxX - initialFrame.maxX,
            maximumTrailingScrollerGutter,
            "The initial detail timeline may reserve only the native vertical-scroller gutter"
        )

        window.setContentSize(NSSize(width: initialSize.width + 320, height: initialSize.height))
        hostingView.frame = window.contentView?.bounds ?? hostingView.frame
        settleLayout(hostingView)
        let expandedTimeline = try timelineScrollView(in: hostingView)
        let expandedFrame = expandedTimeline.convert(expandedTimeline.bounds, to: hostingView)
        XCTAssertGreaterThan(expandedTimeline.contentView.bounds.width, initialWidth + 300)
        XCTAssertLessThanOrEqual(
            hostingView.bounds.maxX - expandedFrame.maxX,
            maximumTrailingScrollerGutter,
            "The detail timeline may reserve only the native vertical-scroller gutter"
        )
        XCTAssertEqual(
            try XCTUnwrap(expandedTimeline.documentView).frame.width,
            expandedTimeline.contentView.bounds.width,
            accuracy: 1
        )
    }

    func testLongConversationRetainsItsFullVerticalScrollRange() throws {
        let suiteName = "CloudCodex.LongConversationLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(remoteDefaults: defaults)
        let thread = try makeThread(
            id: "long-scroll-range",
            name: "长会话必须可以滑动到最底下",
            preview: "验证输入框不会遮住最后一段内容"
        )
        model.threads = [thread]
        model.selectedThreadID = thread.id
        model.messages = [
            .init(
                id: "long-scroll-answer",
                role: .assistant,
                text: (1...180).map { "第 \($0) 行：长会话滚动范围必须保留。" }.joined(separator: "\n")
            )
        ]

        let contentSize = NSSize(width: 1_220, height: 640)
        let hostingView = NSHostingView(rootView: ContentView().environmentObject(model))
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
        let timeline = try timelineScrollView(in: hostingView)
        let document = try XCTUnwrap(timeline.documentView)
        XCTAssertGreaterThan(
            document.bounds.height,
            timeline.contentView.bounds.height + 1_000,
            "A long message must extend the scroll document instead of being clipped to the viewport"
        )

        let bottomY = document.isFlipped
            ? max(document.bounds.minY, document.bounds.maxY - timeline.contentView.bounds.height)
            : document.bounds.minY
        timeline.contentView.scroll(to: NSPoint(x: document.bounds.minX, y: bottomY))
        timeline.reflectScrolledClipView(timeline.contentView)
        let visible = timeline.documentVisibleRect
        if document.isFlipped {
            XCTAssertEqual(visible.maxY, document.bounds.maxY, accuracy: 1)
        } else {
            XCTAssertEqual(visible.minY, document.bounds.minY, accuracy: 1)
        }
    }

    func testFourColumnBrowserLayoutFillsConversationPaneWithoutOverflow() throws {
        let suiteName = "CloudCodex.FourColumnLayoutTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = AppModel(remoteDefaults: defaults)
        let thread = try makeThread(
            id: "four-column-layout",
            name: "四栏状态下会话和内置浏览器正确分配宽度",
            preview: "验证会话区不会留下黑色空白或伸入浏览器"
        )
        model.threads = [thread]
        model.selectedThreadID = thread.id
        model.messages = [
            .init(id: "four-column-question", role: .user, text: "打开内置浏览器后优化四栏布局"),
            .init(
                id: "four-column-answer",
                role: .assistant,
                text: String(repeating: "会话时间线必须填满自己的分栏，同时不能占用浏览器分栏。", count: 12)
            )
        ]
        model.browser.show(threadID: thread.id)
        let browserTab = try model.browser.create(threadID: thread.id)
        browserTab.webView.loadHTMLString("<html><body style='margin:0;background:#246;color:white'>Responsive browser fixture</body></html>", baseURL: nil)

        let contentSize = NSSize(width: 2_300, height: 1_200)
        let hostingView = NSHostingView(rootView: ContentView().environmentObject(model))
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
        let outerSplit = try threeColumnSplitView(in: hostingView)
        let detail = outerSplit.arrangedSubviews[2]
        let timeline = try XCTUnwrap(
            descendants(of: detail)
                .compactMap { $0 as? NSScrollView }
                .filter {
                    !$0.isHiddenOrHasHiddenAncestor
                        && $0.contentView.bounds.width > 300
                        && $0.convert($0.bounds, to: hostingView).maxX
                            < hostingView.bounds.maxX - EmbeddedBrowserLayout.minimumWidth + 1
                }
                .max {
                    $0.contentView.bounds.width * $0.contentView.bounds.height
                        < $1.contentView.bounds.width * $1.contentView.bounds.height
                }
        )
        let detailFrame = detail.convert(detail.bounds, to: hostingView)
        let timelineFrame = timeline.convert(timeline.bounds, to: hostingView)
        let trailingPanelWidth = detailFrame.maxX - timelineFrame.maxX
        try writeLayoutPreviewIfRequested(hostingView, name: "four-column-layout-preview.png")

        XCTAssertGreaterThanOrEqual(
            trailingPanelWidth,
            EmbeddedBrowserLayout.minimumWidth - 1,
            "The four-column conversation must leave the requested browser pane visible"
        )
        XCTAssertLessThanOrEqual(
            trailingPanelWidth,
            EmbeddedBrowserLayout.idealWidth + 64,
            "The browser divider must not create an extra blank strip"
        )
        XCTAssertEqual(
            try XCTUnwrap(timeline.documentView).frame.width,
            timeline.contentView.bounds.width,
            accuracy: 1
        )

        let inspectorSplit = try XCTUnwrap(
            descendants(of: detail)
                .compactMap { $0 as? NSSplitView }
                .first {
                    $0.isVertical
                        && $0.arrangedSubviews.count == 2
                        && timeline.isDescendant(of: $0.arrangedSubviews[0])
                },
            "Expected the native inspector split around the conversation and browser"
        )
        let originalDetailWidth = detail.frame.width
        let probe = try XCTUnwrap(descendants(of: detail).compactMap { $0 as? DetailColumnSizeProbeView }.first)
        XCTAssertTrue(probe.isDescendant(of: inspectorSplit.arrangedSubviews[0]),
                      "The size probe must live inside the conversation pane, not outside the inspector")
        let initialRepairCount = probe.bridgeRepairCount
        let originalDividerPosition = inspectorSplit.arrangedSubviews[0].frame.maxX
        let minimumConversationWidth: CGFloat = 300
        let maximumDividerPosition = inspectorSplit.bounds.width - EmbeddedBrowserLayout.minimumWidth
        let liveDragPositions = (0..<40).map { step in
            min(maximumDividerPosition, max(minimumConversationWidth,
                originalDividerPosition + 180 * sin(CGFloat(step) * .pi / 10)))
        } + [originalDividerPosition]
        var liveTrailingGaps: [CGFloat] = []
        var actualDividerPositions: [CGFloat] = []
        for position in liveDragPositions {
            inspectorSplit.setPosition(position, ofDividerAt: 0)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            hostingView.layoutSubtreeIfNeeded()

            actualDividerPositions.append(inspectorSplit.arrangedSubviews[0].frame.maxX)
            let browserPane = inspectorSplit.arrangedSubviews[1]
            XCTAssertEqual(inspectorSplit.bounds.width, detail.bounds.width, accuracy: 1,
                           "The native split must fill the outer detail column")
            XCTAssertEqual(browserTab.webView.frame.width, browserPane.bounds.width, accuracy: 1,
                           "The actual webpage must fill the browser pane after every divider movement")
            let addressField = try XCTUnwrap(descendants(of: browserPane).compactMap { $0 as? NSTextField }
                .first { $0.placeholderString == "https://…" })
            XCTAssertGreaterThan(addressField.frame.width, browserPane.bounds.width - 150,
                                 "The address bar must expand with the browser, not remain a narrow strip")
            let liveTimelineFrame = timeline.convert(timeline.bounds, to: hostingView)
            let liveConversationFrame = inspectorSplit.arrangedSubviews[0].convert(
                inspectorSplit.arrangedSubviews[0].bounds,
                to: hostingView
            )
            let liveTrailingGap = liveConversationFrame.maxX - liveTimelineFrame.maxX
            liveTrailingGaps.append(liveTrailingGap)
            XCTAssertGreaterThanOrEqual(liveTrailingGap, -1,
                                        "The timeline must not overflow into the browser")
            XCTAssertLessThanOrEqual(
                liveTrailingGap,
                maximumTrailingScrollerGutter,
                "The timeline scrollbar must follow the browser divider during live dragging"
            )
            XCTAssertEqual(
                detail.frame.width,
                originalDetailWidth,
                accuracy: 0.5,
                "Dragging the inspector must not mutate the outer detail column"
            )
        }
        XCTAssertLessThanOrEqual(
            (liveTrailingGaps.max() ?? 0) - (liveTrailingGaps.min() ?? 0),
            1,
            "The conversation-to-divider gap must remain stable instead of shaking between drag frames"
        )
        XCTAssertEqual(probe.bridgeRepairCount, initialRepairCount,
                       "Inspector dragging must never trigger manual bridge frame repairs")
        XCTAssertGreaterThan((actualDividerPositions.max() ?? 0) - (actualDividerPositions.min() ?? 0),
                             100, "The divider must really move, not merely retain a stable gap")

        // A short fixture at the default window size used to miss the empty
        // 600-point strip. Exercise the lifecycle of the real wide window too.
        for iteration in 0..<3 {
            model.browser.hide(threadID: thread.id)
            settleLayout(hostingView)
            let closedTimeline = try timelineScrollView(in: hostingView)
            XCTAssertLessThanOrEqual(
                hostingView.bounds.maxX - closedTimeline.convert(closedTimeline.bounds, to: hostingView).maxX,
                maximumTrailingScrollerGutter)
            model.browser.show(threadID: thread.id)
            model.messages.append(.init(id: "resize-update-\(iteration)", role: .assistant,
                                       text: String(repeating: "切换浏览器并继续更新消息。", count: 30)))
            window.setContentSize(NSSize(width: iteration == 1 ? 1_650 : 2_300, height: 1_200))
            settleLayout(hostingView)
            let refreshedDetail = try threeColumnSplitView(in: hostingView).arrangedSubviews[2]
            let split = try XCTUnwrap(descendants(of: refreshedDetail).compactMap { $0 as? NSSplitView }
                .first { $0.isVertical && $0.arrangedSubviews.count == 2 })
            let pane = split.arrangedSubviews[0]
            let scroll = try timelineScrollView(in: pane)
            XCTAssertLessThanOrEqual(pane.bounds.maxX - scroll.convert(scroll.bounds, to: pane).maxX,
                                    maximumTrailingScrollerGutter)
            XCTAssertEqual(try XCTUnwrap(scroll.documentView).frame.width,
                           scroll.contentView.bounds.width, accuracy: 1)
        }
        try writeLayoutPreviewIfRequested(hostingView, name: "four-column-layout-after-resizing.png")
    }

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
            .init(
                id: "short-answer",
                role: .assistant,
                text: String(repeating: "这是项目介绍，首次点击后详情必须立即铺满第三栏。", count: 12)
            )
        ]
        selectFixture(shortThread, messages: shortMessages, model: model)
        assertStableLayout("short conversation", hostingView: hostingView, window: window,
                           baseline: baseline, originalWindowWidth: originalWindowWidth)
        assertTimelineReachesDetailTrailingEdge(
            "first conversation selection without resizing",
            hostingView: hostingView
        )

        let mediumMessages: [ChatMessage] = [
            .init(id: "medium-question", role: .user, text: "帮我看看还有哪里有问题，和 android 不一样"),
            .init(id: "medium-answer", role: .assistant, text: "正在检查。")
        ]
        selectFixture(shortThread, messages: mediumMessages, model: model)
        assertStableLayout("natural-width user question", hostingView: hostingView, window: window,
                           baseline: baseline, originalWindowWidth: originalWindowWidth)

        // Reproduce a real conversation where several collapsed process cards
        // are interleaved with assistant commentary. Without an explicit
        // timeline width, the vertical ScrollView used the widest child's
        // intrinsic width and shifted every row under the left divider.
        let interleavedMessages = makeInterleavedProcessMessages()
        selectFixture(shortThread, messages: interleavedMessages, model: model)
        assertStableLayout("interleaved process cards and commentary", hostingView: hostingView, window: window,
                           baseline: baseline, originalWindowWidth: originalWindowWidth)
        try writeLayoutPreviewIfRequested(hostingView)

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

        var failedStep = ChatMessage(
            id: "failed-process", role: .activity,
            text: "Request failed with a deliberately long diagnostic that must stay inside the detail viewport.",
            activityKind: .tool, activityTitle: "调用接口", activityStatus: "失败",
            turnID: "failed-turn"
        )
        failedStep.startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        failedStep.completedAt = Date(timeIntervalSince1970: 1_800_000_008)
        let attachmentMessage = ChatMessage(
            id: "attachment-message", role: .user, text: "",
            attachments: [ChatMessageAttachment(
                path: "/tmp/cloudcodex-layout-wide-screenshot.png",
                name: "cloudcodex-layout-wide-screenshot.png",
                kind: .image
            )],
            turnID: "attachment-turn"
        )
        let wideFailureMessages = [
            failedStep,
            attachmentMessage,
            ChatMessage(
                id: "failure-commentary", role: .assistant,
                text: String(repeating: "失败记录、附件和长说明都必须随第三栏宽度换行。", count: 10),
                turnID: "attachment-turn"
            )
        ]
        selectFixture(shortThread, messages: wideFailureMessages, model: model)
        assertStableLayout("failed process, attachment and long commentary", hostingView: hostingView,
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

        let stoppedMessages: [ChatMessage] = [
            .init(id: "stopped-question", role: .user, text: "暂停后修改并重新执行", turnID: "stopped-turn"),
            .init(id: "stopped-step", role: .activity, text: "已终止", activityKind: .status,
                  activityTitle: "任务已停止", activityStatus: "已停止", turnID: "stopped-turn")
        ]
        selectFixture(shortThread, messages: stoppedMessages, model: model)
        model.applyExternalActivitySnapshot(
            ThreadActivitySnapshot(
                thread: shortThread,
                turn: TurnRuntimeState(
                    id: "stopped-turn",
                    status: "interrupted",
                    startedAt: nil,
                    completedAt: nil
                ),
                messages: stoppedMessages
            ),
            threadID: shortThread.id
        )
        model.beginEditingInterruptedMessage(stoppedMessages[0])
        assertStableLayout("stopped-turn inline editor", hostingView: hostingView, window: window,
                           baseline: baseline, originalWindowWidth: originalWindowWidth)
        model.cancelInterruptedMessageEdit()

        // No intermediate layout pass: stale async selection/layout callbacks
        // must not apply an earlier conversation's minimum size afterward.
        selectFixture(longThread, messages: longMessages, model: model)
        selectFixture(shortThread, messages: shortMessages, model: model)
        assertStableLayout("rapid long-to-short switch", hostingView: hostingView, window: window,
                           baseline: baseline, originalWindowWidth: originalWindowWidth)

        // Reproduce resizing the right edge of a wide CloudCodex window. The
        // timeline and its vertical scrollbar must follow the detail column
        // continuously instead of retaining the previous viewport width and
        // leaving a blank strip on the right.
        window.setContentSize(NSSize(width: contentSize.width + 320, height: contentSize.height))
        hostingView.frame = window.contentView?.bounds ?? hostingView.frame
        settleLayout(hostingView)
        let expandedSplit = try threeColumnSplitView(in: hostingView)
        XCTAssertEqual(expandedSplit.arrangedSubviews[0].frame.width, baseline[0], accuracy: 0.5)
        XCTAssertEqual(expandedSplit.arrangedSubviews[1].frame.width, baseline[1], accuracy: 0.5)
        XCTAssertGreaterThan(expandedSplit.arrangedSubviews[2].frame.width, baseline[2] + 300)

        let expandedDetail = expandedSplit.arrangedSubviews[2]
        let expandedTimeline = try XCTUnwrap(
            descendants(of: expandedDetail)
                .compactMap { $0 as? NSScrollView }
                .filter { !$0.isHiddenOrHasHiddenAncestor && $0.contentView.bounds.width > 300 }
                .max {
                    $0.contentView.bounds.width * $0.contentView.bounds.height
                        < $1.contentView.bounds.width * $1.contentView.bounds.height
                }
        )
        let expandedDocument = try XCTUnwrap(expandedTimeline.documentView)
        let expandedTimelineFrame = expandedTimeline.convert(expandedTimeline.bounds, to: hostingView)
        XCTAssertLessThanOrEqual(
            hostingView.bounds.maxX - expandedTimelineFrame.maxX,
            maximumTrailingScrollerGutter,
            "The real three-column timeline may reserve only the native vertical-scroller gutter"
        )
        XCTAssertEqual(
            expandedDocument.frame.width,
            expandedTimeline.contentView.bounds.width,
            accuracy: 1,
            "The timeline must grow with the detail column while the window is dragged wider"
        )
    }

    private func makeThread(id: String, name: String, preview: String) throws -> CodexThread {
        try XCTUnwrap(CodexThread(json: [
            "id": id, "cwd": "/workspace/school", "name": name, "preview": preview,
            "model": "gpt-6-astra", "reasoningEffort": "xhigh", "updatedAt": 1_788_500_000,
            "status": "idle"
        ]))
    }

    private func makeInterleavedProcessMessages() -> [ChatMessage] {
        var result: [ChatMessage] = [
            .init(id: "layout-question", role: .user,
                  text: "学号和姓名后一位接口为什么会请求超时", turnID: "layout-turn")
        ]

        func appendProcess(count: Int, prefix: String) {
            result.append(contentsOf: (0..<count).map { index in
                .init(
                    id: "\(prefix)-\(index)", role: .activity,
                    text: "$ inspect \(index)\n完成", activityKind: .command,
                    activityTitle: "检查调用链", activityStatus: "已完成",
                    turnID: "layout-turn"
                )
            })
        }

        appendProcess(count: 6, prefix: "first-process")
        result.append(.init(
            id: "first-commentary", role: .assistant,
            text: "目前源码里已经写明目标行为：只要本地表按学号命中，就应该立即返回，不再调用集成接口。下一步继续核对精确匹配条件。",
            turnID: "layout-turn"
        ))
        appendProcess(count: 10, prefix: "second-process")
        result.append(.init(
            id: "second-commentary", role: .assistant,
            text: "现在可以把问题拆成两段：本地命中只能保证不去补查教务接口；后面仍会请求微信 jscode2session，再检查 Redis、黑名单和用户绑定数据。",
            turnID: "layout-turn"
        ))
        appendProcess(count: 10, prefix: "third-process")
        return result
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

    private var maximumTrailingScrollerGutter: CGFloat {
        // SwiftUI/AppKit can expose the system's legacy vertical-scroller
        // reservation as part of the detail safe area in offscreen test
        // windows. It is not an empty content column and is currently 17 pt.
        NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) + 1
    }

    private func writeLayoutPreviewIfRequested(
        _ view: NSView,
        name: String = "conversation-layout-preview.png"
    ) throws {
        guard let directory = ProcessInfo.processInfo.environment["CLOUDCODEX_LAYOUT_PREVIEW_DIR"] else { return }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
    }

    private func threeColumnSplitView(in view: NSView) throws -> NSSplitView {
        let splits = descendants(of: view).compactMap { $0 as? NSSplitView }
        return try XCTUnwrap(
            splits.first { $0.isVertical && $0.arrangedSubviews.count == 3 },
            "Expected the real three-column NavigationSplitView; found child counts \(splits.map { $0.arrangedSubviews.count })"
        )
    }

    private func timelineScrollView(in view: NSView) throws -> NSScrollView {
        try XCTUnwrap(
            descendants(of: view)
                .compactMap { $0 as? NSScrollView }
                .filter {
                    !$0.isHiddenOrHasHiddenAncestor
                        && $0.contentView.bounds.width > 300
                        && ($0.documentView?.frame.height ?? 0) > 180
                }
                .max {
                    ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
                }
        )
    }

    private func assertTimelineReachesDetailTrailingEdge(
        _ phase: String,
        hostingView: NSView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        settleLayout(hostingView)
        guard let splitView = try? threeColumnSplitView(in: hostingView),
              let timeline = try? timelineScrollView(in: splitView.arrangedSubviews[2]) else {
            XCTFail("Missing detail timeline after \(phase)", file: file, line: line)
            return
        }
        let detailFrame = splitView.arrangedSubviews[2].convert(
            splitView.arrangedSubviews[2].bounds,
            to: hostingView
        )
        let timelineFrame = timeline.convert(timeline.bounds, to: hostingView)
        XCTAssertLessThanOrEqual(
            detailFrame.maxX - timelineFrame.maxX,
            maximumTrailingScrollerGutter,
            "The timeline left more than the native scroller gutter after \(phase)",
            file: file, line: line
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
        let visibleScrollViews = descendants(of: detail).compactMap { $0 as? NSScrollView }.filter {
            !$0.isHiddenOrHasHiddenAncestor && $0.contentView.bounds.width > 300
        }
        for scrollView in visibleScrollViews {
            guard !scrollView.isHiddenOrHasHiddenAncestor,
                  scrollView.contentView.bounds.width > 300,
                  let documentView = scrollView.documentView else { continue }
            XCTAssertLessThanOrEqual(
                documentView.frame.width,
                scrollView.contentView.bounds.width + 1,
                "Scroll document overflowed detail viewport after \(phase)",
                file: file,
                line: line
            )
        }
        if let timeline = visibleScrollViews.max(by: {
            $0.contentView.bounds.width * $0.contentView.bounds.height
                < $1.contentView.bounds.width * $1.contentView.bounds.height
        }), let documentView = timeline.documentView {
            XCTAssertEqual(
                documentView.frame.width,
                timeline.contentView.bounds.width,
                accuracy: 1,
                "The timeline must fill the real third-column viewport after \(phase)",
                file: file,
                line: line
            )
        } else {
            XCTFail("Missing the third-column timeline after \(phase)", file: file, line: line)
        }
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
