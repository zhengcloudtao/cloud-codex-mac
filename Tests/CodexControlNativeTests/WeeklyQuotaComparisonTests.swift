import XCTest
@testable import CloudCodex

final class WeeklyQuotaComparisonTests: XCTestCase {
    private func overview(used: Double = 10, reset: Double = 10000, plan: String = "prolite") -> AccountOverview {
        let window: [String: Any] = [
            "usedPercent": used, "windowDurationMins": 10080, "resetsAt": reset
        ]
        return .parse(["rateLimits": ["planType": plan, "primary": window]])
    }

    private var account: [String: Any] {
        ["account": ["type": "chatgpt", "email": "test@example.invalid", "planType": "pro"]]
    }

    func testFreshQuotaTierWinsOverCachedAccountTier() throws {
        let snapshot = try WeeklyQuotaComparison.parseSnapshot(startAccount: account, before: overview(),
            usage: ["summary": ["lifetimeTokens": 1000]], after: overview(), endAccount: account,
            now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(snapshot.plan, "Pro 100")
    }

    func testMovingQuotaIsIdentifiedAsTransientInsteadOfGenericFailure() {
        XCTAssertThrowsError(try WeeklyQuotaComparison.parseSnapshot(startAccount: account, before: overview(),
            usage: ["summary": ["lifetimeTokens": 1000]], after: overview(used: 11), endAccount: account,
            now: Date(timeIntervalSince1970: 100))) { error in
            XCTAssertEqual(error as? WeeklyQuotaComparison.ReadIssue, .quotaChanging)
            XCTAssertFalse(WeeklyQuotaComparison.ReadIssue.classify(error).requiresNewBaseline)
        }
    }

    func testUnusedRollingResetTimestampDoesNotPreventFirstSnapshot() throws {
        let snapshot = try WeeklyQuotaComparison.parseSnapshot(startAccount: account, before: overview(used: 0, reset: 10000),
            usage: ["summary": ["lifetimeTokens": 1000]], after: overview(used: 0, reset: 10008), endAccount: account,
            now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(snapshot.usedPercent, 0)
    }

    func testAccountChangeAndMissingTokensHaveSeparateReasons() {
        let changed: [String: Any] = ["account": ["type": "chatgpt", "email": "other@example.invalid"]]
        XCTAssertThrowsError(try WeeklyQuotaComparison.parseSnapshot(startAccount: account, before: overview(),
            usage: [:], after: overview(), endAccount: changed, now: Date(timeIntervalSince1970: 100))) {
            XCTAssertEqual($0 as? WeeklyQuotaComparison.ReadIssue, .accountChanged)
        }
        XCTAssertThrowsError(try WeeklyQuotaComparison.parseSnapshot(startAccount: account, before: overview(),
            usage: [:], after: overview(), endAccount: account, now: Date(timeIntervalSince1970: 100))) {
            XCTAssertEqual($0 as? WeeklyQuotaComparison.ReadIssue, .tokensMissing)
        }
        XCTAssertEqual(WeeklyQuotaComparison.ReadIssue.classify(CodexClientError.timeout("account/usage/read")), .usageTimeout)
    }

    func testExtrapolatesMeasuredConsumptionAndMonthlyValue() throws {
        let sample = try WeeklyQuotaComparison.Sample.make(plan: "Sample plan", percent: 10,
            tokens: 2_000_000, dollars: 3, monthlyPrice: 20)
        XCTAssertEqual(sample.weeklyTokens, 20_000_000)
        XCTAssertEqual(sample.weeklyDollars, 30)
        XCTAssertEqual(try XCTUnwrap(sample.tokensPerDollar), 4_348_125, accuracy: 0.01)
    }

    func testMissingCostsRemainUnknownAndMoneyOnlySampleWorks() throws {
        let tokens = try WeeklyQuotaComparison.Sample.make(plan: "Tokens", percent: 5,
            tokens: 100, dollars: nil, monthlyPrice: nil)
        XCTAssertNil(tokens.weeklyDollars)
        XCTAssertNil(tokens.tokensPerDollar)
        let money = try WeeklyQuotaComparison.Sample.make(plan: "Money", percent: 20,
            tokens: nil, dollars: 10, monthlyPrice: 30)
        XCTAssertNil(money.weeklyTokens)
        XCTAssertEqual(money.weeklyDollars, 50)
    }

    func testRejectsInvalidAndUnstableSmallSamples() {
        for percent in [0, -1, 0.99, 101, Double.nan, .infinity] {
            XCTAssertThrowsError(try WeeklyQuotaComparison.Sample.make(plan: "Plan", percent: percent,
                tokens: 100, dollars: nil, monthlyPrice: nil))
        }
        for tokens in [0, -1, Double.nan, .infinity, Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(try WeeklyQuotaComparison.Sample.make(plan: "Plan", percent: 1,
                tokens: tokens, dollars: nil, monthlyPrice: nil))
        }
        XCTAssertThrowsError(try WeeklyQuotaComparison.Sample.make(plan: " ", percent: 5,
            tokens: 1, dollars: nil, monthlyPrice: nil))
        XCTAssertThrowsError(try WeeklyQuotaComparison.Sample.make(plan: "Plan", percent: 5,
            tokens: nil, dollars: nil, monthlyPrice: nil))
    }

    private func snapshot(identity: String = "ephemeral-account", plan: String = "Plus", used: Double = 20,
                          reset: Double = 10000, tokens: Int64 = 1000, time: Double = 100,
                          balance: Decimal = 10) -> WeeklyQuotaComparison.Snapshot {
        .init(identity: identity, plan: plan, usedPercent: used, resetsAt: reset,
              lifetimeTokens: tokens, date: Date(timeIntervalSince1970: time), creditBalance: balance)
    }

    func testRenamedTierContinuesExistingBaseline() throws {
        let sample = try snapshot(plan: "Pro 5×").sample(to: snapshot(plan: "Pro 100", used: 30, tokens: 1500, time: 200))
        XCTAssertEqual(sample.plan, "Pro 100")
        XCTAssertEqual(sample.tokens, 500)
        XCTAssertThrowsError(try snapshot(plan: "Pro 5×").sample(to: snapshot(plan: "Pro 200", used: 30, tokens: 1500, time: 200)))
    }

    func testUsesTokenDifferenceRatherThanLifetimeTotal() throws {
        let sample = try snapshot().sample(to: snapshot(used: 30, tokens: 1500, time: 200))
        XCTAssertEqual(sample.tokens, 500)
        XCTAssertEqual(sample.percent, 10)
        XCTAssertEqual(sample.weeklyTokens, 5000)
    }

    func testRejectsAccountPlanResetRestorationExhaustionAndCreditSpending() {
        let invalid = [
            snapshot(identity: "other", used: 30, tokens: 1500, time: 200),
            snapshot(plan: "Pro", used: 30, tokens: 1500, time: 200),
            snapshot(used: 30, reset: 20000, tokens: 1500, time: 200),
            snapshot(used: 10, tokens: 1500, time: 200),
            snapshot(used: 100, tokens: 1500, time: 200),
            snapshot(used: 30, tokens: 900, time: 200),
            snapshot(used: 30, tokens: 1500, time: 200, balance: 9),
            snapshot(used: 30, tokens: 1500, time: 10001),
            snapshot(used: 30, tokens: 1500, time: 50)
        ]
        for end in invalid { XCTAssertThrowsError(try snapshot().sample(to: end)) }
    }

    func testRoundTripKeepsComparisonWithoutAccountIdentity() throws {
        let suite = "WeeklyQuotaComparisonTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let sample = try snapshot().sample(to: snapshot(used: 30, tokens: 1500, time: 200))
        let ledger = WeeklyQuotaComparison(samples: [sample])
        let data = try JSONEncoder().encode(ledger)
        defaults.set(data, forKey: WeeklyQuotaComparison.defaultsKey)
        XCTAssertEqual(WeeklyQuotaComparison.load(defaults), ledger)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("ephemeral-account"))
        defaults.set(Data("broken".utf8), forKey: WeeklyQuotaComparison.defaultsKey)
        XCTAssertTrue(WeeklyQuotaComparison.load(defaults).samples.isEmpty)
    }
}
