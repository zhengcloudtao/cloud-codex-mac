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
            if rows.count <= 60 {
                VStack(spacing: 6) { rowContent }
            } else {
                // Favorites are not capped; keep their memory use bounded.
                LazyVStack(spacing: 6) { rowContent }
            }
        }
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
