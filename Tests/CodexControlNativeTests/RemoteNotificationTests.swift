import XCTest
@testable import CloudCodex

@MainActor
final class RemoteNotificationTests: XCTestCase {
    func testOutboxPersistsDeduplicatesAndAcknowledges() throws {
        let suite = "RemoteNotificationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let body = RemoteNotificationEventBody(
            type: RemoteNotificationEventBody.conversationCompleted,
            eventId: "conversation:thread:turn",
            threadId: "thread",
            turnId: "turn"
        )

        let first = RemoteNotificationOutbox(defaults: defaults)
        first.enqueue(deviceID: "device", body: body)
        first.enqueue(deviceID: "device", body: body)
        XCTAssertEqual(first.pending(deviceID: "device").count, 1)

        let restored = RemoteNotificationOutbox(defaults: defaults)
        XCTAssertEqual(restored.pending(deviceID: "device")[body.eventId], body)
        restored.acknowledge(deviceID: "device", body: body)
        XCTAssertTrue(restored.pending(deviceID: "device").isEmpty)
    }

    func testFiveHourQuotaOnlyTriggersOnNonFullToFullTransition() {
        func overview(used: Double?, minutes: Int = 300, capturedAt: Double = 100) -> AccountOverview {
            .init(
                plan: "pro",
                usage: .init(
                    capturedAt: capturedAt,
                    available: true,
                    buckets: [.init(id: "codex", name: "Codex", windows: [
                        .init(usedPercent: used, windowDurationMins: minutes, resetsAt: nil)
                    ])],
                    resetCredits: nil
                ),
                subscriptionPeriodEnd: nil
            )
        }

        XCTAssertTrue(AppModel.didRestoreFiveHourQuota(from: overview(used: 42), to: overview(used: 0)))
        XCTAssertFalse(AppModel.didRestoreFiveHourQuota(from: nil, to: overview(used: 0)))
        XCTAssertFalse(AppModel.didRestoreFiveHourQuota(from: overview(used: 0), to: overview(used: 0)))
        XCTAssertFalse(AppModel.didRestoreFiveHourQuota(from: overview(used: 42, minutes: 10_080), to: overview(used: 0, minutes: 10_080)))
        XCTAssertFalse(AppModel.didRestoreFiveHourQuota(from: overview(used: nil), to: overview(used: 0)))
    }
}
