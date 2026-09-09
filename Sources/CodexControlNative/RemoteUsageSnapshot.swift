import Foundation
import CryptoKit

/// Whitelisted account quota data only. Never forward account IDs, tokens,
/// credit redemption IDs, or raw backend responses to the relay.
struct RemoteUsageSnapshot: Codable, Equatable {
    let capturedAt: Double
    let available: Bool
    let buckets: [Bucket]
    let resetCredits: ResetCredits?

    struct Window: Codable, Equatable {
        let usedPercent: Double?
        let windowDurationMins: Int?
        let resetsAt: Double?
    }
    struct Bucket: Codable, Equatable {
        let id: String
        let name: String
        let windows: [Window]
    }
    struct ResetCredits: Codable, Equatable {
        var credits: [ResetCredit]? = nil
        let availableCount: Int?
        // nil = details unavailable; [] = fetched but no available detail rows.
        let expirations: [Double?]?
    }
    struct ResetCredit: Codable, Equatable {
        let ref: String
        let expiresAt: Double?
        let resetType: String
    }
    static func creditReference(_ id: String) -> String {
        SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func unavailable() -> Self {
        .init(capturedAt: Date().timeIntervalSince1970, available: false, buckets: [], resetCredits: nil)
    }

    static func parse(_ json: [String: Any], now: Date = Date()) -> Self {
        var snapshots = json["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        if snapshots.isEmpty, let legacy = json["rateLimits"] as? [String: Any] {
            snapshots[legacy["limitId"] as? String ?? "codex"] = legacy
        }
        let buckets = snapshots.keys.sorted().prefix(20).compactMap { id -> Bucket? in
            guard let bucket = snapshots[id] else { return nil }
            let windows = ["primary", "secondary"].compactMap { key -> Window? in
                guard let window = bucket[key] as? [String: Any] else { return nil }
                let used = (window["usedPercent"] as? NSNumber)?.doubleValue
                return Window(usedPercent: used.flatMap { $0.isFinite ? min(100, max(0, $0)) : nil },
                              windowDurationMins: window["windowDurationMins"] as? Int,
                              resetsAt: (window["resetsAt"] as? NSNumber)?.doubleValue)
            }
            return Bucket(id: id, name: bucket["limitName"] as? String ?? id, windows: windows)
        }
        var resets: ResetCredits?
        if let summary = json["rateLimitResetCredits"] as? [String: Any] {
            let credits = summary["credits"] as? [[String: Any]]
            resets = ResetCredits(availableCount: (summary["availableCount"] as? Int).map { max(0, $0) },
                                  expirations: credits.map { rows in
                Array(rows.filter { $0["status"] as? String == "available" }.prefix(100)).map { ($0["expiresAt"] as? NSNumber)?.doubleValue }
            })
            resets?.credits = credits.map { rows in
                rows.filter { $0["status"] as? String == "available" }.prefix(100).compactMap { row in
                    guard let id = row["id"] as? String, !id.isEmpty else { return nil }
                    return ResetCredit(ref: creditReference(id), expiresAt: (row["expiresAt"] as? NSNumber)?.doubleValue, resetType: row["resetType"] as? String ?? "unknown")
                }
            }
        }
        return .init(capturedAt: now.timeIntervalSince1970, available: true, buckets: buckets, resetCredits: resets)
    }
}
