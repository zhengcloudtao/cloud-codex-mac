import Foundation
import XCTest
@testable import CloudCodex

final class CodexSubscriptionPeriodReaderTests: XCTestCase {
    func testReadsSubscriptionPeriodFromAccessToken() throws {
        let token = makeJWT(claimValue: "2026-10-01T01:49:29+00:00")
        let authData = try XCTUnwrap(#"{"tokens":{"access_token":"\#(token)"}}"#.data(using: .utf8))

        let date = try XCTUnwrap(CodexSubscriptionPeriodReader.subscriptionPeriodEnd(authData: authData))

        XCTAssertEqual(date.timeIntervalSince1970, 1_790_819_369, accuracy: 0.1)
    }

    func testFallsBackToIDTokenAndAcceptsEpoch() throws {
        let token = makeJWT(claimValue: 1_900_000_000)
        let authData = try XCTUnwrap(#"{"tokens":{"access_token":"not-a-jwt","id_token":"\#(token)"}}"#.data(using: .utf8))

        XCTAssertEqual(
            CodexSubscriptionPeriodReader.subscriptionPeriodEnd(authData: authData)?.timeIntervalSince1970,
            1_900_000_000
        )
    }

    func testDoesNotMistakeOAuthExpiryForSubscriptionEnd() throws {
        let token = makeJWT(payload: ["exp": 1_900_000_000])
        let authData = try XCTUnwrap(#"{"tokens":{"access_token":"\#(token)"}}"#.data(using: .utf8))

        XCTAssertNil(CodexSubscriptionPeriodReader.subscriptionPeriodEnd(authData: authData))
    }

    func testUsesConfiguredCodexHomeWithoutScanningDefaultHomes() {
        let reader = CodexSubscriptionPeriodReader(
            environment: ["CODEX_HOME": "/tmp/cloudcodex-test-home"],
            homeDirectory: URL(fileURLWithPath: "/tmp/ignored-home"),
            loadData: { _ in nil }
        )

        XCTAssertEqual(reader.authPaths().map(\.path), ["/tmp/cloudcodex-test-home/auth.json"])
    }

    private func makeJWT(claimValue: Any) -> String {
        makeJWT(payload: [
            "https://api.openai.com/auth": [
                "chatgpt_subscription_active_until": claimValue
            ]
        ])
    }

    private func makeJWT(payload: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }
}
