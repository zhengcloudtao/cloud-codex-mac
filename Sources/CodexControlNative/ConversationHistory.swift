import Foundation

/// Snapshots are not a replacement for the live event journal: summary reads
/// may omit output and can lag the events already received by this client.
enum ConversationHistory {
    static func merge(snapshot: [ChatMessage], cached: [ChatMessage]) -> [ChatMessage] {
        // A local user bubble becomes the server item, not a second question.
        let confirmedUsers = snapshot.filter { $0.role == .user && $0.turnID != nil }
        var matchedSteerIDs: Set<String> = []
        var result = cached.map { old in
            if old.id.hasPrefix("local-steer-") {
                if let confirmed = confirmedUsers.first(where: {
                    $0.turnID == old.turnID && $0.text == old.text && $0.attachments == old.attachments
                        && !matchedSteerIDs.contains($0.id)
                }) {
                    matchedSteerIDs.insert(confirmed.id)
                    return confirmed
                }
                return old
            }
            if old.id.hasPrefix("local-"), let turnID = old.turnID,
               let confirmed = confirmedUsers.first(where: { $0.turnID == turnID }) {
                return confirmed
            }
            return old
        }
        var seen: Set<String> = []
        result = result.filter { seen.insert($0.id).inserted }
        for (offset, incoming) in snapshot.enumerated() {
            if let index = result.firstIndex(where: { $0.id == incoming.id }) {
                let old = result[index]
                var new = incoming
                if old.text.count > new.text.count && (old.isStreaming || old.role == .activity) {
                    new.text = old.text
                }
                if !old.isStreaming && new.isStreaming {
                    new.isStreaming = false
                    new.activityStatus = old.activityStatus
                }
                new.model = new.model ?? old.model
                new.reasoningEffort = new.reasoningEffort ?? old.reasoningEffort
                new.serviceTier = new.serviceTier ?? old.serviceTier
                new.turnID = new.turnID ?? old.turnID
                new.timestamp = new.timestamp ?? old.timestamp
                new.startedAt = new.startedAt ?? old.startedAt
                new.completedAt = new.completedAt ?? old.completedAt
                result[index] = new
            } else {
                let existingIDs = Set(result.map(\.id))
                let nextID = snapshot.dropFirst(offset + 1).first { existingIDs.contains($0.id) }?.id
                if let nextID, let index = result.firstIndex(where: { $0.id == nextID }) {
                    result.insert(incoming, at: index)
                } else {
                    result.append(incoming)
                }
            }
        }
        return result
    }
}
