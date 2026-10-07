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
        // The height cache uses TextKit 1. Use that same engine for display;
        // a default NSTextView can use TextKit 2 and draw shorter paragraphs,
        // leaving its TextKit 1 allocation as a blank tail in history replies.
        let textView = ReliableSelectableNSTextView(usingTextLayoutManager: false)
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
        // SwiftUI owns the allocated frame. AppKit must not retain or grow
        // a height from an earlier, narrower layout proposal.
        textView.isVerticallyResizable = false
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
        let font = NSFont.preferredFont(forTextStyle: .body)
        if let nativeText = textView as? ReliableSelectableNSTextView {
            nativeText.setAttributedStringIfNeeded(NSAttributedString(
                string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor]
            ))
        } else if textView.string != text {
            textView.string = text
        }
        if textView.font != font { textView.font = font }
        if textView.textColor != .labelColor { textView.textColor = .labelColor }
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

        if let nativeText = textView as? ReliableSelectableNSTextView {
            nativeText.setAttributedStringIfNeeded(NSAttributedString(
                string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor]
            ))
            let size = nativeText.measuredAttributedSize(width: width)
            return CGSize(width: width, height: max(size.height, ceil(font.ascender - font.descender + font.leading)))
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
    // History rows already know their final content width. Treat it as data
    // rather than relying on intermediate SwiftUI sizing proposals.
    var layoutWidth: CGFloat? = nil
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
        // The height cache uses TextKit 1. Use that same engine for display;
        // a default NSTextView can use TextKit 2 and draw shorter paragraphs,
        // leaving its TextKit 1 allocation as a blank tail in history replies.
        let textView = ReliableSelectableNSTextView(usingTextLayoutManager: false)
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
        // SwiftUI owns the allocated frame. AppKit must not retain or grow
        // a height from an earlier, narrower layout proposal.
        textView.isVerticallyResizable = false
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

        // A useful viewport proposal already determines the width. Measuring
        // an entire reply at infinite width on every sizing pass is expensive
        // and its result is discarded by resolvedMaximumWidth in this case.
        let naturalWidth = layoutWidth != nil || (proposal.width ?? 0) >= 80
            ? 0
            : textView.naturalAttributedWidth()
        let width = layoutWidth.map { min(maximumWidth, max(80, $0)) }
            ?? ReliableSelectableText.resolvedMaximumWidth(
                proposedWidth: proposal.width,
                naturalWidth: naturalWidth,
                maximumWidth: maximumWidth
            )

        return textView.measuredAttributedSize(width: width)
    }
}

/// Keeps copying local to the message text view instead of relying entirely on
/// SwiftUI's responder-chain bridge. A conversation refresh or a surrounding
/// scroll gesture can leave an AppKit selection visible while another SwiftUI
/// view temporarily owns the key focus; making the text view first responder
/// at mouse-down and handling both copy entry points makes the visible
/// selection authoritative.
final class ReliableSelectableNSTextView: NSTextView {
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        // The final AppKit width may differ from SwiftUI's earlier sizing
        // proposal. Re-publish the height for that allocated width, including
        // when the Markdown input stayed equal during a column resize.
        if widthChanged { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: NSSize {
        guard bounds.width >= 80, renderedInput != nil else { return super.intrinsicContentSize }
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: measuredAttributedSize(width: bounds.width).height)
    }

    var copyPasteboard: NSPasteboard = .general
    private var renderedInput: NSAttributedString?
    private var cachedNaturalWidth: CGFloat?
    private var cachedLayoutSizes: [CGFloat: CGSize] = [:]
    private let measurementStorage = NSTextStorage()
    private let measurementLayoutManager = NSLayoutManager()
    private let measurementContainer = NSTextContainer(size: .zero)
    private(set) var attributedLayoutMeasurementCount = 0

    func naturalAttributedWidth() -> CGFloat {
        if let cachedNaturalWidth { return cachedNaturalWidth }
        let width = ceil((renderedInput ?? attributedString()).boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).width) + 1
        cachedNaturalWidth = width
        return width
    }

    func measuredAttributedSize(width: CGFloat) -> CGSize {
        if let size = cachedLayoutSizes[width] {
            return size
        }
        // SwiftUI asks about several hypothetical widths during one layout.
        // Resizing the displayed NSTextView here invalidates that same layout
        // and changes its selection surface. Measure in a separate TextKit
        // container; the displayed view only follows its final allocated frame.
        if measurementLayoutManager.textContainers.isEmpty {
            measurementContainer.lineFragmentPadding = 0
            measurementLayoutManager.addTextContainer(measurementContainer)
            measurementStorage.addLayoutManager(measurementLayoutManager)
        }
        measurementContainer.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        attributedLayoutMeasurementCount += 1
        measurementLayoutManager.ensureLayout(for: measurementContainer)
        let height = max(1, ceil(measurementLayoutManager.usedRect(for: measurementContainer).height))
        let size = CGSize(width: width, height: height)
        if cachedLayoutSizes.count >= 8 { cachedLayoutSizes.removeAll(keepingCapacity: true) }
        cachedLayoutSizes[width] = size
        return size
    }

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
        // AppKit normalizes textStorage attributes while laying out text.
        // Compare the last input, rather than that normalized mutable storage,
        // so an unchanged reply cannot keep resetting its native text surface.
        guard renderedInput?.isEqual(to: value) != true else { return }
        renderedInput = value.copy() as? NSAttributedString
        cachedNaturalWidth = nil
        cachedLayoutSizes.removeAll(keepingCapacity: true)
        measurementStorage.setAttributedString(value)
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
