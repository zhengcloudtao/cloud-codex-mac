import Foundation

/// Short-lived telemetry transport. Never loads, resumes, or starts a thread.
/// A slow conversation RPC must not queue the quota measurement behind it.
@MainActor
final class WeeklyQuotaProbe {
    private let makeClient: () -> AppServerClient
    private var activeClient: AppServerClient?

    init(makeClient: (() -> AppServerClient)? = nil) {
        self.makeClient = makeClient ?? { AppServerClient() }
    }

    func read(localTokenMode: Bool = false, knownLifetimeTokens: Int64 = 0) async throws -> WeeklyQuotaComparison.Snapshot {
        let client = makeClient()
        activeClient = client
        defer {
            client.shutdown()
            if activeClient === client { activeClient = nil }
        }
        try await client.start(initializationTimeoutSeconds: 30)
        try Task.checkCancellation()
        if localTokenMode { return try await client.readWeeklyQuotaForLocalUsage(knownLifetimeTokens: knownLifetimeTokens) }
        return try await client.readWeeklyQuotaSnapshot()
    }

    func cancel() {
        activeClient?.shutdown()
        activeClient = nil
    }
}
