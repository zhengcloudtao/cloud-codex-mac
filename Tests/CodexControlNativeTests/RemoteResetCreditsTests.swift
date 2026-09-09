import XCTest
@testable import CloudCodex

final class RemoteResetCreditsTests: XCTestCase {
    func testEachCreditKeepsItsExpiryAndOpaqueReference() throws {
        let snapshot = RemoteUsageSnapshot.parse(["rateLimitResetCredits": [
            "availableCount": 2,
            "credits": [
                ["id": "test-first", "status": "available", "resetType": "codexRateLimits", "expiresAt": 2_000_000_000],
                ["id": "test-second", "status": "available", "resetType": "codexRateLimits"],
                ["id": "test-used", "status": "redeemed", "resetType": "codexRateLimits"]
            ]
        ]])
        let credits = try XCTUnwrap(snapshot.resetCredits?.credits)
        XCTAssertEqual(credits.count, 2)
        XCTAssertEqual(credits[0].ref, RemoteUsageSnapshot.creditReference("test-first"))
        XCTAssertNotEqual(credits[0].ref, credits[1].ref)
        XCTAssertEqual(credits[0].expiresAt, 2_000_000_000)
        XCTAssertNil(credits[1].expiresAt)
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("test-first"))
    }
}
