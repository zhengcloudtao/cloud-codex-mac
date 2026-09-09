import Foundation

/// Terminal/requeue reports survive a network outage or app restart. Credentials
/// are never stored here; reports are partitioned by the authenticated device ID.
@MainActor
final class RemoteStatusOutbox {
    private let defaults: UserDefaults
    private let key = "CloudCodex.remoteControl.statusOutbox.v1"
    private var reports: [String: [String: RemoteTaskStatusBody]]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        reports = defaults.data(forKey: key).flatMap {
            try? JSONDecoder().decode([String: [String: RemoteTaskStatusBody]].self, from: $0)
        } ?? [:]
    }

    func pending(deviceID: String) -> [String: RemoteTaskStatusBody] { reports[deviceID] ?? [:] }

    func enqueue(deviceID: String, taskID: String, body: RemoteTaskStatusBody) {
        // Once terminal, an older delayed requeue must not replace this report.
        if let existing = reports[deviceID]?[taskID], ["completed", "failed"].contains(existing.status), body.status == "queued" { return }
        reports[deviceID, default: [:]][taskID] = body
        persist()
    }

    func acknowledge(deviceID: String, taskID: String, body: RemoteTaskStatusBody) {
        guard reports[deviceID]?[taskID] == body else { return }
        reports[deviceID]?.removeValue(forKey: taskID)
        if reports[deviceID]?.isEmpty == true { reports.removeValue(forKey: deviceID) }
        persist()
    }

    private func persist() {
        if reports.isEmpty { defaults.removeObject(forKey: key) }
        else if let data = try? JSONEncoder().encode(reports) { defaults.set(data, forKey: key) }
    }
}
