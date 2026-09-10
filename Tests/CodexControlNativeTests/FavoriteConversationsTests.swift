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
}
