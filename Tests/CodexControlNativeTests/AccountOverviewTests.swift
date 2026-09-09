import XCTest
@testable import CloudCodex

final class AccountOverviewTests: XCTestCase {
    func testProTiersMatchOfficialClientNames() {
        XCTAssertEqual(AccountOverview.parse(["rateLimits": ["planType": "pro"]]).planDisplayName, "Pro 20×")
        XCTAssertEqual(AccountOverview.parse(["rateLimits": ["planType": "prolite"]]).planDisplayName, "Pro 5×")
        XCTAssertEqual(AccountOverview.parse(["rateLimits": ["planType": "unknown"]]).planDisplayName, "套餐未提供")
        XCTAssertEqual(AccountOverview.parse(["rateLimits": ["planType": "future-plan"]]).planDisplayName, "future-plan")
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
}
