import XCTest
@testable import CloudCodex

final class CodexSharedToolsTests: XCTestCase {
    func testOnlyToolConfigurationIsInheritedAndAccountOverridesWin() throws {
        let source: [String: Any] = [
            "plugins": ["computer-use@test": ["enabled": true], "local@test": ["enabled": true]],
            "mcp_servers": ["fixture": ["command": "/path with spaces/tool", "args": ["mcp"], "enabled": false]],
            "features": ["remote_plugin": true, "dangerous_feature": true],
            "model_provider": "private-provider", "cli_auth_credentials_store": "file",
            "forced_chatgpt_workspace_id": "private-account", "mcp_oauth_credentials_store": "file"
        ]
        let account: [String: Any] = ["plugins": ["local@test": ["enabled": false]]]
        let args = try CodexSharedTools.arguments(source: source, account: account).joined(separator: "\n")
        XCTAssertTrue(args.contains("computer-use@test"))
        XCTAssertTrue(args.contains("/path with spaces/tool"))
        XCTAssertTrue(args.contains("\"enabled\" = false"))
        XCTAssertTrue(args.contains("features.remote_plugin=true"))
        XCTAssertTrue(args.contains("\"local@test\" = { \"enabled\" = false }"))
        for blocked in [ "private-provider", "credentials_store", "private-account", "dangerous_feature"] {
            XCTAssertFalse(args.contains(blocked), blocked)
        }
    }

    func testResourcesAreLinkedWithoutSharingCredentialsOrReplacingLocalSkills() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), account = root.appendingPathComponent("account")
        let fm = FileManager.default
        for path in ["skills/personal", "skills/existing", "skills/.system", "plugins/cache/vendor/plugin/1", "plugins/.runtime"] {
            try fm.createDirectory(at: source.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: account.appendingPathComponent("skills/existing"), withIntermediateDirectories: true)
        try Data("personal skill".utf8).write(to: source.appendingPathComponent("skills/personal/SKILL.md"))
        try Data("private".utf8).write(to: source.appendingPathComponent("auth.json"))
        try Data("local".utf8).write(to: account.appendingPathComponent("skills/existing/local.txt"))
        try CodexSharedTools.prepareResources(source: source, account: account)
        try CodexSharedTools.prepareResources(source: source, account: account)
        XCTAssertEqual(try String(contentsOf: account.appendingPathComponent("skills/personal/SKILL.md")), "personal skill")
        XCTAssertNoThrow(try fm.destinationOfSymbolicLink(atPath: account.appendingPathComponent("skills/personal").path))
        XCTAssertTrue(fm.fileExists(atPath: account.appendingPathComponent("plugins/cache/vendor/plugin/1").path))
        XCTAssertTrue(fm.fileExists(atPath: account.appendingPathComponent("skills/existing/local.txt").path))
        for path in ["auth.json", "config.toml", "skills/.system", "plugins/.runtime"] {
            XCTAssertFalse(fm.fileExists(atPath: account.appendingPathComponent(path).path), path)
        }
    }
}
