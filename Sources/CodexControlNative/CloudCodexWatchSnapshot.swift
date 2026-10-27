import Foundation

// Wire contract v1, mirrored in CloudCodex and CloudTimetable. Unix seconds throughout.
struct CloudCodexWatchSnapshot: Codable, Equatable {
    let version: Int
    let capturedAt: Double
    let quotaCapturedAt: Double?
    let plan: String?
    let subscriptionPeriodEnd: Double?
    let fiveHourRemaining: Double?
    let weeklyRemaining: Double?
    let fiveHourResetsAt: Double?
    let weeklyResetsAt: Double?
    let tasks: [TaskStatus]
    let runningCount: Int
    let waitingCount: Int
    var queuedCount: Int? = nil
    // Optional additions preserve decoding of v1 snapshots from older clients.
    var creditBalanceText: String? = nil
    var availableResetCount: Int? = nil
    var weeklyPaceLabel: String? = nil
    var weeklyPaceState: String? = nil
    struct TaskStatus: Codable, Equatable, Identifiable {
        let id: String
        let title: String
        let status: String
    }
    func isStale(at date: Date) -> Bool { date.timeIntervalSince1970 - capturedAt > 300 }
    func quotaIsStale(at date: Date) -> Bool {
        guard let quotaCapturedAt else { return true }
        return date.timeIntervalSince1970 - quotaCapturedAt > 300
    }
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return "\(Int(min(100, max(0, value)).rounded()))%"
    }
}
