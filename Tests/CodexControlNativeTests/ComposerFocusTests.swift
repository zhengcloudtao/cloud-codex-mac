import AppKit
import XCTest
@testable import CloudCodex

@MainActor
final class ComposerFocusTests: XCTestCase {
    func testNewRequestFocusesAfterAttachmentButRefreshDoesNotStealFocus() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let editor = ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 140))
        let other = NSTextView(frame: NSRect(x: 0, y: 150, width: 500, height: 140))
        let request = UUID()
        editor.requestFocus(request)
        container.addSubview(editor)
        container.addSubview(other)
        window.contentView = container
        let deadline = Date().addingTimeInterval(1)
        while window.firstResponder !== editor && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertTrue(window.makeFirstResponder(other))
        editor.requestFocus(request)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(window.firstResponder === other, "Ordinary redraws must not steal focus")
        editor.requestFocus(UUID())
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(window.firstResponder === editor, "Another New Conversation action should refocus")
    }
}
