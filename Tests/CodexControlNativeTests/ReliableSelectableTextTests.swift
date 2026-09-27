import AppKit
import XCTest
@testable import CloudCodex

@MainActor
final class ReliableSelectableTextTests: XCTestCase {
    func testCopyActionWritesExactlyTheSelectedMessageText() throws {
        let pasteboard = NSPasteboard(name: .init("CloudCodexTests.\(UUID().uuidString)"))
        let textView = ReliableSelectableNSTextView()
        textView.copyPasteboard = pasteboard
        textView.string = "前缀 要复制的文字 后缀"
        textView.setSelectedRange(try XCTUnwrap(textView.string.range(of: "要复制的文字").map {
            NSRange($0, in: textView.string)
        }))

        textView.copy(nil)

        XCTAssertEqual(pasteboard.string(forType: .string), "要复制的文字")
    }

    func testCommandCCopiesSelectionEvenWithCapsLockEnabled() throws {
        let pasteboard = NSPasteboard(name: .init("CloudCodexTests.\(UUID().uuidString)"))
        let textView = ReliableSelectableNSTextView()
        textView.copyPasteboard = pasteboard
        textView.string = "CloudCodex 复制回归"
        textView.setSelectedRange(NSRange(location: 0, length: 10))
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command, .capsLock],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ))

        XCTAssertTrue(textView.performKeyEquivalent(with: event))
        XCTAssertEqual(pasteboard.string(forType: .string), "CloudCodex")
    }

    func testCopyWithoutSelectionLeavesPasteboardUntouched() {
        let pasteboard = NSPasteboard(name: .init("CloudCodexTests.\(UUID().uuidString)"))
        pasteboard.setString("原内容", forType: .string)
        let textView = ReliableSelectableNSTextView()
        textView.copyPasteboard = pasteboard
        textView.string = "没有选区"
        textView.setSelectedRange(NSRange(location: 2, length: 0))

        XCTAssertFalse(textView.copySelectedText())
        XCTAssertEqual(pasteboard.string(forType: .string), "原内容")
    }

    func testEquivalentStyledRefreshPreservesSelection() {
        let textView = ReliableSelectableNSTextView()
        let initial = NSAttributedString(
            string: "第一段\n第二段",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        )
        textView.setAttributedStringIfNeeded(initial)
        textView.setSelectedRange(NSRange(location: 2, length: 4))

        textView.setAttributedStringIfNeeded(initial.copy() as! NSAttributedString)

        XCTAssertEqual(textView.selectedRange(), NSRange(location: 2, length: 4))
    }

    func testStyledContentChangeReplacesText() {
        let textView = ReliableSelectableNSTextView()
        textView.setAttributedStringIfNeeded(NSAttributedString(string: "旧回复"))

        textView.setAttributedStringIfNeeded(NSAttributedString(string: "新回复"))

        XCTAssertEqual(textView.string, "新回复")
    }
}
