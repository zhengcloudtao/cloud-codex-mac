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
            turnId: "turn",
            threadTitle: "修复会话通知"
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

    func testLegacyNotificationWithoutTitleDecodes() throws {
        let data = Data(#"{"type":"conversation_completed","eventId":"conversation:thread:turn","threadId":"thread","turnId":"turn"}"#.utf8)
        let body = try JSONDecoder().decode(RemoteNotificationEventBody.self, from: data)
        XCTAssertNil(body.threadTitle)
        XCTAssertEqual(body.threadId, "thread")
    }

    func testFiveHourAndWeeklyQuotaTriggerOnNonFullToFullTransition() {
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

        XCTAssertTrue(QuotaRestorationTracker.didRestore(from: overview(used: 42), to: overview(used: 0)))
        XCTAssertFalse(QuotaRestorationTracker.didRestore(from: nil, to: overview(used: 0)))
        XCTAssertFalse(QuotaRestorationTracker.didRestore(from: overview(used: 0), to: overview(used: 0)))
        XCTAssertTrue(QuotaRestorationTracker.didRestore(from: overview(used: 42, minutes: 10_080), to: overview(used: 0, minutes: 10_080)))
        XCTAssertFalse(QuotaRestorationTracker.didRestore(from: overview(used: nil), to: overview(used: 0)))
    }
    func testQuotaRecoverySurvivesMissingReadingsAndDoesNotRepeat() {
        func overview(_ used: Double?, at time: Double, available: Bool = true, bucket: String = "codex") -> AccountOverview {
            .init(plan: "pro", usage: .init(capturedAt: time, available: available,
                buckets: [.init(id: bucket, name: bucket, windows: [
                    .init(usedPercent: used, windowDurationMins: 300, resetsAt: nil)
                ])], resetCredits: nil), subscriptionPeriodEnd: nil)
        }
        var tracker = QuotaRestorationTracker()
        XCTAssertFalse(tracker.record(overview(0, at: 1)), "startup must not notify")
        XCTAssertFalse(tracker.record(overview(42, at: 2)))
        XCTAssertFalse(tracker.record(overview(nil, at: 3)))
        XCTAssertFalse(tracker.record(overview(0, at: 4, available: false)))
        XCTAssertFalse(tracker.record(overview(.nan, at: 5)))
        XCTAssertTrue(tracker.record(overview(0, at: 6)), "missing readings must not hide recovery")
        XCTAssertFalse(tracker.record(overview(0, at: 7)), "full readings must not repeat")
        XCTAssertFalse(tracker.record(overview(42, at: 2)), "late readings must not rearm notification")
        XCTAssertFalse(tracker.record(overview(0, at: 8)))
        XCTAssertFalse(tracker.record(overview(10, at: 9)))
        XCTAssertTrue(tracker.record(overview(0, at: 10)), "the next real recovery must notify")
        XCTAssertFalse(tracker.record(overview(10, at: 11)))
        XCTAssertFalse(tracker.record(overview(0, at: 12, bucket: "other")), "different quota buckets must not be compared")
    }

    func testWeeklyOnlyAndMultipleWindowsKeepIndependentRecoveryState() {
        func overview(at time: Double, fiveHour: Double? = nil, weekly: Double?) -> AccountOverview {
            var windows: [RemoteUsageSnapshot.Window] = [
                .init(usedPercent: weekly, windowDurationMins: 10_080, resetsAt: nil)
            ]
            if let fiveHour {
                windows.append(.init(usedPercent: fiveHour, windowDurationMins: 300, resetsAt: nil))
            }
            return .init(plan: "pro", usage: .init(capturedAt: time, available: true,
                buckets: [.init(id: "codex", name: "Codex", windows: windows)], resetCredits: nil),
                subscriptionPeriodEnd: nil)
        }
        var weeklyOnly = QuotaRestorationTracker()
        XCTAssertFalse(weeklyOnly.record(overview(at: 1, weekly: 0)))
        XCTAssertFalse(weeklyOnly.record(overview(at: 2, weekly: 45)))
        XCTAssertFalse(weeklyOnly.record(overview(at: 3, weekly: nil)))
        XCTAssertTrue(weeklyOnly.record(overview(at: 4, weekly: 0)))
        XCTAssertFalse(weeklyOnly.record(overview(at: 5, weekly: 0)))

        var both = QuotaRestorationTracker()
        XCTAssertFalse(both.record(overview(at: 1, fiveHour: 20, weekly: 40)))
        XCTAssertFalse(both.record(overview(at: 2, fiveHour: 20, weekly: nil)))
        XCTAssertTrue(both.record(overview(at: 3, fiveHour: 20, weekly: 0)), "weekly recovery must notify while five-hour quota is not full")
        XCTAssertFalse(both.record(overview(at: 4, fiveHour: 20, weekly: 0)))
        XCTAssertTrue(both.record(overview(at: 5, fiveHour: 0, weekly: 0)))
        XCTAssertFalse(both.record(overview(at: 6, fiveHour: 0, weekly: 0)))
    }

}
