import AppKit
import XCTest
@testable import CloudCodex

@MainActor
final class ComposerInputMethodTests: XCTestCase {
    func testSuggestionDoesNotBecomeDraftOrReplaceTypingAndMarkedText() {
        let view = ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 60))
        view.suggestion = "补充验证并说明结果"
        var acceptCount = 0
        view.acceptSuggestion = { acceptCount += 1 }
        XCTAssertEqual(view.string, "")
        XCTAssertTrue(view.showsSuggestion)
        XCTAssertTrue(view.acceptVisibleSuggestion())
        XCTAssertEqual(acceptCount, 1)
        view.string = "自己的内容"
        XCTAssertFalse(view.showsSuggestion)
        XCTAssertFalse(view.acceptVisibleSuggestion())
        view.string = ""
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.showsSuggestion)
        XCTAssertFalse(view.acceptVisibleSuggestion())
        XCTAssertEqual(acceptCount, 1)
    }

    func testTabAcceptsSuggestionWithoutSubmitting() throws {
        let view = ComposerNSTextView()
        view.suggestion = "补充验证"
        var accepted = false
        var submitted = false
        view.acceptSuggestion = { accepted = true }
        view.submit = { submitted = true }
        let tab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
            isARepeat: false, keyCode: 48))
        view.keyDown(with: tab)
        XCTAssertTrue(accepted)
        XCTAssertFalse(submitted)
        XCTAssertEqual(view.string, "补充验证")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 4, length: 0))
        view.insertText("，继续", replacementRange: view.selectedRange())
        XCTAssertEqual(view.string, "补充验证，继续")
    }

    func testTabKeyEquivalentAcceptsSuggestionBeforeFocusNavigation() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = ComposerNSTextView(frame: window.contentView!.bounds)
        window.contentView = view
        window.makeFirstResponder(view)
        view.suggestion = "检查结果😀"
        var accepted = 0
        view.acceptSuggestion = { accepted += 1 }
        let tab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\t",
            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        XCTAssertTrue(view.performKeyEquivalent(with: tab))
        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(view.string, "检查结果😀")
        XCTAssertEqual(view.selectedRange(), NSRange(location: view.string.utf16.count, length: 0))
        XCTAssertTrue(window.firstResponder === view)
    }

    func testGhostTextRendersWithoutEnteringTheDocument() throws {
        let view = ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 64))
        view.appearance = NSAppearance(named: .darkAqua)
        view.font = NSFont.preferredFont(forTextStyle: .body)
        view.textContainerInset = NSSize(width: 5, height: 7)
        view.backgroundColor = .windowBackgroundColor
        view.suggestion = "补充验证并说明结果，也检查一下相关入口"
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        XCTAssertEqual(view.string, "")
        XCTAssertTrue(view.showsSuggestion)
        if let path = ProcessInfo.processInfo.environment["CLOUDCODEX_COMPOSER_PREVIEW"] {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

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
