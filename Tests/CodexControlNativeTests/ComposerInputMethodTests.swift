import AppKit
import XCTest
@testable import CloudCodex

@MainActor
final class ComposerInputMethodTests: XCTestCase {
    func testStreamingRefreshDoesNotClearChineseComposition() {
        let view = ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 160))
        view.string = "补充："
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.setMarkedText("ni hao", selectedRange: NSRange(location: 6, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        let text = view.string
        let selection = view.selectedRange()
        let markedRange = view.markedRange()
        for _ in 0..<50 {
            view.synchronizeBoundText("补充：")
            view.synchronizeBoundText("")
        }
        XCTAssertEqual(view.string, text)
        XCTAssertEqual(view.selectedRange(), selection)
        XCTAssertEqual(view.markedRange(), markedRange)
        XCTAssertTrue(view.hasMarkedText())

        view.insertText("你好", replacementRange: view.markedRange())
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.string, "补充：你好")
        view.synchronizeBoundText(view.string)
        XCTAssertEqual(view.string, "补充：你好")
        view.synchronizeBoundText("")
        XCTAssertEqual(view.string, "", "Explicit sending must still clear committed text")
    }

    func testUnchangedDraftRefreshPreservesSelection() {
        let view = ComposerNSTextView()
        view.string = "已经确认的输入"
        view.setSelectedRange(NSRange(location: 2, length: 3))
        view.synchronizeBoundText("已经确认的输入")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 2, length: 3))
    }
}
