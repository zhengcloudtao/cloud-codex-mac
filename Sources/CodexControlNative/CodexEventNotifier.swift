import Foundation

enum CodexEventNotification: Sendable {
    case quotaUpdated
    case conversationCompleted
}

/// Sends best-effort administrator notifications without making Codex refreshes
/// or completed turns depend on the notification service being reachable.
final class CodexEventNotifier: @unchecked Sendable {
    static let live = CodexEventNotifier()

    static let quotaUpdatedEndpoint = URL(
        string: "https://api.cloudslow.com/szpu/system/codexUpdateQuota"
    )!
    static let conversationCompletedEndpoint = URL(
        string: "https://api.cloudslow.com/szpu/system/codexConversationCompleted"
    )!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func notify(_ event: CodexEventNotification) async {
        let endpoint: URL
        switch event {
        case .quotaUpdated:
            endpoint = Self.quotaUpdatedEndpoint
        case .conversationCompleted:
            endpoint = Self.conversationCompletedEndpoint
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return
            }
        } catch {
            // Notifications are deliberately best-effort. A network failure
            // must not change quota state or a conversation's terminal state.
        }
    }

    /// The UI's 100% means remaining quota, while app-server reports usage.
    /// Match the five-hour session by duration rather than response ordering.
    static func shouldNotifyQuotaUpdated(
        previous: AccountOverview?,
        current: AccountOverview
    ) -> Bool {
        guard let previousUsed = sessionUsedPercent(in: previous),
              let currentUsed = sessionUsedPercent(in: current) else {
            return false
        }
        return previousUsed > 0.001 && currentUsed <= 0.001
    }

    private static func sessionUsedPercent(in account: AccountOverview?) -> Double? {
        let bucket = account?.usage.buckets.first(where: { $0.id == "codex" })
            ?? account?.usage.buckets.first
        return bucket?.windows.first(where: { $0.windowDurationMins == 300 })?.usedPercent
    }
}
