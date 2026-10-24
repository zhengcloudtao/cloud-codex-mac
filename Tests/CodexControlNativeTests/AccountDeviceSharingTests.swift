import XCTest
import CryptoKit
@testable import CloudCodex

final class AccountDeviceSharingTests: XCTestCase {
    func testCiphertextBindsShareAndVersion() throws {
        let key = Data(0..<32)
        let access = SharedAccountAccess(accessToken: "synthetic-access-only", chatgptAccountId: "fixture-account", chatgptPlanType: "plus", email: "fixture@example.invalid", expiresAt: 2_000_001_800)
        let cipher = try AccountShareCrypto.seal(access, id: "share", version: 2, key: key)
        let result = try AccountShareCrypto.open(.init(id: "share", version: 2, ciphertext: cipher), key: key)
        XCTAssertEqual(result.accessToken, access.accessToken)
        XCTAssertThrowsError(try AccountShareCrypto.open(.init(id: "different", version: 2, ciphertext: cipher), key: key))
        XCTAssertThrowsError(try AccountShareCrypto.open(.init(id: "share", version: 1, ciphertext: cipher), key: key))
        XCTAssertThrowsError(try AccountShareCrypto.open(.init(id: "share", version: 2, ciphertext: cipher), key: Data(repeating: 7, count: 32)))
        XCTAssertFalse(cipher.contains(access.accessToken))
    }
    func testCrossPlatformFixture() throws {
        // A fixed synthetic CryptoKit fixture is also opened by the Windows test.
        let cipher = "AAECAwQFBgcICQoLPCC3eKaAsWjZLvzu38tCT/Cv6UCYHisVW0qE5n4Mc8Esf8CQ1uM+uhfMHpnv91x5jToP+DSi6r4drQh/cZuBm4JZ6xuwskkUciCIQs3sZolM7bkWJg8yBqmE7qlaypv9p40qxIhjrXf/dVKQcldHFsITF9mGhUDiLJInoefIB2DNM2yv0PXncW2ZOMhPvz+DQtbZBwUho3q8btBHyq8RQhWtM6CYUFosBryb8dR+"
        let access = try AccountShareCrypto.open(.init(id: "11111111-2222-3333-4444-555555555555", version: 2, ciphertext: cipher), key: Data(0..<32))
        XCTAssertEqual(access.chatgptAccountId, "fixture-account")
        XCTAssertEqual(access.expiresAt, 2_000_001_800)
    }
    func testRefreshTokenIsNeverIncludedInExport() throws {
        let claims: [String: Any] = ["exp": 2_000_001_800, "https://api.openai.com/auth": ["chatgpt_account_id": "fixture-account"]]
        let raw = try JSONSerialization.data(withJSONObject: claims).base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let fixture = try JSONSerialization.data(withJSONObject: ["tokens": ["access_token": "fixture.\(raw).signature", "refresh_token": "synthetic-never-export", "account_id": "fixture-account"]])
        let access = try AccountShareKeychain.parseAccess(fixture, identity: .init(email: "fixture@example.invalid", plan: "plus"))
        let serialized = try JSONEncoder().encode(access)
        XCTAssertFalse(String(decoding: serialized, as: UTF8.self).contains("refresh_token"))
        XCTAssertFalse(String(decoding: serialized, as: UTF8.self).contains("synthetic-never-export"))
        XCTAssertEqual(access.chatgptAccountId, "fixture-account")
    }
}
