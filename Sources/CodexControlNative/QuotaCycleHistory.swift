import Foundation

/// Account-scoped observations. Token totals cover live CloudCodex events only;
/// Quota percentages are account-wide. Proportional estimates are display-only
/// and never replace observed token totals.
struct QuotaCycleHistory: Codable, Equatable {
    static let defaultsKey = "cloudcodex.quotaCycles.v1"

    struct Breakdown: Codable, Equatable {
        var input: Int64 = 0
        var output: Int64 = 0
        var total: Int64 { input + output }
    }

    struct Sample: Codable, Equatable {
        let capturedAt: Double
        let usedPercent: Double
        let tokens: Int64
        var breakdown: Breakdown? = nil

        func hasSameUsage(as other: Sample) -> Bool {
            usedPercent == other.usedPercent && tokens == other.tokens && breakdown == other.breakdown
        }
    }

    enum GapReason: String, Codable {
        case missedReset, partialTokens, tokenOverflow, unrecordedTokenDelta
    }

    struct Cycle: Codable, Equatable, Identifiable {
        var id = UUID()
        let bucketID: String
        let minutes: Int
        let startedAt: Double
        var endedAt: Double?
        var initialUsedPercent: Double?
        var startingUsedPercent: Double { initialUsedPercent ?? samples.first?.usedPercent ?? 0 }
        var tokens: Int64 = 0
        var breakdown: Breakdown? = nil
        var unclassifiedTokens: Int64 { max(0, tokens - (breakdown?.total ?? 0)) }
        var consumedPercent: Double = 0
        var samples: [Sample] = []
        // Optional for compatibility with v1 records, which stored only a
        // blanket restart flag and cannot establish that data was actually lost.
        var gapReasons: [GapReason]?
        var hasObservationGap: Bool { !(gapReasons ?? []).isEmpty }

        mutating func recordGap(_ reason: GapReason) {
            if gapReasons == nil { gapReasons = [] }
            if gapReasons?.contains(reason) == false { gapReasons?.append(reason) }
        }
        var lastReset: Double?
        var hasUsage = false

        var title: String { minutes == 300 ? "5 小时额度" : "每周额度" }

        var estimatedInputTokens: Double? {
            guard unclassifiedTokens == 0, let breakdown, let total = estimatedTotalTokens else { return nil }
            return total * Double(breakdown.input) / Double(tokens)
        }

        var estimatedOutputTokens: Double? {
            guard unclassifiedTokens == 0, let breakdown, let total = estimatedTotalTokens else { return nil }
            return total * Double(breakdown.output) / Double(tokens)
        }

        /// A proportional projection, not an account-provided token allowance.
        var estimatedTotalTokens: Double? {
            guard tokens > 0, consumedPercent.isFinite, consumedPercent > 0 else { return nil }
            let estimate = Double(tokens) / consumedPercent * 100
            return estimate.isFinite ? estimate : nil
        }
    }

    private(set) var cycles: [Cycle] = []
    private var activeBucketID: String?

    static func load(_ defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              var history = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        // Old hasObservationGap booleans mixed restarts with actual evidence.
        // Do not carry those unproven warnings forward. New reasons persist.
        for index in history.cycles.indices {
            if history.cycles[index].gapReasons == nil { history.cycles[index].gapReasons = [] }
            // Legacy partialTokens used a sticky per-turn history flag, not
            // evidence of a missing delta inside this quota cycle.
            history.cycles[index].gapReasons?.removeAll { $0 == .partialTokens }
            var compacted: [Sample] = []
            for sample in history.cycles[index].samples {
                if let previous = compacted.last, sample.hasSameUsage(as: previous) {
                    compacted[compacted.count - 1] = sample
                } else {
                    compacted.append(sample)
                }
            }
            history.cycles[index].samples = compacted
        }
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: defaultsKey)
        }
        return history
    }

    mutating func record(_ overview: AccountOverview) {
        guard overview.usage.available, let bucket = overview.primaryBucket,
              overview.usage.capturedAt.isFinite else { return }
        for window in bucket.windows {
            guard let minutes = window.windowDurationMins, [300, 10_080].contains(minutes),
                  let used = window.usedPercent, used.isFinite, (0...100).contains(used) else { continue }
            record(bucketID: bucket.id, minutes: minutes, used: used,
                   at: overview.usage.capturedAt, resetsAt: window.resetsAt)
        }
    }

    mutating func record(bucketID: String, minutes: Int, used: Double, at: Double, resetsAt: Double?) {
        guard at.isFinite, used.isFinite, (0...100).contains(used) else { return }
        activeBucketID = bucketID
        let reset = resetsAt.flatMap { $0.isFinite ? $0 : nil }
        if let index = cycles.lastIndex(where: { $0.bucketID == bucketID && $0.minutes == minutes && $0.endedAt == nil }) {
            guard let previous = cycles[index].samples.last, at > previous.capturedAt else { return }
            let resetChanged = reset != nil && cycles[index].lastReset != nil && abs(reset! - cycles[index].lastReset!) > 1
            let restored = used <= 0.001 && (cycles[index].hasUsage || (cycles[index].tokens > 0 && resetChanged))
            // A reset boundary moved after usage, but no full-quota sample
            // was seen: at least the cycle boundary was missed. Idle reset-time
            // changes and partial quota restorations alone do not prove a gap.
            if resetChanged && ((previous.usedPercent > 0.001 && !restored)
                || (restored && !cycles[index].hasUsage)) {
                cycles[index].recordGap(.missedReset)
            }
            cycles[index].consumedPercent += max(0, used - previous.usedPercent)
            cycles[index].hasUsage = cycles[index].hasUsage || used > 0.001
            cycles[index].lastReset = reset
            let sample = Sample(capturedAt: at, usedPercent: used, tokens: cycles[index].tokens, breakdown: cycles[index].breakdown)
            if sample.hasSameUsage(as: previous) {
                // Keep the latest observation for freshness/stale-event rejection;
                // the original cycle start is retained separately in startedAt.
                cycles[index].samples[cycles[index].samples.count - 1] = sample
            } else {
                cycles[index].samples.append(sample)
            }
            if restored {
                cycles[index].endedAt = at
            } else { return }
        }
        // A mid-window start records only future deltas, never prior usage.
        var cycle = Cycle(bucketID: bucketID, minutes: minutes, startedAt: at)
        cycle.initialUsedPercent = used
        cycle.hasUsage = used > 0.001
        cycle.breakdown = Breakdown()
        cycle.lastReset = reset
        cycle.samples = [.init(capturedAt: at, usedPercent: used, tokens: 0, breakdown: Breakdown())]
        cycles.append(cycle)
    }

    mutating func addTokens(_ delta: Int64, input: Int64? = nil, output: Int64? = nil, missingSince: Double? = nil, at: Double = Date().timeIntervalSince1970) {
        guard delta > 0, at.isFinite else { return }
        for index in cycles.indices where cycles[index].endedAt == nil && cycles[index].bucketID == activeBucketID && at >= cycles[index].startedAt {
            let sum = cycles[index].tokens.addingReportingOverflow(delta)
            guard !sum.overflow else { cycles[index].recordGap(.tokenOverflow); continue }
            cycles[index].tokens = sum.partialValue
            if let input, let output, input >= 0, output >= 0,
               input <= delta, output == delta - input {
                var breakdown = cycles[index].breakdown ?? Breakdown()
                // Classified totals cannot exceed the checked total above.
                breakdown.input += input
                breakdown.output += output
                cycles[index].breakdown = breakdown
            }
            // Tokens alone cannot establish that account quota left 100% (e.g. credits).
            if let missingSince, missingSince >= cycles[index].startedAt, missingSince <= at {
                cycles[index].recordGap(.unrecordedTokenDelta)
            }
        }
    }
}
