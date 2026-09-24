import XCTest
@testable import CloudCodex

final class CodexProfileReaderTests: XCTestCase {
    func testReadsDisplayOnlyProfileClaimsAndDerivesUsername() throws {
        let access = token(["https://api.openai.com/profile": [
            "name": "Example Name",
            "email": "example.handle@example.com"
        ]])
        let data = try XCTUnwrap(#"{"tokens":{"access_token":"\#(access)"}}"#.data(using: .utf8))

        let profile = try XCTUnwrap(CodexProfileReader.profile(authData: data))

        XCTAssertEqual(profile.name, "Example Name")
        XCTAssertEqual(profile.email, "example.handle@example.com")
        XCTAssertEqual(profile.username, "example.handle")
        XCTAssertNil(profile.avatarURL)
    }

    func testOfficialProfileUsesFirstPartyNameAndAvatar() throws {
        let data = try XCTUnwrap(#"""
        {
            "id":"user-123",
            "name":"ZhengYuntao",
            "email":"zheng@example.com",
            "picture":"https://chatgpt.com/backend-api/files/avatar.jpg"
        }
        """#.data(using: .utf8))

        let profile = try XCTUnwrap(CodexOfficialProfileReader.profile(responseData: data))

        XCTAssertEqual(profile.id, "user-123")
        XCTAssertEqual(profile.name, "ZhengYuntao")
        XCTAssertEqual(profile.username, "zheng")
        XCTAssertEqual(profile.avatarURL?.absoluteString, "https://chatgpt.com/backend-api/files/avatar.jpg")
    }

    func testOfficialProfileRejectsUnsafeAvatarAndMergesLocalFallback() throws {
        let data = try XCTUnwrap(#"{"id":"user-123","picture":"file:///tmp/avatar.png"}"#.data(using: .utf8))
        let official = try XCTUnwrap(CodexOfficialProfileReader.profile(responseData: data))
        let fallback = CodexProfileReader.Profile(
            name: "Token Name",
            email: "token@example.com",
            username: "token",
            avatarURL: URL(string: "https://example.com/token.png")
        )

        let merged = official.mergingFallback(fallback)

        XCTAssertEqual(merged.id, "user-123")
        XCTAssertEqual(merged.name, "Token Name")
        XCTAssertEqual(merged.avatarURL, fallback.avatarURL)
    }

    func testDisplayNameOverrideIsBoundToOneProfile() {
        let suiteName = "CodexProfileReaderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = CodexProfileDisplayNameStore(defaults: defaults)

        store.setDisplayName("  ZhengYuntao  ", for: "user-123")

        XCTAssertEqual(store.displayName(for: "user-123"), "ZhengYuntao")
        XCTAssertNil(store.displayName(for: "another-user"))
    }

    func testOnlyAcceptsHTTPSAvatarURL() throws {
        let secure = token(["picture": "https://cdn.example.com/avatar.png"])
        let insecure = token(["picture": "file:///tmp/avatar.png"])
        let secureData = try XCTUnwrap(#"{"tokens":{"id_token":"\#(secure)"}}"#.data(using: .utf8))
        let insecureData = try XCTUnwrap(#"{"tokens":{"id_token":"\#(insecure)"}}"#.data(using: .utf8))

        XCTAssertEqual(CodexProfileReader.profile(authData: secureData)?.avatarURL?.absoluteString,
                       "https://cdn.example.com/avatar.png")
        XCTAssertNil(CodexProfileReader.profile(authData: insecureData)?.avatarURL)
    }

    private func token(_ payload: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }
}
