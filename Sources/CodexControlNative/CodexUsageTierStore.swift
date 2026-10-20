import Foundation
import Darwin

/// A bounded local sidecar containing only turn identifiers and acknowledged
/// tier choices. Never store prompts, account identifiers, or credentials.
enum CodexUsageTierStore {
    struct Entry: Codable, Equatable {
        let threadID: String
        let turnID: String
        let tier: String
        let source: String
        let date: Date
        var key: String { threadID + ":" + turnID }
    }
    static func home(_ override: URL? = nil) -> URL {
        if let override { return override }
        if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], !path.isEmpty { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
    static func file(_ home: URL) -> URL { home.appendingPathComponent("cloudcodex-usage-tiers.v1.json") }
    static func load(home: URL) -> [String: Entry] {
        guard let data = try? Data(contentsOf: file(home)),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [:] }
        return Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { _, new in new })
    }
    @discardableResult
    static func save(_ entry: Entry, home: URL) -> Bool {
        guard !entry.threadID.isEmpty, !entry.turnID.isEmpty,
              ["default", "standard", "priority", "fast", "ultrafast", "flex", "batch"].contains(entry.tier) else { return false }
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let lock = open(home.appendingPathComponent("cloudcodex-usage-tiers.v1.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard lock >= 0 else { return false }
            defer { flock(lock, LOCK_UN); close(lock) }
            guard flock(lock, LOCK_EX) == 0 else { return false }
            var entries = load(home: home)
            // A later request acknowledgement cannot replace a returned API tier.
            if entries[entry.key]?.source == "API 返回档位", entry.source != "API 返回档位" { return true }
            entries[entry.key] = entry
            let bounded = Array(entries.values.sorted { $0.date < $1.date }.suffix(20_000))
            try JSONEncoder().encode(bounded).write(to: file(home), options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(home).path)
            return true
        } catch { return false } // Telemetry failures must never block a task.
    }

    static func acceptedTurn(threadID: String, result: [String: Any], requested: String?, home: URL) {
        guard let turn = result["turn"] as? [String: Any], let id = turn["id"] as? String else { return }
        let response = turn["response"] as? [String: Any]
        let actual = response?["service_tier"] as? String
        let tier = actual ?? turn["serviceTier"] as? String ?? result["serviceTier"] as? String ?? requested
        guard let tier else { return }
        save(.init(threadID: threadID, turnID: id, tier: tier,
                   source: actual == nil ? "已接受请求档位，实际档未返回" : "API 返回档位", date: Date()), home: home)
    }
}
