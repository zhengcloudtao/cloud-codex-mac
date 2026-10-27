import XCTest
@testable import CloudCodex

final class QuotaCycleHistoryTests: XCTestCase {
    func testFullToFullPreservesTokensAndPercentageAndStartsNextCycle() {
        var history = QuotaCycleHistory()
        history.record(bucketID: "codex", minutes: 300, used: 0, at: 1, resetsAt: 100)
        history.record(bucketID: "codex", minutes: 300, used: 0, at: 2, resetsAt: 100)
        XCTAssertEqual(history.cycles.count, 1)
        history.addTokens(120, at: 3)
        history.record(bucketID: "codex", minutes: 300, used: 25, at: 4, resetsAt: 100)
        history.addTokens(80, at: 5)
        history.record(bucketID: "codex", minutes: 300, used: 60, at: 6, resetsAt: 100)
        history.record(bucketID: "codex", minutes: 300, used: 0, at: 101, resetsAt: 200)
        XCTAssertEqual(history.cycles.count, 2)
        XCTAssertEqual(history.cycles[0].tokens, 200)
        XCTAssertEqual(history.cycles[0].consumedPercent, 60)
        XCTAssertEqual(history.cycles[0].endedAt, 101)
        XCTAssertEqual(history.cycles[0].samples.last?.tokens, 200)
        XCTAssertEqual(history.cycles[1].tokens, 0)
        XCTAssertFalse(history.cycles[0].hasObservationGap)
    }

    func testWaitsForFullAndRejectsStaleAndInvalidSamples() {
        var history = QuotaCycleHistory()
        history.record(bucketID: "codex", minutes: 300, used: 20, at: 1, resetsAt: 100)
        history.addTokens(100, at: 2)
        XCTAssertTrue(history.cycles.isEmpty)
        history.record(bucketID: "codex", minutes: 300, used: 0, at: 3, resetsAt: 100)
        history.record(bucketID: "codex", minutes: 300, used: 30, at: 2, resetsAt: 100)
        history.record(bucketID: "codex", minutes: 300, used: .nan, at: 4, resetsAt: 100)
        XCTAssertEqual(history.cycles[0].samples.count, 1)
        XCTAssertEqual(history.cycles[0].tokens, 0)
    }

    func testWindowsIndependentAndPartialRecoveryDoesNotEndCycle() throws {
        var history = QuotaCycleHistory()
        for minutes in [300, 10_080] {
            history.record(bucketID: "codex", minutes: minutes, used: 0, at: 1, resetsAt: 100)
            history.record(bucketID: "codex", minutes: minutes, used: 40, at: 2, resetsAt: 100)
        }
        history.addTokens(50, at: 3)
        history.record(bucketID: "codex", minutes: 300, used: 20, at: 4, resetsAt: 100)
        history.record(bucketID: "codex", minutes: 300, used: 30, at: 5, resetsAt: 100)
        history = try JSONDecoder().decode(QuotaCycleHistory.self, from: JSONEncoder().encode(history))
        history.record(bucketID: "codex", minutes: 300, used: 0, at: 6, resetsAt: 200)
        history.addTokens(10, missingSince: 1, at: 7)
        XCTAssertEqual(history.cycles[0].consumedPercent, 50)
        XCTAssertEqual(history.cycles[0].tokens, 50)
        XCTAssertFalse(history.cycles[0].hasObservationGap)
        XCTAssertNil(history.cycles[1].endedAt)
        XCTAssertEqual(history.cycles[1].tokens, 60)
        XCTAssertEqual(history.cycles[2].tokens, 10)
    }

    func testPersistenceDoesNotInventGapAndDoesNotLeakBetweenAccounts() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defer { defaults.removeObject(forKey: QuotaCycleHistory.defaultsKey) }
        var history = QuotaCycleHistory()
        history.record(bucketID: "codex", minutes: 300, used: 0, at: 1, resetsAt: 100)
        history.addTokens(40, at: 2)
        defaults.set(try JSONEncoder().encode(history), forKey: QuotaCycleHistory.defaultsKey)
        let loaded = QuotaCycleHistory.load(defaults)
        XCTAssertEqual(loaded.cycles[0].tokens, 40)
        XCTAssertFalse(loaded.cycles[0].hasObservationGap)
        defaults.removeObject(forKey: QuotaCycleHistory.defaultsKey)
        XCTAssertTrue(QuotaCycleHistory.load(defaults).cycles.isEmpty)
    }
    @MainActor
    func testAppModelPersistsLiveTokensWithoutDoubleCounting() throws {
        let suite = "quota-cycle-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var history = QuotaCycleHistory()
        history.record(bucketID: "codex", minutes: 300, used: 0, at: 1, resetsAt: 100)
        defaults.set(try JSONEncoder().encode(history), forKey: QuotaCycleHistory.defaultsKey)
        let app = AppModel(remoteDefaults: defaults)
        let usage: [String: Any] = ["inputTokens": 10, "outputTokens": 2, "totalTokens": 12,
                                   "cachedInputTokens": 0, "reasoningOutputTokens": 0]
        let params: [String: Any] = ["threadId": "t", "turnId": "a", "tokenUsage": ["last": usage, "total": usage]]
        app.handleEvent("thread/tokenUsage/updated", params)
        app.handleEvent("thread/tokenUsage/updated", params)
        XCTAssertEqual(app.quotaCycleHistory.cycles[0].tokens, 12)
        XCTAssertEqual(QuotaCycleHistory.load(defaults).cycles[0].tokens, 12)
    }

    func testBucketChangesDoNotChargeInactiveBucket() {
        var history = QuotaCycleHistory()
        history.record(bucketID: "a", minutes: 300, used: 0, at: 1, resetsAt: 100)
        history.record(bucketID: "b", minutes: 300, used: 0, at: 2, resetsAt: 100)
        history.addTokens(25, at: 3)
        XCTAssertEqual(history.cycles[0].tokens, 0)
        XCTAssertEqual(history.cycles[1].tokens, 25)
    }

    func testIdleSamplesCoalesceButUsageChangesRemain() {
        var history = QuotaCycleHistory()
        for time in 1...20 {
            history.record(bucketID: "codex", minutes: 300, used: 0, at: Double(time), resetsAt: 100)
        }
        XCTAssertEqual(history.cycles[0].samples.count, 1)
        XCTAssertEqual(history.cycles[0].startedAt, 1)
        XCTAssertEqual(history.cycles[0].samples[0].capturedAt, 20)
        history.record(bucketID: "codex", minutes: 300, used: 50, at: 19, resetsAt: 100)
        XCTAssertEqual(history.cycles[0].consumedPercent, 0)
        history.addTokens(10, at: 21)
        history.record(bucketID: "codex", minutes: 300, used: 0, at: 22, resetsAt: 100)
        history.record(bucketID: "codex", minutes: 300, used: 2, at: 23, resetsAt: 100)
        XCTAssertEqual(history.cycles[0].samples.count, 3)
        XCTAssertEqual(history.cycles[0].tokens, 10)
        XCTAssertEqual(history.cycles[0].consumedPercent, 2)
    }

    func testLoadCompactsAndPersistsExistingUnchangedSamples() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defer { defaults.removeObject(forKey: QuotaCycleHistory.defaultsKey) }
        var history = QuotaCycleHistory()
        history.record(bucketID: "codex", minutes: 300, used: 0, at: 1, resetsAt: 100)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as? [String: Any])
        var cycles = try XCTUnwrap(json["cycles"] as? [[String: Any]])
        cycles[0]["samples"] = [
            ["capturedAt": 1, "usedPercent": 0, "tokens": 0],
            ["capturedAt": 2, "usedPercent": 0, "tokens": 0],
            ["capturedAt": 3, "usedPercent": 2, "tokens": 100],
            ["capturedAt": 4, "usedPercent": 2, "tokens": 100]
        ]
        json["cycles"] = cycles
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: QuotaCycleHistory.defaultsKey)
        let loaded = QuotaCycleHistory.load(defaults)
        XCTAssertEqual(loaded.cycles[0].samples.map(\.capturedAt), [2, 4])
        XCTAssertEqual(loaded.cycles[0].samples.last?.tokens, 100)
        XCTAssertEqual(loaded.cycles[0].startedAt, 1)
        let persisted = try JSONDecoder().decode(QuotaCycleHistory.self, from: XCTUnwrap(defaults.data(forKey: QuotaCycleHistory.defaultsKey)))
        XCTAssertEqual(persisted, loaded)
    }

    func testAnyUnchangedUsageCoalescesButEitherChangeAndNonAdjacentRepeatRemain() {
        var history = QuotaCycleHistory()
        history.record(bucketID: "codex", minutes: 300, used: 0, at: 1, resetsAt: 100)
        history.addTokens(100, at: 2)
        for time in 3...10 {
            history.record(bucketID: "codex", minutes: 300, used: 25, at: Double(time), resetsAt: 100)
        }
        XCTAssertEqual(history.cycles[0].samples.count, 2)
        XCTAssertEqual(history.cycles[0].samples.last?.capturedAt, 10)
        history.addTokens(10, at: 11)
        history.record(bucketID: "codex", minutes: 300, used: 25, at: 12, resetsAt: 100)
        history.record(bucketID: "codex", minutes: 300, used: 30, at: 13, resetsAt: 100)
        history.record(bucketID: "codex", minutes: 300, used: 25, at: 14, resetsAt: 100)
        XCTAssertEqual(history.cycles[0].samples.map(\.capturedAt), [1, 10, 12, 13, 14])
        XCTAssertEqual(history.cycles[0].tokens, 110)
        XCTAssertEqual(history.cycles[0].consumedPercent, 30)
    }

    func testTotalTokenEstimateUsesObservedConsumptionAndHandlesMissingData() throws {
        var cycle = QuotaCycleHistory.Cycle(bucketID: "codex", minutes: 300, startedAt: 1)
        XCTAssertNil(cycle.estimatedTotalTokens)
        cycle.tokens = 1_811_924
        XCTAssertNil(cycle.estimatedTotalTokens)
        cycle.consumedPercent = 25
        XCTAssertEqual(try XCTUnwrap(cycle.estimatedTotalTokens), 7_247_696, accuracy: 0.001)
        cycle.recordGap(.unrecordedTokenDelta)
        XCTAssertEqual(try XCTUnwrap(cycle.estimatedTotalTokens), 7_247_696, accuracy: 0.001)
        cycle.consumedPercent = 50
        XCTAssertEqual(try XCTUnwrap(cycle.estimatedTotalTokens), 3_623_848, accuracy: 0.001)
        cycle.consumedPercent = .nan
        XCTAssertNil(cycle.estimatedTotalTokens)
        cycle.consumedPercent = .infinity
        XCTAssertNil(cycle.estimatedTotalTokens)
        cycle.consumedPercent = -1
        XCTAssertNil(cycle.estimatedTotalTokens)
        cycle.consumedPercent = 25
        cycle.tokens = 0
        XCTAssertNil(cycle.estimatedTotalTokens)
    }

    func testConfirmedGapsSurviveRestartButLegacyRestartFlagsAreCleared() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defer { defaults.removeObject(forKey: QuotaCycleHistory.defaultsKey) }
        var history = QuotaCycleHistory()
        history.record(bucketID: "codex", minutes: 300, used: 0, at: 1, resetsAt: 100)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as? [String: Any])
        var cycles = try XCTUnwrap(json["cycles"] as? [[String: Any]])
        cycles[0]["hasObservationGap"] = true
        cycles[0].removeValue(forKey: "gapReasons")
        json["cycles"] = cycles
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: QuotaCycleHistory.defaultsKey)
        history = QuotaCycleHistory.load(defaults)
        XCTAssertFalse(history.cycles[0].hasObservationGap)
        history.addTokens(20, missingSince: 1, at: 2)
        XCTAssertTrue(history.cycles[0].hasObservationGap)
        defaults.set(try JSONEncoder().encode(history), forKey: QuotaCycleHistory.defaultsKey)
        XCTAssertEqual(QuotaCycleHistory.load(defaults).cycles[0].gapReasons, [.unrecordedTokenDelta])
    }

    func testOnlyMissedResetBoundaryMarksGapNotIdleResetChanges() {
        var history = QuotaCycleHistory()
        history.record(bucketID: "codex", minutes: 300, used: 0, at: 1, resetsAt: 100)
        history.record(bucketID: "codex", minutes: 300, used: 0, at: 2, resetsAt: 200)
        XCTAssertFalse(history.cycles[0].hasObservationGap)
        history.record(bucketID: "codex", minutes: 300, used: 20, at: 3, resetsAt: 200)
        history.record(bucketID: "codex", minutes: 300, used: 10, at: 201, resetsAt: 300)
        XCTAssertEqual(history.cycles[0].gapReasons, [.missedReset])
    }

    @MainActor
    func testInheritedPartialFlagDoesNotMarkCycleButOmittedFreshDeltaDoes() throws {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var history = QuotaCycleHistory()
        history.record(bucketID: "codex", minutes: 300, used: 0, at: 1, resetsAt: 100)
        defaults.set(try JSONEncoder().encode(history), forKey: QuotaCycleHistory.defaultsKey)
        let app = AppModel(remoteDefaults: defaults)
        func event(_ turn: String, _ total: Int, _ last: Int) {
            func usage(_ n: Int) -> [String: Any] {
                ["inputTokens": n, "outputTokens": 0, "totalTokens": n,
                 "cachedInputTokens": 0, "reasoningOutputTokens": 0]
            }
            app.handleEvent("thread/tokenUsage/updated", ["threadId": "t", "turnId": turn,
                "tokenUsage": ["total": usage(total), "last": usage(last)]])
        }
        event("a", 1000, 10) // Inherited history, not a measured cycle gap.
        XCTAssertTrue(app.turnTokenUsage.record(thread: "t", turn: "a")!.partial)
        XCTAssertFalse(app.quotaCycleHistory.cycles[0].hasObservationGap)
        event("a", 1020, 20) // Sticky partial flag must not leak into this event.
        XCTAssertFalse(app.quotaCycleHistory.cycles[0].hasObservationGap)
        XCTAssertEqual(app.quotaCycleHistory.cycles[0].tokens, 30)
        event("b", 1100, 10) // Measured delta 80, but only 10 attributed.
        XCTAssertEqual(app.quotaCycleHistory.cycles[0].gapReasons, [.unrecordedTokenDelta])
    }

    func testLegacyPartialFlagClearedButConfirmedDeltaSurvives() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defer { defaults.removeObject(forKey: QuotaCycleHistory.defaultsKey) }
        var history = QuotaCycleHistory()
        history.record(bucketID: "codex", minutes: 300, used: 0, at: 10, resetsAt: 100)
        history.addTokens(10, missingSince: 1, at: 11)
        XCTAssertFalse(history.cycles[0].hasObservationGap)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(history)) as? [String: Any])
        var cycles = try XCTUnwrap(json["cycles"] as? [[String: Any]])
        cycles[0]["gapReasons"] = ["partialTokens"]
        json["cycles"] = cycles
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: QuotaCycleHistory.defaultsKey)
        history = QuotaCycleHistory.load(defaults)
        XCTAssertFalse(history.cycles[0].hasObservationGap)
        history.addTokens(10, missingSince: 11, at: 12)
        defaults.set(try JSONEncoder().encode(history), forKey: QuotaCycleHistory.defaultsKey)
        XCTAssertEqual(QuotaCycleHistory.load(defaults).cycles[0].gapReasons, [.unrecordedTokenDelta])
    }

}
