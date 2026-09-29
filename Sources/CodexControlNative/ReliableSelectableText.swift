import AppKit
import SwiftUI

/// A read-only AppKit text surface for message bodies. SwiftUI's
/// `Text.textSelection` can lose the drag to the surrounding `ScrollView`,
/// especially for a single short line. NSTextView owns the complete selection
/// gesture, supports selection across wrapped lines, and keeps the current
/// selection when unrelated conversation state refreshes.
struct ReliableSelectableText: NSViewRepresentable {
    let text: String
    var maximumWidth: CGFloat = UserMessagePresentation.maximumContentWidth

    func makeNSView(context: Context) -> NSTextView {
        let textView = ReliableSelectableNSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // The first SwiftUI sizing pass can be wider than the final bubble.
        // Track the allocated view width so AppKit rewraps instead of drawing
        // text past the trailing edge after the surrounding HStack contracts.
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        // Reassigning the string clears an in-progress selection. Conversation
        // polling redraws this view frequently, so only update on real changes.
        if textView.string != text {
            textView.string = text
        }
        textView.font = .preferredFont(forTextStyle: .body)
        textView.textColor = .labelColor
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView textView: NSTextView, context: Context) -> CGSize? {
        let font = textView.font ?? .preferredFont(forTextStyle: .body)
        let naturalWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 1
        let width = Self.resolvedWidth(
            proposedWidth: proposal.width,
            naturalWidth: naturalWidth,
            hasExplicitLineBreak: text.contains("\n"),
            maximumWidth: maximumWidth
        )

        textView.frame.size.width = width
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let height = ceil(layoutManager.usedRect(for: textContainer).height)
            return CGSize(width: width, height: max(height, ceil(font.ascender - font.descender + font.leading)))
        }
        return CGSize(width: width, height: ceil(font.ascender - font.descender + font.leading))
    }

    static func resolvedMaximumWidth(
        proposedWidth: CGFloat?,
        naturalWidth: CGFloat,
        maximumWidth: CGFloat = UserMessagePresentation.maximumContentWidth
    ) -> CGFloat {
        // HStack's first sizing pass can propose zero or one point to an
        // NSViewRepresentable. Accepting that value stacks every glyph in a
        // vertical strip. Treat only a useful proposal as authoritative.
        if let proposedWidth, proposedWidth >= 80 {
            return min(maximumWidth, proposedWidth)
        }
        return min(maximumWidth, max(80, naturalWidth))
    }

    static func resolvedWidth(
        proposedWidth: CGFloat?,
        naturalWidth: CGFloat,
        hasExplicitLineBreak: Bool,
        maximumWidth: CGFloat = UserMessagePresentation.maximumContentWidth
    ) -> CGFloat {
        let proposedMaximumWidth = resolvedMaximumWidth(
            proposedWidth: proposedWidth,
            naturalWidth: naturalWidth,
            maximumWidth: maximumWidth
        )

        // SwiftUI can first offer an artificially narrow width while the
        // trailing user-message row is being measured. A short, single-line
        // question should use its real text width instead of permanently
        // wrapping inside that provisional proposal. Long or explicitly
        // multiline messages still honor the container width so they remain
        // safe in a narrow detail column.
        if !hasExplicitLineBreak,
           naturalWidth <= maximumWidth {
            // Once the row has a useful final proposal, let the native text
            // container use that available width as well. Returning only the
            // natural measurement leaves NSTextView narrower than its SwiftUI
            // background and can wrap the final one or two CJK glyphs even
            // though the bubble has plenty of empty space.
            return min(
                maximumWidth,
                max(1, naturalWidth, proposedMaximumWidth)
            )
        }
        return proposedMaximumWidth
    }
}

/// The styled counterpart used by assistant Markdown. Keeping the whole
/// rendered reply in one NSTextView makes a drag selection continuous across
/// paragraphs, lists and code while the surrounding conversation scroll view
/// remains responsible for scrolling.
struct ReliableSelectableAttributedText: NSViewRepresentable {
    typealias NSViewType = ReliableSelectableNSTextView

    let text: NSAttributedString
    var maximumWidth: CGFloat = UserMessagePresentation.maximumContentWidth
    @Environment(\.openURL) private var openURL

    final class Coordinator: NSObject, NSTextViewDelegate {
        var openURL: (URL) -> Void

        init(openURL: @escaping (URL) -> Void) {
            self.openURL = openURL
        }

        func textView(
            _ textView: NSTextView,
            clickedOnLink link: Any,
            at charIndex: Int
        ) -> Bool {
            guard let url = Self.url(from: link) else { return false }
            openURL(url)
            return true
        }

        static func url(from link: Any) -> URL? {
            if let url = link as? URL { return url }
            if let value = link as? String { return URL(string: value) }
            return nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(openURL: { openURL($0) })
    }

    func makeNSView(context: Context) -> ReliableSelectableNSTextView {
        let textView = ReliableSelectableNSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        textView.insertionPointColor = .controlAccentColor
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.required, for: .vertical)
        return textView
    }

    func updateNSView(_ textView: ReliableSelectableNSTextView, context: Context) {
        context.coordinator.openURL = { openURL($0) }
        textView.setAttributedStringIfNeeded(text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView textView: ReliableSelectableNSTextView, context: Context) -> CGSize? {
        let attributedText = text
        textView.setAttributedStringIfNeeded(attributedText)

        let naturalWidth = ceil(attributedText.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).width) + 1
        let width = ReliableSelectableText.resolvedMaximumWidth(
            proposedWidth: proposal.width,
            naturalWidth: naturalWidth,
            maximumWidth: maximumWidth
        )

        textView.frame.size.width = width
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let height = ceil(layoutManager.usedRect(for: textContainer).height)
            return CGSize(width: width, height: max(1, height))
        }
        return CGSize(width: width, height: 1)
    }
}

/// Keeps copying local to the message text view instead of relying entirely on
/// SwiftUI's responder-chain bridge. A conversation refresh or a surrounding
/// scroll gesture can leave an AppKit selection visible while another SwiftUI
/// view temporarily owns the key focus; making the text view first responder
/// at mouse-down and handling both copy entry points makes the visible
/// selection authoritative.
final class ReliableSelectableNSTextView: NSTextView {
    var copyPasteboard: NSPasteboard = .general

    override func mouseDown(with event: NSEvent) {
        _ = window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let disallowedModifiers: NSEvent.ModifierFlags = [.control, .option, .shift]
        if modifiers.contains(.command),
           modifiers.intersection(disallowedModifiers).isEmpty,
           event.charactersIgnoringModifiers?.lowercased() == "c",
           copySelectedText() {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func copy(_ sender: Any?) {
        if copySelectedText() { return }
        super.copy(sender)
    }

    /// NSTextView drops its selection whenever textStorage is replaced. Only
    /// mutate it when the rendered Markdown really changed; polling and other
    /// conversation updates can otherwise erase a selection mid-drag.
    func setAttributedStringIfNeeded(_ value: NSAttributedString) {
        guard !textStorage!.isEqual(to: value) else { return }
        textStorage?.setAttributedString(value)
    }

    @discardableResult
    func copySelectedText() -> Bool {
        let selection = selectedRange()
        guard selection.location != NSNotFound,
              selection.length > 0,
              NSMaxRange(selection) <= (string as NSString).length else {
            return false
        }

        let selectedText = (string as NSString).substring(with: selection)
        copyPasteboard.clearContents()
        return copyPasteboard.setString(selectedText, forType: .string)
    }
}
