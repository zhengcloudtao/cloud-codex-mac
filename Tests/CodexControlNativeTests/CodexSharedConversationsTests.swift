import XCTest
@testable import CloudCodex

final class CodexSharedConversationsTests: XCTestCase {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SharedConversationTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testMigratesExistingSessionsKeepsBackupsAndDoesNotShareCredentials() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("local"), account = root.appendingPathComponent("account")
        let relative = "sessions/2026/10/23/rollout-test.jsonl"
        let source = account.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic history\n".utf8).write(to: source)
        let auth = account.appendingPathComponent("auth.json")
        try Data("synthetic-placeholder".utf8).write(to: auth)
        try CodexSharedConversations.prepare(home: shared, accountHomes: [account])
        XCTAssertEqual(try Data(contentsOf: shared.appendingPathComponent(relative)), Data("synthetic history\n".utf8))
        XCTAssertEqual(source.resolvingSymlinksInPath(), shared.appendingPathComponent(relative).resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: auth), Data("synthetic-placeholder".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.appendingPathComponent("auth.json").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: account.path).contains { $0.hasPrefix("sessions.before-sharing-") })
        try CodexSharedConversations.prepare(home: shared, accountHomes: [account])
        try Data("continued history\n".utf8).write(to: source)
        XCTAssertEqual(try Data(contentsOf: shared.appendingPathComponent(relative)), Data("continued history\n".utf8))
    }

    func testDivergentHistoryStopsWithoutOverwritingEitherCopy() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("local"), account = root.appendingPathComponent("account")
        for home in [shared, account] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        }
        let a = shared.appendingPathComponent("sessions/same.jsonl"), b = account.appendingPathComponent("sessions/same.jsonl")
        try Data("local branch".utf8).write(to: a); try Data("account branch".utf8).write(to: b)
        XCTAssertThrowsError(try CodexSharedConversations.prepare(home: shared, accountHomes: [account]))
        XCTAssertEqual(try Data(contentsOf: a), Data("local branch".utf8))
        XCTAssertEqual(try Data(contentsOf: b), Data("account branch".utf8))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: b.deletingLastPathComponent().path))
    }

    func testLongerHistoryRetainsOriginalAsBackup() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("local"), account = root.appendingPathComponent("account")
        for home in [shared, account] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent("archived_sessions"), withIntermediateDirectories: true)
        }
        let name = "archived_sessions/same.jsonl"
        try Data("old\n".utf8).write(to: shared.appendingPathComponent(name))
        try Data("old\nnew\n".utf8).write(to: account.appendingPathComponent(name))
        try CodexSharedConversations.prepare(home: shared, accountHomes: [account])
        XCTAssertEqual(try Data(contentsOf: shared.appendingPathComponent(name)), Data("old\nnew\n".utf8))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: shared.appendingPathComponent("archived_sessions").path).contains { $0.hasPrefix("same.jsonl.before-sharing-") })
    }

    @MainActor
    func testInstalledCodexResumesSameThreadAcrossCredentialHomes() async throws {
        guard ProcessInfo.processInfo.environment["CLOUDCODEX_SHARED_HISTORY_INTEGRATION"] == "1" else {
            throw XCTSkip("Opt in to exercising the installed Codex CLI using synthetic history only.")
        }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("shared history"), account = root.appendingPathComponent("account")
        let id = UUID().uuidString.lowercased()
        let path = shared.appendingPathComponent("sessions/2026/10/23/rollout-2026-10-23T00-00-00-\(id).jsonl")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rows: [[String: Any]] = [
            ["timestamp": "2026-10-23T00:00:00Z", "type": "session_meta", "payload": ["id": id, "timestamp": "2026-10-23T00:00:00Z", "cwd": root.path, "originator": "codex_cli_rs", "cli_version": "0.163.0", "source": "cli", "model_provider": "openai"]],
            ["timestamp": "2026-10-23T00:00:01Z", "type": "event_msg", "payload": ["type": "user_message", "message": "Synthetic shared conversation", "images": [], "local_images": []]],
            ["timestamp": "2026-10-23T00:00:01Z", "type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Synthetic shared conversation"]]]]
        ]
        let data = try rows.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try Data(data.utf8).write(to: path)
        try CodexSharedConversations.prepare(home: shared, accountHomes: [account])
        let client = AppServerClient(codexHomeOverride: shared)
        client.sharedConversationHome = shared
        defer { client.shutdown() }
        try await client.start()
        let first = try await client.listThreads()
        XCTAssertTrue(first.threads.contains { $0.id == id })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: shared.path).contains {
            $0.hasPrefix("state_") && $0.hasSuffix(".sqlite")
        }, "The database must be created in the exact shared directory, including paths containing spaces.")
        try await client.resumeThread(id)
        try await client.changeAccount(home: account, managed: true)
        let second = try await client.listThreads()
        XCTAssertTrue(second.threads.contains { $0.id == id })
        let resumed = try await client.readThreadState(id)
        XCTAssertEqual(resumed.id, id)
        try await client.resumeThread(id)
        XCTAssertEqual(try Data(contentsOf: path).prefix(data.utf8.count), Data(data.utf8))
        try await client.changeAccount(home: shared, managed: false)
        try await client.resumeThread(id)
    }
}
