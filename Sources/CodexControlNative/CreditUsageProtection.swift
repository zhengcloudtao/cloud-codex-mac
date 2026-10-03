import Foundation

struct CreditUsageBlocked: LocalizedError {
    let reason: CreditUsageProtection.Reason
    var errorDescription: String? { reason.message }
}

/// A client-side stop rule. Account snapshots cannot reserve credits or undo billing.
struct CreditUsageProtection {
    enum Reason: String {
        // usageUnavailable is retained only for migrating saved state and hiding legacy queue errors.
        case balanceDecreased, includedQuotaExhausted, usageUnavailable

        var message: String {
            switch self {
            case .balanceDecreased:
                return "检测到额外额度余额下降，已禁止继续发送，并正在暂停所有运行中的会话。"
            case .includedQuotaExhausted:
                return "套餐额度已用完，额外额度使用开关已关闭，已禁止继续发送，并正在暂停所有运行中的会话。"
            case .usageUnavailable:
                return "暂时无法确认套餐额度，为避免使用额外额度，已禁止继续发送，并正在暂停所有运行中的会话。"
            }
        }
    }

    var reason: Reason?
    private(set) var lastBalance: Decimal?

    mutating func observe(_ account: AccountOverview, allowsCredits: Bool) {
        let balance = account.creditBalance?.decimalBalance
        defer { if let balance { lastBalance = balance } }
        if allowsCredits { reason = nil; return }
        if let balance, let lastBalance, balance < lastBalance {
            reason = .balanceDecreased
        } else if reason == nil, account.usage.buckets.contains(where: { bucket in
            bucket.windows.contains { ($0.usedPercent ?? 0) >= 100 }
        }) {
            reason = .includedQuotaExhausted
        }
    }

    static func hasKnownIncludedQuota(_ account: AccountOverview) -> Bool {
        guard let primary = account.primaryBucket, !primary.windows.isEmpty else { return false }
        let windows = account.usage.buckets.flatMap(\.windows)
        return !windows.isEmpty && windows.allSatisfy {
            guard let used = $0.usedPercent else { return false }
            return used < 100
        }
    }

    mutating func reset() { reason = nil; lastBalance = nil }
}
