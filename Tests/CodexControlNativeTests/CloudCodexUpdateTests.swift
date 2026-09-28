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
            latestBuild: "58",
            minimumVersion: "0.2.0",
            updateMessage: "请更新。",
            downloadUrl: "https://downloads.example.com/CloudCodex.zip",
            downloadSha256: String(repeating: "a", count: 64),
            downloadLength: 1024,
            downloadEdSignature: Data(repeating: 1, count: 64).base64EncodedString()
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
            latestBuild: nil,
            minimumVersion: "8.0.0",
            updateMessage: "请更新。",
            downloadUrl: nil,
            downloadSha256: nil,
            downloadLength: nil,
            downloadEdSignature: nil
        )
        XCTAssertEqual(CloudCodexUpdateDecision.evaluate(currentVersion: "0.1.0", config: config), .none)
    }

    func testReleaseEndpointUsesExistingGoAIBaseURL() {
        let endpoint = RemoteControlAPI.defaultBaseURL.appendingPathComponent("api/public/cloud-codex/release")
        XCTAssertEqual(endpoint.absoluteString, "https://api.cloudslow.com/ai/api/public/cloud-codex/release")
        XCTAssertEqual(
            CloudCodexSparkleConfiguration.feedURL.absoluteString,
            "https://api.cloudslow.com/ai/api/public/cloud-codex/appcast.xml"
        )
    }

    func testSparkleRequiresSignedHTTPSAppArchiveMetadata() {
        let signature = Data(repeating: 1, count: 64).base64EncodedString()
        let ready = CloudCodexReleaseConfig(
            updateEnabled: true,
            latestVersion: "0.3.0",
            latestBuild: "58",
            minimumVersion: "0.2.0",
            updateMessage: "请更新。",
            downloadUrl: "https://downloads.example.com/CloudCodex.zip",
            downloadSha256: String(repeating: "a", count: 64),
            downloadLength: 1024,
            downloadEdSignature: signature
        )
        XCTAssertTrue(ready.isSparkleReady)
        XCTAssertFalse(CloudCodexReleaseConfig(
            updateEnabled: true,
            latestVersion: "0.3.0",
            latestBuild: "58",
            minimumVersion: "0.2.0",
            updateMessage: "请更新。",
            downloadUrl: "http://downloads.example.com/CloudCodex.zip",
            downloadSha256: String(repeating: "a", count: 64),
            downloadLength: 1024,
            downloadEdSignature: signature
        ).isSparkleReady)
        XCTAssertFalse(CloudCodexReleaseConfig(
            updateEnabled: true,
            latestVersion: "0.3.0",
            latestBuild: nil,
            minimumVersion: "0.2.0",
            updateMessage: "请更新。",
            downloadUrl: "https://downloads.example.com/CloudCodex.zip",
            downloadSha256: String(repeating: "a", count: 64),
            downloadLength: 1024,
            downloadEdSignature: signature
        ).isSparkleReady)
    }
}
