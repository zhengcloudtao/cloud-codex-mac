import Foundation

/// Count conversations, not streamed messages. Remember acknowledged turns so
/// duplicate completion events and history refreshes cannot re-add a badge.
struct UnreadCompletions: Codable, Equatable {
    var latestTurns: [String: String] = [:]
    var unread: Set<String> = []

    @discardableResult
    mutating func complete(threadID: String, turnID: String, viewed: Bool) -> Bool {
        guard latestTurns[threadID] != turnID else { return false }
        latestTurns[threadID] = turnID
        if viewed { unread.remove(threadID) } else { unread.insert(threadID) }
        return true
    }

    mutating func markRead(_ threadID: String) { unread.remove(threadID) }

    mutating func markAllRead() { unread.removeAll() }
}
