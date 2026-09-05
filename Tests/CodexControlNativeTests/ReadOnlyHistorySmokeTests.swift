import XCTest
@testable import CloudCodex

/// Opt-in integration check against an existing local task. Never resumes,
/// creates, sends to, stops or changes a task, and never logs task contents.
@MainActor
final class ReadOnlyHistorySmokeTests: XCTestCase {
    func testExistingTaskRestoresActivityPagesWithoutBlockingMainActor() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let cwd = env["CLOUDCODEX_SMOKE_CWD"], let title = env["CLOUDCODEX_SMOKE_TITLE"] else {
            throw XCTSkip("Set CLOUDCODEX_SMOKE_CWD and CLOUDCODEX_SMOKE_TITLE for the read-only integration check")
        }
        let client = AppServerClient()
        try await client.start()
        let page = try await client.listThreads(cwd: cwd)
        let thread = try XCTUnwrap(page.threads.first { $0.displayName == title })
        var largestTickGap: TimeInterval = 0
        var tickCount = 0
        let heartbeat = Task { @MainActor in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
                let now = Date()
                largestTickGap = max(largestTickGap, now.timeIntervalSince(last))
                last = now
                tickCount += 1
            }
        }
        defer { heartbeat.cancel() }
        let start = Date()
        _ = try await client.readThread(thread.id)
        var snapshot = try await client.readLatestThreadActivity(thread.id, knownThread: thread)
        for _ in 0..<5 where client.hasMoreActivityHistory(thread.id) && snapshot.turn?.isActive != true {
            snapshot = try await client.readLatestThreadActivity(thread.id, knownThread: thread)
        }
        XCTAssertTrue(snapshot.messages.contains { $0.activityKind == .reasoning })
        XCTAssertTrue(snapshot.messages.contains { $0.activityKind == .command || $0.activityKind == .tool })
        XCTAssertEqual(Set(snapshot.messages.map(\.id)).count, snapshot.messages.count)
        XCTAssertGreaterThan(tickCount, 0)
        XCTAssertLessThan(largestTickGap, 1, "Read-only history loading stalled the main actor")
        let reread = try await client.readLatestThreadActivity(thread.id, knownThread: thread)
        XCTAssertGreaterThanOrEqual(reread.messages.count, snapshot.messages.count)
        print("Read-only history: \(snapshot.messages.count) normalized items; \(String(format: "%.2f", Date().timeIntervalSince(start))) s; max main-actor tick gap \(String(format: "%.3f", largestTickGap)) s")
    }
}
