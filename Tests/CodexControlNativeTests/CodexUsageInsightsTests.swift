import XCTest
@testable import CloudCodex

final class CodexUsageInsightsTests: XCTestCase {
    func testParsesOfficialAccountUsageShape() throws {
        let value = CodexUsageInsights.parse(
            account: ["account": ["type": "chatgpt", "email": "tester@example.com", "planType": "pro"]],
            usage: [
                "summary": [
                    "lifetimeTokens": 6_890_000_000 as Int64,
                    "peakDailyTokens": 590_000_000 as Int64,
                    "longestRunningTurnSec": 11_520,
                    "currentStreakDays": 25,
                    "longestStreakDays": 31
                ],
                "dailyUsageBuckets": [
                    ["startDate": "2026-09-16", "tokens": 1200],
                    ["startDate": "2026-09-15", "tokens": 800]
                ]
            ]
        )

        XCTAssertEqual(value.identity.email, "tester@example.com")
        XCTAssertEqual(value.identity.displayName, "tester")
        XCTAssertEqual(value.identity.planDisplayName, "Pro")
        XCTAssertEqual(value.summary.lifetimeTokens, 6_890_000_000)
        XCTAssertEqual(value.summary.longestRunningTurnSeconds, 11_520)
        XCTAssertEqual(value.dailyBuckets.map(\.tokens), [800, 1200])
    }

    func testMissingUsageFieldsStayUnknown() {
        let value = CodexUsageInsights.parse(account: [:], usage: ["summary": [:]])

        XCTAssertEqual(value.identity.displayName, "Codex 用户")
        XCTAssertNil(value.summary.lifetimeTokens)
        XCTAssertTrue(value.dailyBuckets.isEmpty)
        XCTAssertEqual(CodexUsageInsights.compactTokenCount(nil), "未提供")
        XCTAssertEqual(CodexUsageInsights.duration(nil), "未提供")
    }

    func testFormatsLargeTokenCountsAndDurations() {
        XCTAssertEqual(CodexUsageInsights.compactTokenCount(6_890_000_000), "68.9亿")
        XCTAssertEqual(CodexUsageInsights.compactTokenCount(59_000), "5.9万")
        XCTAssertEqual(CodexUsageInsights.duration(11_520), "3 小时 12 分")
    }
}
