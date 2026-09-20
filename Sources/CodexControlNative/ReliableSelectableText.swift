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
        let width = Self.resolvedWidth(
            proposedWidth: proposal.width,
            naturalWidth: naturalWidth,
            hasExplicitLineBreak: text.contains("\n")
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

    static func resolvedMaximumWidth(proposedWidth: CGFloat?, naturalWidth: CGFloat) -> CGFloat {
        // HStack's first sizing pass can propose zero or one point to an
        // NSViewRepresentable. Accepting that value stacks every glyph in a
        // vertical strip. Treat only a useful proposal as authoritative.
        if let proposedWidth, proposedWidth >= 80 {
            return min(UserMessagePresentation.maximumContentWidth, proposedWidth)
        }
        return min(UserMessagePresentation.maximumContentWidth, max(80, naturalWidth))
    }

    static func resolvedWidth(
        proposedWidth: CGFloat?,
        naturalWidth: CGFloat,
        hasExplicitLineBreak: Bool
    ) -> CGFloat {
        let maximumWidth = resolvedMaximumWidth(
            proposedWidth: proposedWidth,
            naturalWidth: naturalWidth
        )

        // SwiftUI can first offer an artificially narrow width while the
        // trailing user-message row is being measured. A short, single-line
        // question should use its real text width instead of permanently
        // wrapping inside that provisional proposal. Long or explicitly
        // multiline messages still honor the container width so they remain
        // safe in a narrow detail column.
        if !hasExplicitLineBreak,
           naturalWidth <= UserMessagePresentation.maximumContentWidth {
            // Once the row has a useful final proposal, let the native text
            // container use that available width as well. Returning only the
            // natural measurement leaves NSTextView narrower than its SwiftUI
            // background and can wrap the final one or two CJK glyphs even
            // though the bubble has plenty of empty space.
            return min(
                UserMessagePresentation.maximumContentWidth,
                max(1, naturalWidth, maximumWidth)
            )
        }
        return maximumWidth
    }
}
