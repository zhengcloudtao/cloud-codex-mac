import Foundation

/// Persist the thread snapshot together with its real Codex thread ID. Keeping
/// the snapshot means an older favorite remains visible even after it falls
/// outside the regular 60-row recent-conversation window.
struct FavoriteConversations: Codable, Equatable {
    private(set) var snapshots: [String: CodexThread] = [:]

    var isEmpty: Bool { snapshots.isEmpty }

    func contains(_ threadID: String) -> Bool {
        snapshots[threadID] != nil
    }

    func thread(_ threadID: String) -> CodexThread? {
        snapshots[threadID]
    }

    mutating func toggle(_ thread: CodexThread) {
        if contains(thread.id) {
            snapshots.removeValue(forKey: thread.id)
        } else {
            snapshots[thread.id] = thread
        }
    }

    mutating func updateIfFavorite(_ thread: CodexThread) {
        guard contains(thread.id) else { return }
        snapshots[thread.id] = thread
    }

    func sortedThreads(matching searchText: String = "") -> [CodexThread] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return snapshots.values
            .filter { thread in
                query.isEmpty
                    || thread.displayName.localizedCaseInsensitiveContains(query)
                    || thread.visiblePreview.localizedCaseInsensitiveContains(query)
            }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id < $1.id
            }
    }
}
