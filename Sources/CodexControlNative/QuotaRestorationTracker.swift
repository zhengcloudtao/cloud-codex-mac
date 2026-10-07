import Foundation

/// Track each quota window independently, including weekly-only accounts.
/// Missing samples retain the last known value; first readings never notify.
struct QuotaRestorationTracker {
    private var bucketID: String?
    private var previousUsed: [Int: Double] = [:]
    private var capturedAt: Double?

    mutating func record(_ overview: AccountOverview) -> Bool {
        let readings = Self.readings(in: overview)
        guard !readings.isEmpty, overview.usage.capturedAt.isFinite else { return false }
        if let capturedAt, overview.usage.capturedAt <= capturedAt { return false }
        if bucketID != overview.primaryBucket?.id {
            previousUsed.removeAll()
            bucketID = overview.primaryBucket?.id
        }
        var restored = false
        for (minutes, used) in readings {
            if let old = previousUsed[minutes], old > 0.001, used <= 0.001 {
                restored = true
            }
            previousUsed[minutes] = used
        }
        capturedAt = overview.usage.capturedAt
        return restored
    }

    static func didRestore(from previous: AccountOverview?, to current: AccountOverview) -> Bool {
        guard let previous, previous.primaryBucket?.id == current.primaryBucket?.id else { return false }
        let old = readings(in: previous)
        return readings(in: current).contains { minutes, used in
            guard let previousUsed = old[minutes] else { return false }
            return previousUsed > 0.001 && used <= 0.001
        }
    }

    private static func readings(in overview: AccountOverview) -> [Int: Double] {
        guard overview.usage.available, let bucket = overview.primaryBucket else { return [:] }
        var values: [Int: Double] = [:]
        for window in bucket.windows {
            guard let minutes = window.windowDurationMins, [300, 10_080].contains(minutes),
                  let used = window.usedPercent, used.isFinite, (0...100).contains(used) else { continue }
            values[minutes] = used
        }
        return values
    }
}
