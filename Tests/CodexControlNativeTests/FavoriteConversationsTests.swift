import XCTest
@testable import CloudCodex

final class FavoriteConversationsTests: XCTestCase {
    private func thread(_ id: String, updatedAt: TimeInterval = 0, name: String? = nil) throws -> CodexThread {
        try XCTUnwrap(CodexThread(json: [
            "id": id,
            "cwd": "/tmp/project",
            "name": name as Any,
            "preview": "preview \(id)",
            "recencyAt": updatedAt,
            "status": "idle"
        ]))
    }

    func testToggleUpdateSearchAndRecencyOrder() throws {
        var favorites = FavoriteConversations()
        let older = try thread("older", updatedAt: 10, name: "旧会话")
        let newer = try thread("newer", updatedAt: 20, name: "新会话")
        favorites.toggle(older)
        favorites.toggle(newer)
        XCTAssertEqual(favorites.sortedThreads().map(\.id), ["newer", "older"])
        XCTAssertEqual(favorites.sortedThreads(matching: "旧").map(\.id), ["older"])

        let refreshedOlder = try thread("older", updatedAt: 30, name: "已更新")
        favorites.updateIfFavorite(refreshedOlder)
        XCTAssertEqual(favorites.sortedThreads().map(\.id), ["older", "newer"])
        favorites.toggle(refreshedOlder)
        XCTAssertFalse(favorites.contains("older"))
    }

    @MainActor
    func testModelPersistsFavoriteByRealThreadID() throws {
        let suite = "FavoriteConversationsTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let favorite = try thread("thread-real-id", updatedAt: 50)

        let model = AppModel(remoteDefaults: defaults)
        model.toggleFavoriteConversation(favorite)
        let restored = AppModel(remoteDefaults: defaults)

        XCTAssertTrue(restored.isFavoriteConversation("thread-real-id"))
        XCTAssertEqual(restored.visibleFavoriteThreads.map(\.id), ["thread-real-id"])
    }
    func testRemoteCommandsAreDurableAndNeverReplayOverLaterLocalChoice() throws {
        let value = try thread("remote", updatedAt: 50)
        var favorites = FavoriteConversations()
        favorites.apply(value, favorited: true, commandID: "request-1")
        XCTAssertTrue(favorites.contains(value.id))
        favorites.toggle(value) // A later Mac action wins over a retry of the old command.
        var restored = try JSONDecoder().decode(FavoriteConversations.self, from: JSONEncoder().encode(favorites))
        restored.apply(value, favorited: true, commandID: "request-1")
        XCTAssertFalse(restored.contains(value.id))
        restored.apply(value, favorited: true, commandID: "request-2")
        restored.apply(value, favorited: false, commandID: "request-3")
        XCTAssertFalse(restored.contains(value.id))
        XCTAssertTrue(restored.hasApplied("request-3"))
    }

    func testLegacyFavoritesAndOlderAuthorizedSnapshots() throws {
        let value = try thread("older", updatedAt: 1)
        let legacy = try JSONSerialization.data(withJSONObject: ["snapshots": [:]])
        var favorites = try JSONDecoder().decode(FavoriteConversations.self, from: legacy)
        favorites.toggle(value)
        let recent = RemoteThreadSnapshot(id: "recent", title: "Recent", workspace: "/tmp/project", model: "", status: "active")
        let snapshots = favorites.remoteSnapshots(recent: [recent], allowedPaths: ["/tmp/project"])
        XCTAssertEqual(snapshots.map(\.id), ["recent", "older"])
        XCTAssertEqual(snapshots[0].isFavorite, false)
        XCTAssertEqual(snapshots[0].status, "active")
        XCTAssertEqual(snapshots[1].isFavorite, true)
        XCTAssertEqual(snapshots[1].status, "unknown")
        XCTAssertTrue(favorites.remoteSnapshots(recent: [], allowedPaths: []).isEmpty)
        let current = RemoteThreadSnapshot(id: "older", title: "Renamed", workspace: "/tmp/project", model: "", status: "idle")
        XCTAssertEqual(favorites.remoteSnapshots(recent: [current], allowedPaths: ["/tmp/project"]).count, 1)
    }

    func testRemoteCommandRejectsExpiredAndMalformedDeadlines() {
        let now = Date(timeIntervalSince1970: 1000)
        var command = RemoteFavoriteChange(id: "c", deviceId: "mac", threadId: "t", workspace: "/tmp/project", favorited: true)
        XCTAssertTrue(command.isExpired(at: now))
        command.expiresAt = "1970-01-01T00:20:00.123Z"
        XCTAssertFalse(command.isExpired(at: now))
        command.expiresAt = "1970-01-01T00:10:00Z"
        XCTAssertTrue(command.isExpired(at: now))
        command.expiresAt = "invalid"
        XCTAssertTrue(command.isExpired(at: now))
    }

}
