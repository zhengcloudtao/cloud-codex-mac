import AppKit
import SwiftUI

struct RecentConversationRow: Identifiable, Equatable {
    let thread: CodexThread
    let isSelected: Bool
    let outcome: ConversationOutcome?
    let showPreview: Bool
    let hasUnreadCompletion: Bool
    let needsUserInput: Bool
    let isFavorite: Bool
    let relativeTimeBucket: Int = Int(Date().timeIntervalSince1970 / 60)

    var id: String { thread.id }
}

/// Keep the scroll surface independent of the detail pane and model polling.
/// Recent history is capped at 60 rows. Mount that bounded set once so native
/// scrolling does not construct and measure new SwiftUI rows mid-gesture.
struct RecentConversationList: View, Equatable {
    let rows: [RecentConversationRow]
    let onSelect: (String) -> Void
    let onRename: (CodexThread) -> Void
    let onToggleFavorite: (CodexThread) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.rows == rhs.rows }

    var body: some View {
        ScrollView {
            Group {
                if rows.count <= 60 {
                    VStack(spacing: 6) { rowContent }
                } else {
                    // Favorites are not capped; keep their memory use bounded.
                    LazyVStack(spacing: 6) { rowContent }
                }
            }
            .background(ConversationListScrollerStyle())
        }
        // Empty rows have no content width. Keep the viewport full size so
        // loading and empty-state overlays receive the entire list column.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentMargins(.horizontal, 8, for: .scrollContent)
        .contentMargins(.vertical, 3, for: .scrollContent)
        .accessibilityIdentifier("recent-conversation-list")
    }

    private var rowContent: some View {
        ForEach(rows) { row in
            Button { onSelect(row.id) } label: {
                ThreadRow(thread: row.thread, isSelected: row.isSelected,
                          outcome: row.outcome, showPreview: row.showPreview,
                          hasUnreadCompletion: row.hasUnreadCompletion,
                          needsUserInput: row.needsUserInput,
                          relativeTimeBucket: row.relativeTimeBucket)
                    .equatable()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(row.thread.displayName)
            .accessibilityValue(row.isSelected ? "当前会话" : "")
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(row.isSelected ? Color.accentColor : .clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .contextMenu {
                Button { onRename(row.thread) } label: {
                    Label("编辑会话名称", systemImage: "pencil")
                }
                Divider()
                Button(row.isFavorite ? "取消收藏" : "收藏会话") {
                    onToggleFavorite(row.thread)
                }
            }
        }
    }
}

/// Apply only to the enclosing conversation list, leaving other scroll views
/// and the user's system-wide scrollbar preference unchanged.
private struct ConversationListScrollerStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> ConversationListScrollerProbe {
        ConversationListScrollerProbe()
    }

    func updateNSView(_ view: ConversationListScrollerProbe, context: Context) {
        view.configureWhenReady()
    }
}

final class ConversationListScrollerProbe: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWhenReady()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        configureWhenReady()
    }

    override func layout() {
        super.layout()
        configureWhenReady()
    }

    func configureWhenReady() {
        DispatchQueue.main.async { [weak self] in
            var ancestor = self?.superview
            while let view = ancestor, !(view is NSScrollView) {
                ancestor = view.superview
            }
            guard let scroll = ancestor as? NSScrollView else { return }
            // Keep native dragging and hover behavior, and clip the entire
            // scroller so the track has rounded ends as well as the thumb.
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
            if scroll.scrollerInsets.top != 6 || scroll.scrollerInsets.bottom != 6 {
                scroll.scrollerInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
            }
            if let scroller = scroll.verticalScroller {
                scroller.wantsLayer = true
                scroller.layer?.cornerRadius = scroller.bounds.width / 2
                scroller.layer?.masksToBounds = true
            }
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
