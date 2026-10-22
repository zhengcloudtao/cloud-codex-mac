import Foundation

/// Persist the thread snapshot together with its real Codex thread ID. Keeping
/// the snapshot means an older favorite remains visible even after it falls
/// outside the regular 60-row recent-conversation window.
struct FavoriteConversations: Codable, Equatable {
    private(set) var snapshots: [String: CodexThread] = [:]

    private var appliedCommands: [String: Date] = [:]

    init() {}
    private enum CodingKeys: String, CodingKey { case snapshots, appliedCommands }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        snapshots = try values.decode([String: CodexThread].self, forKey: .snapshots)
        appliedCommands = try values.decodeIfPresent([String: Date].self, forKey: .appliedCommands) ?? [:]
    }

    func hasApplied(_ commandID: String) -> Bool { appliedCommands[commandID] != nil }

    mutating func apply(_ thread: CodexThread, favorited: Bool, commandID: String, now: Date = Date()) {
        guard !hasApplied(commandID) else { return }
        if favorited { snapshots[thread.id] = thread } else { snapshots.removeValue(forKey: thread.id) }
        appliedCommands = appliedCommands.filter { now.timeIntervalSince($0.value) < 600 }
        appliedCommands[commandID] = now
    }

    // Keep recent scheduling data intact; older favorites are additional snapshots.
    func remoteSnapshots(recent: [RemoteThreadSnapshot], allowedPaths: Set<String>) -> [RemoteThreadSnapshot] {
        let recentIDs = Set(recent.map(\.id))
        let decorated = recent.map { value -> RemoteThreadSnapshot in
            var value = value
            value.isFavorite = contains(value.id)
            return value
        }
        let older = sortedThreads().filter { !recentIDs.contains($0.id) && allowedPaths.contains($0.cwd) }.prefix(300).map {
            RemoteThreadSnapshot(id: $0.id, title: $0.displayName, workspace: $0.cwd, model: $0.model ?? "",
                                 status: "unknown", updatedAt: $0.updatedAt.timeIntervalSince1970, isFavorite: true)
        }
        return decorated + older
    }

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
