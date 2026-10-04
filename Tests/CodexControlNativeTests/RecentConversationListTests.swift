import AppKit
import SwiftUI
import XCTest
@testable import CloudCodex

@MainActor
final class RecentConversationListTests: XCTestCase {
    func testSixtyRowsRetainNativeScrollSurfaceAndPositionAcrossSelectionAndUpdates() throws {
        var rows = try (0..<60).map { index in
            RecentConversationRow(thread: try XCTUnwrap(CodexThread(json: [
                "id": "thread-\(index)", "name": "会话 \(index)", "cwd": "/tmp/scroll-fixture",
                "preview": String(repeating: "固定高度摘要，滚动时无需临时创建行。", count: 8),
                "updatedAt": Date().timeIntervalSince1970
            ])), isSelected: index == 0, outcome: nil, showPreview: true,
               hasUnreadCompletion: false, needsUserInput: false, isFavorite: false)
        }
        func content(_ rows: [RecentConversationRow]) -> some View {
            RecentConversationList(rows: rows, onSelect: { _ in }, onRename: { _ in },
                                   onToggleFavorite: { _ in }).equatable()
                .frame(width: 400, height: 600)
        }
        let host = NSHostingView(rootView: content(rows))
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 400, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 600)
        defer { window.contentView = nil; window.close() }
        settle(host)
        let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        let height = document.frame.height
        XCTAssertGreaterThan(height, 6000, "All 60 fixed-height rows should be laid out before scrolling")
        let initialViews = Set(descendants(document).map(ObjectIdentifier.init))
        for index in 0..<120 {
            let offset = CGFloat(index % 60) * 70
            scroll.contentView.scroll(to: CGPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(document.frame.height, height, accuracy: 1)
        XCTAssertEqual(Set(descendants(document).map(ObjectIdentifier.init)), initialViews,
                       "Scrolling must not mount new native row surfaces")
        let readingPosition = scroll.contentView.bounds.origin
        let selected = rows[55]
        rows[55] = RecentConversationRow(thread: selected.thread, isSelected: true, outcome: .completed,
            showPreview: true, hasUnreadCompletion: true, needsUserInput: false, isFavorite: true)
        host.rootView = content(rows)
        settle(host)
        XCTAssertTrue(descendants(host).compactMap { $0 as? NSScrollView }.first === scroll)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, readingPosition.y, accuracy: 1,
                       "Selecting a row outside the viewport must not scroll it into view")
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func settle(_ view: NSView) {
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}
