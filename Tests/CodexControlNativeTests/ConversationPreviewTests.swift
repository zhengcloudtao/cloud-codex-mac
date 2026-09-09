import AppKit
import SwiftUI
import XCTest
@testable import CloudCodex

@MainActor
final class ConversationPreviewTests: XCTestCase {
    func testHiddenPreviewUsesCompactStableRowHeight() throws {
        let thread = try XCTUnwrap(CodexThread(json: [
            "id": "preview-test", "cwd": "/tmp/project", "name": "标题", "preview": "两行内容摘要"
        ]))
        let normal = NSHostingView(rootView: ThreadRow(thread: thread, showPreview: true).frame(width: 330))
        let compact = NSHostingView(rootView: ThreadRow(thread: thread, showPreview: false).frame(width: 330))
        XCTAssertEqual(normal.fittingSize.height, 96, accuracy: 1)
        XCTAssertEqual(compact.fittingSize.height, 58, accuracy: 1)
        let selected = NSHostingView(rootView: ThreadRow(thread: thread, isSelected: true,
            outcome: .completed, showPreview: false).frame(width: 330))
        XCTAssertEqual(selected.fittingSize.height, compact.fittingSize.height, accuracy: 1)
    }
}
