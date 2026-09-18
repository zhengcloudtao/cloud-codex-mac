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
