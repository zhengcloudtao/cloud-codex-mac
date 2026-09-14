import Foundation

/// Keeps only sanitized weekly-quota percentages. No account identifier or
/// credential is persisted with the local consumption history.
struct QuotaConsumptionTracker: Codable, Equatable {
    struct Sample: Codable, Equatable {
        let capturedAt: Double
        let usedPercent: Double
        let resetsAt: Double
    }

    private(set) var samples: [Sample] = []

    mutating func record(account: AccountOverview) -> Double? {
        guard let window = account.weeklyUsageWindow,
              let usedPercent = window.usedPercent,
              let resetsAt = window.resetsAt,
              usedPercent.isFinite,
              resetsAt.isFinite else {
            return nil
        }

        let capturedAt = account.usage.capturedAt
        guard capturedAt.isFinite else { return nil }
        let current = Sample(
            capturedAt: capturedAt,
            usedPercent: max(0, min(100, usedPercent)),
            resetsAt: resetsAt
        )

        // A different reset boundary, or a falling used-percent value within
        // one boundary, means quota was restored. It starts a new measurement
        // period instead of appearing as negative consumption.
        if let last = samples.last,
           abs(last.resetsAt - current.resetsAt) > 1
            || current.usedPercent + 0.001 < last.usedPercent {
            samples = []
        }

        if let last = samples.last, abs(last.capturedAt - current.capturedAt) < 0.001 {
            samples[samples.count - 1] = current
        } else if samples.last.map({ current.capturedAt > $0.capturedAt }) ?? true {
            samples.append(current)
        }

        let retentionStart = current.capturedAt - 2 * 60 * 60
        samples.removeAll {
            $0.capturedAt < retentionStart
                || abs($0.resetsAt - current.resetsAt) > 1
        }
        return consumptionRate(at: current.capturedAt)
    }

    func consumptionRate(at now: Double) -> Double? {
        guard let current = samples.last,
              abs(current.capturedAt - now) < 5 * 60 else { return nil }
        let target = now - 30 * 60
        guard let lower = samples.last(where: { $0.capturedAt <= target }) else {
            return nil
        }

        let upper = samples.first(where: { $0.capturedAt >= target }) ?? lower
        let baseline: Double
        if upper.capturedAt > lower.capturedAt {
            let fraction = (target - lower.capturedAt) / (upper.capturedAt - lower.capturedAt)
            baseline = lower.usedPercent + (upper.usedPercent - lower.usedPercent) * fraction
        } else {
            baseline = lower.usedPercent
        }
        return max(0, min(100, current.usedPercent - baseline))
    }
}
