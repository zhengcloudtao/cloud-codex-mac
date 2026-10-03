import XCTest
@testable import CloudCodex

final class RemoteUsageTests: XCTestCase {
    @MainActor
    func testOptionalLiveReadOnlyQuotaProtocol() async throws {
        guard ProcessInfo.processInfo.environment["CLOUDCODEX_USAGE_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in read-only quota protocol check")
        }
        let client = AppServerClient()
        try await client.start()
        let snapshot = try await client.readRemoteUsage()
        XCTAssertTrue(snapshot.available)
        XCTAssertGreaterThan(snapshot.capturedAt, 0)
        _ = try JSONEncoder().encode(snapshot)
        print("Read-only account/rateLimits/read succeeded; sanitized snapshot encodes successfully")
    }

    func testBucketWindowsAreNotAssumedToBeFiveHoursAndWeek() throws {
        let response: [String: Any] = ["accountId": "do-not-forward", "rateLimitsByLimitId": [
            "codex": ["planType": "pro", "credits": ["balance": "62416.782067", "unlimited": false], "primary": ["usedPercent": 4, "windowDurationMins": 10080, "resetsAt": 1800000000]],
            "spark": ["limitName": "Spark", "primary": ["usedPercent": 0, "windowDurationMins": 300]]
        ], "rateLimitResetCredits": ["availableCount": 3, "credits": [
            ["id": "do-not-forward", "status": "available", "expiresAt": 1800000100],
            ["status": "available", "expiresAt": NSNull()], ["status": "redeemed", "expiresAt": 1800000000]
        ]]]
        let subscriptionPeriodEnd = Date(timeIntervalSince1970: 1_900_000_000)
        let snapshot = RemoteUsageSnapshot.parse(response, subscriptionPeriodEnd: subscriptionPeriodEnd)
        XCTAssertEqual(snapshot.buckets[0].windows[0].windowDurationMins, 10080)
        XCTAssertEqual(snapshot.buckets[0].windows[0].usedPercent, 4)
        XCTAssertEqual(snapshot.plan, "pro")
        XCTAssertEqual(snapshot.subscriptionPeriodEnd, 1_900_000_000)
        XCTAssertEqual(snapshot.creditBalance, .init(balance: "62416.782067", unlimited: false))
        XCTAssertEqual(snapshot.resetCredits?.availableCount, 3)
        XCTAssertEqual(snapshot.resetCredits?.expirations?.count, 2)
        XCTAssertEqual(snapshot.resetCredits?.expirations?.first!, 1800000100)
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("do-not-forward"))
        XCTAssertFalse(encoded.contains("accountId"))
        XCTAssertTrue(encoded.contains("\"plan\":\"pro\""))
        XCTAssertTrue(encoded.contains("\"subscriptionPeriodEnd\":1900000000"))
        XCTAssertTrue(encoded.contains("\"creditBalance\""))
    }

    func testUnknownIsDifferentFromZeroAndLegacyResponseIsSupported() {
        let unknown = RemoteUsageSnapshot.parse(["rateLimits": ["primary": ["usedPercent": NSNull()]]])
        XCTAssertNil(unknown.buckets[0].windows[0].usedPercent)
        XCTAssertNil(unknown.resetCredits)
        XCTAssertNil(unknown.subscriptionPeriodEnd)
        XCTAssertNil(unknown.creditBalance)
        let countOnly = RemoteUsageSnapshot.parse(["rateLimitResetCredits": ["availableCount": 0]])
        XCTAssertEqual(countOnly.resetCredits?.availableCount, 0)
        XCTAssertNil(countOnly.resetCredits?.expirations)
        XCTAssertFalse(RemoteUsageSnapshot.unavailable().available)
    }
}
