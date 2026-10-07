import Foundation

struct RemoteNotificationEventBody: Codable, Equatable {
    static let conversationCompleted = "conversation_completed"
    static let quotaRestored = "quota_restored"

    let type: String
    let eventId: String
    var threadId: String? = nil
    var turnId: String? = nil
    var threadTitle: String? = nil
}

/// Notification events survive a network outage or app restart. They contain
/// event identifiers and the conversation display title, never a full response,
/// workspace path, or credential.
@MainActor
final class RemoteNotificationOutbox {
    private let defaults: UserDefaults
    private let key = "CloudCodex.remoteControl.notificationOutbox.v1"
    private var events: [String: [String: RemoteNotificationEventBody]]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        events = defaults.data(forKey: key).flatMap {
            try? JSONDecoder().decode([String: [String: RemoteNotificationEventBody]].self, from: $0)
        } ?? [:]
    }

    func pending(deviceID: String) -> [String: RemoteNotificationEventBody] {
        events[deviceID] ?? [:]
    }

    func enqueue(deviceID: String, body: RemoteNotificationEventBody) {
        events[deviceID, default: [:]][body.eventId] = body
        persist()
    }

    func acknowledge(deviceID: String, body: RemoteNotificationEventBody) {
        guard events[deviceID]?[body.eventId] == body else { return }
        events[deviceID]?.removeValue(forKey: body.eventId)
        if events[deviceID]?.isEmpty == true { events.removeValue(forKey: deviceID) }
        persist()
    }

    private func persist() {
        if events.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: key)
        }
    }
}
