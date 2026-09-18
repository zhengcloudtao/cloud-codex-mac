import AppKit
import SwiftUI

/// A read-only AppKit text surface for message bodies. SwiftUI's
/// `Text.textSelection` can lose the drag to the surrounding `ScrollView`,
/// especially for a single short line. NSTextView owns the complete selection
/// gesture, supports selection across wrapped lines, and keeps the current
/// selection when unrelated conversation state refreshes.
struct ReliableSelectableText: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView(frame: .zero)
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
        let maximumWidth = Self.resolvedMaximumWidth(
            proposedWidth: proposal.width,
            naturalWidth: naturalWidth
        )
        let width = text.contains("\n") ? maximumWidth : min(maximumWidth, max(1, naturalWidth))

        textView.frame.size.width = width
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
            layoutManager.ensureLayout(for: textContainer)
            let height = ceil(layoutManager.usedRect(for: textContainer).height)
            return CGSize(width: width, height: max(height, ceil(font.ascender - font.descender + font.leading)))
        }
        return CGSize(width: width, height: ceil(font.ascender - font.descender + font.leading))
    }

    static func resolvedMaximumWidth(proposedWidth: CGFloat?, naturalWidth: CGFloat) -> CGFloat {
        // HStack's first sizing pass can propose zero or one point to an
        // NSViewRepresentable. Accepting that value stacks every glyph in a
        // vertical strip. Treat only a useful proposal as authoritative.
        if let proposedWidth, proposedWidth >= 80 {
            return min(UserMessagePresentation.maximumContentWidth, proposedWidth)
        }
        return min(UserMessagePresentation.maximumContentWidth, max(80, naturalWidth))
    }
}
