import XCTest
@testable import CloudCodex

final class AutomaticWeeklyQuotaSamplerTests: XCTestCase {
    private func snapshot(identity: String = "private-account@example.invalid", plan: String = "Plus",
                          used: Double = 10, reset: Double = 10000, tokens: Int64 = 1000,
                          time: Double = 100, balance: Decimal = 10) -> WeeklyQuotaComparison.Snapshot {
        .init(identity: identity, plan: plan, usedPercent: used, resetsAt: reset,
              lifetimeTokens: tokens, date: Date(timeIntervalSince1970: time), creditBalance: balance)
    }

    func testPersistedLegacyTierKeepsAutomaticSamplingBaseline() throws {
        var old = AutomaticWeeklyQuotaSampler()
        _ = old.record(snapshot(plan: "Pro 20×"))
        var restored = try JSONDecoder().decode(AutomaticWeeklyQuotaSampler.self, from: JSONEncoder().encode(old))
        _ = restored.record(snapshot(plan: "Pro 200", used: 15, tokens: 1500, time: 160))
        let sample = try XCTUnwrap(restored.record(snapshot(plan: "Pro 200", used: 15, tokens: 1500, time: 220)))
        XCTAssertEqual(sample.plan, "Pro 200")
        XCTAssertEqual(sample.tokens, 500)
        XCTAssertEqual(sample.percent, 5)
    }

    func testStartsWithoutManualActionAndWaitsForStableSignificantConsumption() throws {
        var sampler = AutomaticWeeklyQuotaSampler()
        XCTAssertNil(sampler.record(snapshot()))
        XCTAssertEqual(sampler.phase, .baseline)
        XCTAssertNil(sampler.record(snapshot(used: 14, tokens: 1400, time: 160)))
        XCTAssertEqual(sampler.phase, .collecting)
        XCTAssertNotNil(sampler.record(snapshot(used: 15, tokens: 1500, time: 220)))
        XCTAssertEqual(sampler.phase, .ready)
        let sample = try XCTUnwrap(sampler.record(snapshot(used: 15, tokens: 1500, time: 280)))
        XCTAssertEqual(sample.percent, 5)
        XCTAssertEqual(sample.tokens, 500)
        XCTAssertEqual(sample.weeklyTokens, 10000)
        XCTAssertEqual(sample.automatic, true)
        XCTAssertNil(sample.dollars)
        XCTAssertEqual(sampler.phase, .ready)
    }

    func testContinuedConsumptionUpdatesSameSegmentInsteadOfDuplicatingRows() throws {
        var sampler = AutomaticWeeklyQuotaSampler()
        _ = sampler.record(snapshot())
        _ = sampler.record(snapshot(used: 15, tokens: 1500, time: 160))
        let first = try XCTUnwrap(sampler.record(snapshot(used: 15, tokens: 1500, time: 220)))
        _ = sampler.record(snapshot(used: 20, tokens: 2400, time: 280))
        let next = try XCTUnwrap(sampler.record(snapshot(used: 20, tokens: 2400, time: 340)))
        XCTAssertEqual(first.id, next.id)
        XCTAssertEqual(next.percent, 10)
        XCTAssertEqual(next.tokens, 1400)
        XCTAssertEqual(next.weeklyTokens, 14000)
    }

    func testLaggingQuotaOrTokenUpdatesWaitInsteadOfCreatingEarlyEstimates() {
        var sampler = AutomaticWeeklyQuotaSampler()
        _ = sampler.record(snapshot())
        XCTAssertNil(sampler.record(snapshot(used: 20, tokens: 1000, time: 160)))
        XCTAssertNotNil(sampler.record(snapshot(used: 20, tokens: 2000, time: 220)))
        XCTAssertEqual(sampler.phase, .ready)
        XCTAssertNotNil(sampler.record(snapshot(used: 20, tokens: 2000, time: 280)))
    }

    func testLocalModelCostsAreExtrapolatedAndPartialPricesDoNotPretendToBeComplete() throws {
        var sampler = AutomaticWeeklyQuotaSampler()
        _ = sampler.record(snapshot())
        let tokens = CodexAPIUsagePricing.Tokens(input: 100_000, cached: 60_000, cacheWrite: 0, output: 10_000)
        var report = CodexAPIUsagePricing.Report()
        report.add(CodexAPIUsagePricing.line(model: "gpt-6.1-sol", tier: "default", tokens: tokens, observedTokens: 110_000))
        var current = snapshot(used: 16, time: 220)
        current.accountTokensAvailable = false
        let sample = try XCTUnwrap(sampler.record(current, localTokens: 110_000, costReport: report))
        XCTAssertEqual(try XCTUnwrap(sample.weeklyDollars), 3.1, accuracy: 1e-12)
        XCTAssertEqual(sample.costReport, report)
        report.add(CodexAPIUsagePricing.line(model: "unknown", tier: nil, tokens: nil, observedTokens: 1000))
        var later = snapshot(used: 17, time: 280)
        later.accountTokensAvailable = false
        let partial = try XCTUnwrap(sampler.record(later, localTokens: 111_000, costReport: report))
        XCTAssertNil(partial.dollars)
        XCTAssertEqual(partial.costReport?.knownDollars, report.knownDollars)
        XCTAssertEqual(sample.id, partial.id)
    }

    func testSixPercentWithFrozenAccountCounterUsesLocalLogsImmediately() throws {
        var sampler = AutomaticWeeklyQuotaSampler()
        _ = sampler.record(snapshot())
        var current = snapshot(used: 16, tokens: 1000, time: 220)
        current.accountTokensAvailable = false
        let sample = try XCTUnwrap(sampler.record(current, localTokens: 600_000))
        XCTAssertEqual(sample.weeklyTokens, 10_000_000)
        XCTAssertEqual(sample.tokenSource, .localLogs)
        XCTAssertEqual(sampler.phase, .ready)
        XCTAssertEqual(sampler.observedLocalTokens, 600_000)
    }

    func testContinuedUsageDoesNotRequireIdleCountersAndKeepsLocalBasis() throws {
        var sampler = AutomaticWeeklyQuotaSampler()
        _ = sampler.record(snapshot())
        let first = try XCTUnwrap(sampler.record(snapshot(used: 16, time: 220), localTokens: 600))
        let next = try XCTUnwrap(sampler.record(snapshot(used: 17, tokens: 9999, time: 280), localTokens: 700))
        XCTAssertEqual(next.id, first.id)
        XCTAssertEqual(next.tokens, 700)
        XCTAssertEqual(next.tokenSource, .localLogs)
    }

    func testQuotaThresholdMetWithoutAnyObservedTokensExplainsActualBlocker() {
        var sampler = AutomaticWeeklyQuotaSampler()
        _ = sampler.record(snapshot())
        XCTAssertNil(sampler.record(snapshot(used: 16, time: 220), localTokens: 0))
        XCTAssertTrue(sampler.status.contains("额度消耗已达标"))
        XCTAssertTrue(sampler.status.contains("Token"))
    }

    func testAccountPlanResetRestorationCreditSpendAndLongGapStartNewSegments() {
        let changed = [
            snapshot(identity: "different-account", used: 20, tokens: 2000, time: 220),
            snapshot(plan: "Pro", used: 20, tokens: 2000, time: 220),
            snapshot(used: 20, reset: 20000, tokens: 2000, time: 220),
            snapshot(used: 9, tokens: 2000, time: 220),
            snapshot(used: 20, tokens: 900, time: 220),
            snapshot(used: 20, tokens: 2000, time: 220, balance: 9),
            snapshot(used: 20, tokens: 2000, time: 1200)
        ]
        for end in changed {
            var sampler = AutomaticWeeklyQuotaSampler()
            _ = sampler.record(snapshot())
            let oldID = sampler.sampleID
            XCTAssertNil(sampler.record(end))
            XCTAssertEqual(sampler.phase, .baseline)
            XCTAssertEqual(sampler.baseline?.lifetimeTokens, end.lifetimeTokens)
            XCTAssertNotEqual(sampler.sampleID, oldID)
        }
    }

    func testExhaustionAndUnavailableDataInvalidateBaseline() {
        var sampler = AutomaticWeeklyQuotaSampler()
        _ = sampler.record(snapshot())
        XCTAssertNil(sampler.record(snapshot(used: 100, tokens: 2000, time: 160)))
        XCTAssertEqual(sampler.phase, .unavailable)
        XCTAssertNil(sampler.baseline)
        _ = sampler.record(snapshot(time: 220))
        sampler.invalidate()
        XCTAssertNil(sampler.latest)
        XCTAssertNil(sampler.baseline)
    }

    func testStaleReadCannotRollBackLatestObservation() {
        var sampler = AutomaticWeeklyQuotaSampler()
        _ = sampler.record(snapshot(time: 220))
        let expected = sampler
        XCTAssertNil(sampler.record(snapshot(used: 20, tokens: 2000, time: 160)))
        XCTAssertEqual(sampler, expected)
    }

    func testTransientFailureKeepsBaselineAndContinuesSameMeasurement() throws {
        for issue: WeeklyQuotaComparison.ReadIssue in [.timeout, .usageTimeout, .quotaTimeout, .startupTimeout, .quotaChanging, .quotaMissing, .tokensMissing, .response] {
            var sampler = AutomaticWeeklyQuotaSampler()
            _ = sampler.record(snapshot())
            let id = sampler.sampleID
            sampler.readingFailed(issue, at: Date(timeIntervalSince1970: 160))
            XCTAssertNotNil(sampler.baseline)
            XCTAssertEqual(sampler.sampleID, id)
            XCTAssertEqual(sampler.phase, .retrying)
            XCTAssertEqual(sampler.lastIssue, issue)
            _ = sampler.record(snapshot(used: 20, tokens: 2000, time: 220))
            let sample = try XCTUnwrap(sampler.record(snapshot(used: 20, tokens: 2000, time: 280)))
            XCTAssertEqual(sample.id, id)
            XCTAssertEqual(sample.tokens, 1000)
            XCTAssertNil(sampler.lastIssue)
        }
    }

    func testConfirmedBoundaryFailureClearsBaselineAndExplainsReason() {
        for issue: WeeklyQuotaComparison.ReadIssue in [.accountChanged, .planChanged, .quotaExhausted, .resetExpired, .authentication] {
            var sampler = AutomaticWeeklyQuotaSampler()
            _ = sampler.record(snapshot())
            sampler.readingFailed(issue)
            XCTAssertNil(sampler.baseline)
            XCTAssertEqual(sampler.phase, .unavailable)
            XCTAssertEqual(sampler.lastIssue, issue)
            XCTAssertTrue(sampler.status.contains(issue.errorDescription!))
        }
    }

    func testUnavailableFirstReadingExplainsWaitingRatherThanDisconnection() {
        var sampler = AutomaticWeeklyQuotaSampler()
        sampler.readingFailed(.quotaChanging)
        XCTAssertTrue(sampler.status.contains("等待首次有效读数"))
        XCTAssertFalse(sampler.status.contains("断开"))
        sampler.reset()
        XCTAssertEqual(sampler.phase, .waiting)
        XCTAssertNil(sampler.lastIssue)
    }

    func testRestartRestoresCountersAndSegmentWithoutPersistingRawIdentity() throws {
        let suite = "AutomaticWeeklyQuotaSamplerTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var sampler = AutomaticWeeklyQuotaSampler()
        _ = sampler.record(snapshot())
        _ = sampler.record(snapshot(used: 20, tokens: 2000, time: 160))
        let data = try JSONEncoder().encode(sampler)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-account@example.invalid"))
        defaults.set(data, forKey: AutomaticWeeklyQuotaSampler.defaultsKey)
        var restored = AutomaticWeeklyQuotaSampler.load(defaults)
        XCTAssertEqual(restored, sampler)
        let sample = try XCTUnwrap(restored.record(snapshot(used: 20, tokens: 2000, time: 220)))
        XCTAssertEqual(sample.id, sampler.sampleID)
        XCTAssertEqual(sample.weeklyTokens, 10000)
    }

    @MainActor
    func testDisabledSamplingAndSavedHistoryRestoreWithoutStartingClient() async throws {
        let suite = "AutomaticWeeklyQuotaModelTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: AutomaticWeeklyQuotaSampler.enabledKey)
        let sample = try WeeklyQuotaComparison.Sample.make(plan: "Previous plan", percent: 10,
            tokens: 100, dollars: nil, monthlyPrice: nil)
        defaults.set(try JSONEncoder().encode(WeeklyQuotaComparison(samples: [sample])),
                     forKey: WeeklyQuotaComparison.defaultsKey)
        let model = AppModel(remoteDefaults: defaults)
        XCTAssertFalse(model.automaticWeeklyQuotaEnabled)
        XCTAssertEqual(model.weeklyQuotaComparison.samples, [sample])
        await model.sampleWeeklyQuotaAutomatically()
        XCTAssertFalse(model.isSamplingWeeklyQuota)
        model.setAutomaticWeeklyQuotaEnabled(true)
        XCTAssertTrue(defaults.bool(forKey: AutomaticWeeklyQuotaSampler.enabledKey))
        model.setAutomaticWeeklyQuotaEnabled(false)
        XCTAssertEqual(model.weeklyQuotaComparison.samples, [sample])
    }

    @MainActor
    func testOptionalLiveReadOnlySnapshot() async throws {
        guard ProcessInfo.processInfo.environment["CLOUDCODEX_AUTO_QUOTA_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in read-only automatic quota snapshot check")
        }
        let probe = WeeklyQuotaProbe()
        var sampler = AutomaticWeeklyQuotaSampler()
        let attempts = ProcessInfo.processInfo.environment["CLOUDCODEX_AUTO_QUOTA_DIAGNOSTIC"] == "1" ? 3 : 1
        var successful = 0
        for _ in 0..<attempts {
            do {
                let snapshot = try await probe.read(localTokenMode: true)
                XCTAssertGreaterThan(snapshot.resetsAt, snapshot.date.timeIntervalSince1970)
                XCTAssertGreaterThanOrEqual(snapshot.lifetimeTokens, 0)
                _ = sampler.record(snapshot)
                successful += 1
                print("quota-snapshot: success")
            } catch {
                let issue = WeeklyQuotaComparison.ReadIssue.classify(error)
                print("quota-snapshot: \(issue.rawValue)")
                sampler.readingFailed(issue)
            }
        }
        XCTAssertGreaterThan(successful, 0, "No usable read-only quota snapshot")
        // No account identity, token totals, or balances are logged.
    }
}
