import AppKit
import XCTest
@testable import CloudCodex

@MainActor
final class MessageScrollViewportTests: XCTestCase {
    func testTimelineCacheReusesUnchangedHistoryButRefreshesStreamingText() {
        let cache = ConversationTimelineCache()
        var messages = (0..<500).map {
            ChatMessage(id: "step-\($0)", role: .activity, text: "完成步骤 \($0)", turnID: "turn")
        }
        messages.append(.init(id: "reply", role: .assistant, text: "正在生成", isStreaming: true))
        let first = cache.entries(from: messages)
        for _ in 0..<120 { XCTAssertEqual(cache.entries(from: messages), first) }
        XCTAssertEqual(cache.rebuildCount, 1)
        messages[messages.count - 1].text += "更多内容"
        XCTAssertNotEqual(cache.entries(from: messages), first)
        XCTAssertEqual(cache.rebuildCount, 2)
        XCTAssertTrue(cache.entries(from: []).isEmpty)
    }

    func testInitialBottomTracksLateLayoutAndStopsForUserScroll() {
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 600, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let document = FlippedTimelineDocument(frame: CGRect(x: 0, y: 0, width: 600, height: 1000))
        scroll.documentView = document
        window.contentView = scroll
        let controller = MessageScrollViewportController()
        defer { controller.detach(scroll); window.contentView = nil; window.close() }
        controller.followLatest() // Request may precede native attachment.
        controller.attach(scroll)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(scroll.documentVisibleRect.maxY, document.bounds.maxY, accuracy: 1)

        document.setFrameSize(CGSize(width: 600, height: 2300))
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: document)
        XCTAssertLessThan(scroll.documentVisibleRect.maxY, 2300, "no synchronous layout reentry")
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(scroll.documentVisibleRect.maxY, 2300, accuracy: 1)

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: 700))
        document.setFrameSize(CGSize(width: 600, height: 2700))
        controller.reportHistoryPosition()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(scroll.contentView.bounds.minY, 700, accuracy: 1, "reading history must not snap back")

        controller.followLatest()
        controller.detach(scroll) // Switching away cancels pending positioning.
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(scroll.contentView.bounds.minY, 700, accuracy: 1)
    }

    func testNativeFrameUsesTopOffsetForBothCoordinateDirections() {
        let viewport = CGRect(x: 20, y: 500, width: 600, height: 400)
        XCTAssertEqual(MessageScrollViewportController.topLeadingFrame(
            CGRect(x: 30, y: 550, width: 500, height: 100), in: viewport, isFlipped: true
        ), CGRect(x: 10, y: 50, width: 500, height: 100))
        XCTAssertEqual(MessageScrollViewportController.topLeadingFrame(
            CGRect(x: 30, y: 750, width: 500, height: 100), in: viewport, isFlipped: false
        ), CGRect(x: 10, y: 50, width: 500, height: 100))
    }

    func testNativeHistoryTriggerOnlyRequestsOncePerEntryAndKeepsAnchor() throws {
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 600, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 4000))
        scroll.documentView = document
        window.contentView = scroll
        defer { window.contentView = nil; window.close() }
        let controller = MessageScrollViewportController()
        controller.attach(scroll)
        let trigger = MessageHistoryProbeView(frame: CGRect(x: 0, y: 3850, width: 200, height: 28))
        trigger.role = .trigger
        document.addSubview(trigger)
        controller.register(trigger)
        let anchor = MessageHistoryProbeView(frame: CGRect(x: 0, y: 3650, width: 500, height: 160))
        anchor.role = .anchor("oldest")
        document.addSubview(anchor)
        controller.register(anchor)
        var requests = 0
        controller.onHistoryRequested = { requests += 1 }

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 3500))
        for _ in 0..<120 { controller.reportHistoryPosition() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(requests, 1)
        let frame = try XCTUnwrap(controller.viewportFrame(of: anchor))
        XCTAssertEqual(frame.minY, 90, accuracy: 1)
        XCTAssertEqual(controller.prependAlignment(for: "oldest").y, 90 / 240, accuracy: 0.001)

        scroll.contentView.scroll(to: NSPoint(x: 0, y: 2000))
        controller.reportHistoryPosition()
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 3500))
        controller.reportHistoryPosition()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(requests, 2)

        controller.unregister(trigger)
        controller.reportHistoryPosition()
        XCTAssertEqual(requests, 2)
    }
}

private final class FlippedTimelineDocument: NSView { override var isFlipped: Bool { true } }
