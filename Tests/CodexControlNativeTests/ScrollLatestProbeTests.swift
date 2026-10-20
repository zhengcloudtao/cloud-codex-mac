import AppKit
import XCTest
@testable import CloudCodex

@MainActor
final class ScrollLatestProbeTests: XCTestCase {
    func testBoundsNotificationDoesNotReenterScrollLayoutAndDisconnectCancelsQueuedWork() {
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000))
        let probe = ScrollLatestProbeView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        document.addSubview(probe)
        scroll.documentView = document
        window.contentView = scroll
        defer { probe.disconnect(); window.contentView = nil; window.close() }
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))

        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 80, y: 40))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
        // The notification may be inside a SwiftUI layout/CA commit. It must
        // not synchronously scroll again, even when horizontal repair is needed.
        XCTAssertEqual(clip.bounds.minX, 80, accuracy: 0.5)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(clip.bounds.minX, 0, accuracy: 0.5)
        XCTAssertEqual(clip.bounds.minY, 40, accuracy: 0.5)

        clip.scroll(to: NSPoint(x: 80, y: 40))
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: clip)
        probe.disconnect() // As when switching away before queued work executes.
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(clip.bounds.minX, 80, accuracy: 0.5)
    }
}
