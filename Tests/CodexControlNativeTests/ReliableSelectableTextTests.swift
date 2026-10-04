import AppKit
import XCTest
import SwiftUI
@testable import CloudCodex

@MainActor
final class ReliableSelectableTextTests: XCTestCase {
    func testAllocatedWidthUpdatesIntrinsicHeightWithoutReplacingText() {
        let view = ReliableSelectableNSTextView()
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false
        view.setAttributedStringIfNeeded(NSAttributedString(
            string: String(repeating: "宽度变化以后，气泡必须按当前宽度收紧高度。", count: 100),
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        ))
        view.setSelectedRange(NSRange(location: 0, length: 4))
        view.setFrameSize(NSSize(width: 280, height: 3000))
        let narrowHeight = view.intrinsicContentSize.height
        view.setFrameSize(NSSize(width: 692, height: narrowHeight))
        let wideHeight = view.intrinsicContentSize.height
        XCTAssertLessThan(wideHeight, narrowHeight)
        XCTAssertEqual(wideHeight, view.measuredAttributedSize(width: 692).height)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 4))
        let measurements = view.attributedLayoutMeasurementCount
        for _ in 0..<100 { _ = view.intrinsicContentSize }
        XCTAssertEqual(view.attributedLayoutMeasurementCount, measurements)
    }

    func testWidthChangesMatchFreshTextLayout() {
        let input = NSAttributedString(string: String(repeating: "长回复应该在放宽窗口以后缩短高度，不能留下多余空白。", count: 200),
            attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let view = ReliableSelectableNSTextView()
        view.setAttributedStringIfNeeded(input)
        for width: CGFloat in [180, 692, 380, 580, 900, 200, 800] {
            let fresh = ReliableSelectableNSTextView()
            fresh.setAttributedStringIfNeeded(input)
            let expected = fresh.measuredAttributedSize(width: width)
            let actual = view.measuredAttributedSize(width: width)
            XCTAssertEqual(actual, expected)
        }
    }

    func testMarkdownAllocatedHeightMatchesDisplayedTextLayout() throws {
        let generatedMarkdown = (0..<12).map { index in
            "## 验证结果 \(index)\n\n" +
            "已完成资料整理，原有工作继续保留。\n\n" +
            "- service_school：654 项，0 失败，0 错误，2 跳过。\n" +
            "- 已完成 OSS 和数据库的实际写入，但没有将客户端重新打包，也没有进行微信开发者工具或真机端显示验收。"
        }.joined(separator: "\n\n")
        let markdown = try ProcessInfo.processInfo.environment["CLOUDCODEX_TEXT_LAYOUT_FIXTURE"]
            .map { try String(contentsOfFile: $0, encoding: .utf8) } ?? generatedMarkdown
        for width: CGFloat in [380, 600, 900] {
            let host = NSHostingView(rootView: MarkdownMessageView(
                markdown: markdown, contentWidth: min(width, UserMessagePresentation.maximumContentWidth)
            ).frame(width: width))
            let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: width, height: 500),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let text = try XCTUnwrap(descendants(host).compactMap { $0 as? ReliableSelectableNSTextView }.first)
            let manager = try XCTUnwrap(text.layoutManager)
            let container = try XCTUnwrap(text.textContainer)
            manager.ensureLayout(for: container)
            let actual = ceil(manager.usedRect(for: container).height)
            let measured = text.measuredAttributedSize(width: text.bounds.width).height
            let fresh = ReliableSelectableNSTextView()
            fresh.setAttributedStringIfNeeded(MarkdownTextDocument.appKitAttributed(from: MarkdownBlockParser.parse(markdown)))
            let freshHeight = fresh.measuredAttributedSize(width: text.bounds.width).height
            XCTAssertEqual(measured, actual, accuracy: 2)
            XCTAssertEqual(measured, freshHeight, accuracy: 2)
            XCTAssertEqual(text.bounds.height, actual, accuracy: 2, "The text surface must not leave a large empty tail")

        }
    }

    func testHypotheticalSizingDoesNotResizeDisplayedTextAndReusesAlternatingWidths() {
        let view = ReliableSelectableNSTextView(frame: CGRect(x: 0, y: 0, width: 500, height: 300))
        view.textContainer?.widthTracksTextView = true
        view.setAttributedStringIfNeeded(NSAttributedString(
            string: String(repeating: "不要在测量阶段修改正在显示的文本视图。\n", count: 100),
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        ))
        let displayedFrame = view.frame
        let displayedContainerSize = view.textContainer?.containerSize
        for _ in 0..<60 {
            _ = view.measuredAttributedSize(width: 200)
            _ = view.measuredAttributedSize(width: 500)
        }
        XCTAssertEqual(view.attributedLayoutMeasurementCount, 2)
        XCTAssertEqual(view.frame, displayedFrame)
        XCTAssertEqual(view.textContainer?.containerSize, displayedContainerSize)
    }

    func testTextStorageNormalizationDoesNotReplaceUnchangedInputOrSelection() {
        let view = ReliableSelectableNSTextView()
        let input = NSAttributedString(string: "同一条长回复", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        view.setAttributedStringIfNeeded(input)
        _ = view.measuredAttributedSize(width: 300)
        view.textStorage?.addAttribute(.toolTip, value: "native normalization", range: NSRange(location: 0, length: input.length))
        view.setSelectedRange(NSRange(location: 1, length: 3))
        view.setAttributedStringIfNeeded(input)
        _ = view.measuredAttributedSize(width: 300)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 1, length: 3))
        XCTAssertEqual(view.attributedLayoutMeasurementCount, 1)
        XCTAssertNotNil(view.textStorage?.attribute(.toolTip, at: 0, effectiveRange: nil))
    }

    func testRepeatedLongReplySizingReusesLayoutAndPreservesSelection() {
        let textView = ReliableSelectableNSTextView()
        textView.textContainer?.widthTracksTextView = true
        textView.setAttributedStringIfNeeded(NSAttributedString(
            string: String(repeating: "长回复滚动时应保持文字选择和排版。\n", count: 200),
            attributes: [.font: NSFont.systemFont(ofSize: 14)]
        ))
        let initial = textView.measuredAttributedSize(width: 500)
        textView.setSelectedRange(NSRange(location: 3, length: 8))
        for _ in 0..<100 {
            XCTAssertEqual(textView.measuredAttributedSize(width: 500), initial)
        }
        XCTAssertEqual(textView.attributedLayoutMeasurementCount, 1)
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 3, length: 8))

        let narrowed = textView.measuredAttributedSize(width: 200)
        XCTAssertGreaterThan(narrowed.height, initial.height)
        XCTAssertEqual(textView.attributedLayoutMeasurementCount, 2)

        textView.setAttributedStringIfNeeded(NSAttributedString(
            string: "新回复", attributes: [.font: NSFont.systemFont(ofSize: 14)]
        ))
        XCTAssertLessThan(textView.measuredAttributedSize(width: 200).height, narrowed.height)
        XCTAssertEqual(textView.attributedLayoutMeasurementCount, 3)
    }

    func testStyledChangeInvalidatesNaturalWidthAndHeight() {
        let textView = ReliableSelectableNSTextView()
        let content = "相同文字"
        textView.setAttributedStringIfNeeded(NSAttributedString(
            string: content, attributes: [.font: NSFont.systemFont(ofSize: 12)]
        ))
        let width = textView.naturalAttributedWidth()
        let size = textView.measuredAttributedSize(width: 300)
        textView.setAttributedStringIfNeeded(NSAttributedString(
            string: content, attributes: [.font: NSFont.systemFont(ofSize: 28)]
        ))
        XCTAssertGreaterThan(textView.naturalAttributedWidth(), width)
        XCTAssertGreaterThan(textView.measuredAttributedSize(width: 300).height, size.height)
    }

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
