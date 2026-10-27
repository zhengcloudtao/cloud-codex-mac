import Foundation

extension CloudCodexWatchSnapshot {
    mutating func applyAccountMetrics(_ usage: RemoteUsageSnapshot?, now: Date = .now) {
        creditBalanceText = nil
        availableResetCount = nil
        weeklyPaceLabel = nil
        weeklyPaceState = nil
        guard let usage, usage.available else { return }
        if let balance = usage.creditBalance {
            let presentation = AccountOverview.CreditBalance(balance: balance.balance, unlimited: balance.unlimited)
            if balance.unlimited || presentation.decimalBalance != nil {
                creditBalanceText = presentation.displayValue
            }
        }
        availableResetCount = usage.resetCredits?.availableCount.map { max(0, $0) }
        let account = AccountOverview(plan: usage.plan ?? "", usage: usage, subscriptionPeriodEnd: nil)
        if let pace = account.weeklyPaceStatus(now: now) {
            weeklyPaceLabel = pace.label
            switch pace.state {
            case .ahead: weeklyPaceState = "ahead"
            case .behind: weeklyPaceState = "behind"
            case .onTrack: weeklyPaceState = "onTrack"
            }
        }
    }
}
