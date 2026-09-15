import XCTest
@testable import CloudCodex

final class AccountOverviewTests: XCTestCase {
    func testTokenRevokedErrorBecomesConciseReloginGuidance() {
        let raw = #"failed to fetch codex rate limits: GET https://chatgpt.com/backend-api/wham/usage failed: 401 Unauthorized; body={"error":{"message":"Encountered invalidated oauth token for user","code":"token_revoked"}}"#

        let issue = AccountOverviewRefreshIssue.parse(raw)

        XCTAssertEqual(issue.title, "Codex 登录已失效")
        XCTAssertEqual(issue.message, "当前显示的是上次获取的数据。请在 Codex 中重新登录，然后返回此处刷新。")
        XCTAssertFalse(issue.message.contains("https://"))
        XCTAssertFalse(issue.message.contains("token_revoked"))
    }

    func testNetworkAndUnknownErrorsUseShortFallbackMessages() {
        XCTAssertEqual(AccountOverviewRefreshIssue.parse("network connection timed out").title, "暂时无法刷新")
        XCTAssertEqual(AccountOverviewRefreshIssue.parse("unexpected backend response").title, "套餐信息刷新失败")
    }

    func testProTiersMatchOfficialClientNames() {
        XCTAssertEqual(AccountOverview.parse(["rateLimits": ["planType": "pro"]]).planDisplayName, "Pro 20×")
        XCTAssertEqual(AccountOverview.parse(["rateLimits": ["planType": "prolite"]]).planDisplayName, "Pro 5×")
        XCTAssertEqual(AccountOverview.parse(["rateLimits": ["planType": "unknown"]]).planDisplayName, "套餐未提供")
        XCTAssertEqual(AccountOverview.parse(["rateLimits": ["planType": "future-plan"]]).planDisplayName, "future-plan")
    }
    func testKeepsLocallyReadSubscriptionPeriodSeparateFromQuotaResets() {
        let periodEnd = Date(timeIntervalSince1970: 1_790_819_369)
        let account = AccountOverview.parse(
            ["rateLimits": ["planType": "pro", "primary": ["resetsAt": 1_800_000_000]]],
            subscriptionPeriodEnd: periodEnd
        )

        XCTAssertEqual(account.subscriptionPeriodEnd, periodEnd)
        XCTAssertNotEqual(account.subscriptionPeriodEnd?.timeIntervalSince1970, 1_800_000_000)
    }
    func testQuotaWindowsAreMatchedByDurationNotPosition() {
        let account = AccountOverview.parse([
            "rateLimitsByLimitId": ["codex": ["planType": "pro",
                "primary": ["usedPercent": 25, "windowDurationMins": 10_080, "resetsAt": 100],
                "secondary": ["usedPercent": 70, "windowDurationMins": 300, "resetsAt": 200]]],
            "rateLimitResetCredits": ["availableCount": 2, "credits": [
                ["id": "one", "status": "available", "expiresAt": 300],
                ["id": "two", "status": "available", "expiresAt": 400],
                ["id": "old", "status": "expired", "expiresAt": 1]
            ]]
        ])
        XCTAssertEqual(account.plan, "pro")
        XCTAssertEqual(account.remaining(minutes: 300), "30%")
        XCTAssertEqual(account.remaining(minutes: 10_080), "75%")
        XCTAssertEqual(account.compactRemaining(minutes: 300), "30%")
        XCTAssertEqual(account.compactRemaining(minutes: 10_080), "75%")
        XCTAssertEqual(account.compactResetCredits, "2 次")
        XCTAssertEqual(account.usage.resetCredits?.availableCount, 2)
        XCTAssertEqual(account.usage.resetCredits?.expirations, [300, 400])
    }
    func testMissingDataIsNotShownAsZeroOrUnlimited() {
        let account = AccountOverview.parse([:])
        XCTAssertEqual(account.plan, "未提供")
        XCTAssertEqual(account.remaining(minutes: 300), "未提供")
        XCTAssertNil(account.compactRemaining(minutes: 300))
        XCTAssertNil(account.compactRemaining(minutes: 10_080))
        XCTAssertNil(account.compactResetCredits)
        XCTAssertNil(account.usage.resetCredits?.availableCount)
    }

    func testCompactSummaryOnlyIncludesValuesCloudCodexRecognized() {
        let account = AccountOverview.parse([
            "rateLimitsByLimitId": ["codex": ["planType": "pro",
                "primary": ["usedPercent": 26, "windowDurationMins": 10_080]]],
            "rateLimitResetCredits": ["availableCount": 0]
        ])

        XCTAssertNil(account.compactRemaining(minutes: 300))
        XCTAssertEqual(account.compactRemaining(minutes: 10_080), "74%")
        XCTAssertEqual(account.compactResetCredits, "0 次")
    }

    func testWeeklyRecommendationUsesRemainingQuotaAndResetTime() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = AccountOverview.parse([
            "rateLimitsByLimitId": ["codex": ["planType": "pro",
                "primary": [
                    "usedPercent": 25,
                    "windowDurationMins": 10_080,
                    "resetsAt": Int(now.addingTimeInterval(3 * 24 * 60 * 60).timeIntervalSince1970)
                ]]]
        ])

        let recommendation = try XCTUnwrap(account.weeklyUsageRecommendation(now: now))
        XCTAssertEqual(recommendation.title, "24小时建议")
        XCTAssertEqual(recommendation.value, "25%")
        XCTAssertTrue(recommendation.detail.contains("当前剩余 75%"))
    }

    func testWeeklyRecommendationUsesAllRemainingQuotaWithinOneDay() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = AccountOverview.parse([
            "rateLimits": ["planType": "plus", "primary": [
                "usedPercent": 26,
                "windowDurationMins": 10_080,
                "resetsAt": Int(now.addingTimeInterval(12 * 60 * 60).timeIntervalSince1970)
            ]]
        ])

        let recommendation = try XCTUnwrap(account.weeklyUsageRecommendation(now: now))
        XCTAssertEqual(recommendation.title, "重置前建议")
        XCTAssertEqual(recommendation.value, "74%")
        XCTAssertTrue(recommendation.detail.contains("不足 24 小时"))
    }

    func testWeeklyRecommendationRoundsUpAndHidesUnknownOrExpiredWindows() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = AccountOverview.parse([
            "rateLimits": ["primary": [
                "usedPercent": 50,
                "windowDurationMins": 10_080,
                "resetsAt": Int(now.addingTimeInterval(7 * 24 * 60 * 60).timeIntervalSince1970)
            ]]
        ])
        XCTAssertEqual(try XCTUnwrap(account.weeklyUsageRecommendation(now: now)).value, "14.3%")

        let unknownReset = AccountOverview.parse([
            "rateLimits": ["primary": ["usedPercent": 50, "windowDurationMins": 10_080]]
        ])
        XCTAssertNil(unknownReset.weeklyUsageRecommendation(now: now))

        let expired = AccountOverview.parse([
            "rateLimits": ["primary": [
                "usedPercent": 50,
                "windowDurationMins": 10_080,
                "resetsAt": Int(now.addingTimeInterval(-1).timeIntervalSince1970)
            ]]
        ])
        XCTAssertNil(expired.weeklyUsageRecommendation(now: now))
    }

    func testWeeklyRecommendationKeepsFullWeekBaselineWhenUsageIsAhead() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = AccountOverview.parse([
            "rateLimits": ["primary": [
                "usedPercent": 55,
                "windowDurationMins": 10_080,
                "resetsAt": Int(now.addingTimeInterval((4 * 24 + 7.0 + 22.0 / 60.0) * 60 * 60).timeIntervalSince1970)
            ]]
        ])

        let recommendation = try XCTUnwrap(account.weeklyUsageRecommendation(now: now))
        XCTAssertEqual(recommendation.value, "14.3%")
        XCTAssertTrue(recommendation.detail.contains("基础保底速度为 14.3%/24小时"))
        XCTAssertTrue(recommendation.detail.contains("两者中更高"))
    }

    func testWeeklyRecommendationRaisesBaselineWhenResetCatchUpIsHigher() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let account = AccountOverview.parse([
            "rateLimits": ["primary": [
                "usedPercent": 40,
                "windowDurationMins": 10_080,
                "resetsAt": Int(now.addingTimeInterval(2 * 24 * 60 * 60).timeIntervalSince1970)
            ]]
        ])

        XCTAssertEqual(try XCTUnwrap(account.weeklyUsageRecommendation(now: now)).value, "30%")
    }

    func testWeeklyPaceShowsAheadBehindAndOnTrackFromElapsedWeek() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func account(used: Double) -> AccountOverview {
            AccountOverview.parse([
                "rateLimits": ["primary": [
                    "usedPercent": used,
                    "windowDurationMins": 10_080,
                    "resetsAt": Int(now.addingTimeInterval(4 * 24 * 60 * 60).timeIntervalSince1970)
                ]]
            ])
        }

        let ahead = try XCTUnwrap(account(used: 55).weeklyPaceStatus(now: now))
        XCTAssertEqual(ahead.state, .ahead)
        XCTAssertEqual(ahead.compactLabel, "超前")
        XCTAssertTrue(ahead.detail.contains("理想剩余约"))

        let behind = try XCTUnwrap(account(used: 20).weeklyPaceStatus(now: now))
        XCTAssertEqual(behind.state, .behind)
        XCTAssertEqual(behind.compactLabel, "追赶")

        let expectedUsed = 100 - 4.0 / 7.0 * 100
        XCTAssertEqual(try XCTUnwrap(account(used: expectedUsed).weeklyPaceStatus(now: now)).state, .onTrack)
    }

    func testThirtyMinuteConsumptionUsesWeeklyQuotaSamples() throws {
        var tracker = QuotaConsumptionTracker()
        let reset = 1_900_000_000.0
        func account(at time: Double, used: Double) -> AccountOverview {
            let window: [String: Any] = [
                "usedPercent": used,
                "windowDurationMins": 10_080,
                "resetsAt": reset
            ]
            let bucket: [String: Any] = ["primary": window]
            return AccountOverview.parse([
                "rateLimitsByLimitId": ["codex": bucket]
            ], subscriptionPeriodEnd: nil).replacingCapturedAtForTest(time)
        }

        XCTAssertNil(tracker.record(account: account(at: 1_800_000_000, used: 20)))
        XCTAssertNil(tracker.record(account: account(at: 1_800_000_900, used: 21)))
        let rate = try XCTUnwrap(tracker.record(account: account(at: 1_800_001_800, used: 23.5)))
        XCTAssertEqual(rate, 3.5, accuracy: 0.001)
        XCTAssertEqual(AccountOverview.consumptionRateLabel(rate), "3.5%/30分钟")
        XCTAssertEqual(AccountOverview.compactConsumptionRateLabel(rate), "3.5%")
    }

    func testThirtyMinuteConsumptionInterpolatesAndRestartsAfterQuotaRestore() throws {
        var tracker = QuotaConsumptionTracker()
        let reset = 1_900_000_000.0
        func account(at time: Double, used: Double) -> AccountOverview {
            let window: [String: Any] = [
                "usedPercent": used,
                "windowDurationMins": 10_080,
                "resetsAt": reset
            ]
            return AccountOverview.parse([
                "rateLimits": ["primary": window]
            ]).replacingCapturedAtForTest(time)
        }

        _ = tracker.record(account: account(at: 1_800_000_000, used: 10))
        _ = tracker.record(account: account(at: 1_800_000_120, used: 11))
        let interpolated = try XCTUnwrap(tracker.record(account: account(at: 1_800_001_860, used: 14)))
        XCTAssertEqual(interpolated, 3.5, accuracy: 0.001)

        XCTAssertNil(tracker.record(account: account(at: 1_800_001_920, used: 2)))
    }
}

private extension AccountOverview {
    func replacingCapturedAtForTest(_ capturedAt: Double) -> AccountOverview {
        AccountOverview(
            plan: plan,
            usage: RemoteUsageSnapshot(
                capturedAt: capturedAt,
                available: usage.available,
                buckets: usage.buckets,
                resetCredits: usage.resetCredits,
                plan: usage.plan,
                subscriptionPeriodEnd: usage.subscriptionPeriodEnd
            ),
            subscriptionPeriodEnd: subscriptionPeriodEnd
        )
    }
}
