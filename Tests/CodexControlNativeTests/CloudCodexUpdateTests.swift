import XCTest
@testable import CloudCodex

final class CloudCodexUpdateTests: XCTestCase {
    func testVersionComparisonUsesNumericComponents() {
        XCTAssertLessThan(SemanticAppVersion("0.9.9")!, SemanticAppVersion("0.10.0")!)
        XCTAssertLessThan(SemanticAppVersion("1.0.0")!, SemanticAppVersion("2.0.0")!)
        XCTAssertNil(SemanticAppVersion("1.2"))
        XCTAssertNil(SemanticAppVersion("latest"))
    }

    func testUpdateDecisionDistinguishesLatestAndMinimumVersions() {
        let config = CloudCodexReleaseConfig(
            updateEnabled: true,
            latestVersion: "0.3.0",
            minimumVersion: "0.2.0",
            updateMessage: "请更新。",
            downloadUrl: "https://downloads.example.com/CloudCodex.zip",
            downloadSha256: String(repeating: "a", count: 64)
        )
        XCTAssertEqual(CloudCodexUpdateDecision.evaluate(currentVersion: "0.1.0", config: config), .required)
        XCTAssertEqual(CloudCodexUpdateDecision.evaluate(currentVersion: "0.2.0", config: config), .optional)
        XCTAssertEqual(CloudCodexUpdateDecision.evaluate(currentVersion: "0.3.0", config: config), .none)
        XCTAssertEqual(CloudCodexUpdateDecision.evaluate(currentVersion: "0.4.0", config: config), .none)
    }

    func testDisabledUpdatePromptNeverShows() {
        let config = CloudCodexReleaseConfig(
            updateEnabled: false,
            latestVersion: "9.0.0",
            minimumVersion: "8.0.0",
            updateMessage: "请更新。",
            downloadUrl: nil,
            downloadSha256: nil
        )
        XCTAssertEqual(CloudCodexUpdateDecision.evaluate(currentVersion: "0.1.0", config: config), .none)
    }

    func testReleaseEndpointUsesExistingGoAIBaseURL() {
        let endpoint = RemoteControlAPI.defaultBaseURL.appendingPathComponent("api/public/cloud-codex/release")
        XCTAssertEqual(endpoint.absoluteString, "https://api.cloudslow.com/ai/api/public/cloud-codex/release")
    }

    func testUpdatePackageRequiresHTTPSArchiveAndChecksum() {
        let checksum = String(repeating: "a", count: 64)
        XCTAssertNotNil(CloudCodexUpdatePackage(
            url: "https://downloads.example.com/CloudCodex.dmg?source=admin",
            sha256: checksum,
            version: "0.3.0"
        ))
        XCTAssertNil(CloudCodexUpdatePackage(
            url: "http://downloads.example.com/CloudCodex.dmg",
            sha256: checksum,
            version: "0.3.0"
        ))
        XCTAssertNil(CloudCodexUpdatePackage(
            url: "https://downloads.example.com/CloudCodex.txt",
            sha256: checksum,
            version: "0.3.0"
        ))
        XCTAssertNil(CloudCodexUpdatePackage(
            url: "https://downloads.example.com/CloudCodex.zip",
            sha256: "bad",
            version: "0.3.0"
        ))
    }

    func testUpdatePackageSHA256Verification() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("hello".utf8).write(to: file)
        let package = CloudCodexUpdatePackage(
            url: "https://downloads.example.com/CloudCodex.zip",
            sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
            version: "0.3.0"
        )
        XCTAssertEqual(try CloudCodexUpdatePackage.sha256(of: file), package?.sha256)
        XCTAssertEqual(try package?.matches(fileAt: file), true)
    }
}
