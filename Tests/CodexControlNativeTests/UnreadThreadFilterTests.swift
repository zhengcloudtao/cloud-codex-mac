import XCTest
@testable import CloudCodex

final class UnreadThreadFilterTests: XCTestCase {
    @MainActor
    func testUnreadFilterSpansWorkspacesAndRecentPageAndMarksRead() throws {
        let suite = "UnreadThreadFilterTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(remoteDefaults: defaults)
        func thread(_ id: String, cwd: String, date: Double) throws -> CodexThread {
            try XCTUnwrap(CodexThread(json: [
                "id": id, "cwd": cwd, "name": "会话 \(id)",
                "preview": "预览 \(id)", "recencyAt": date, "status": "idle"
            ]))
        }
        let older = try thread("older", cwd: "/tmp/one", date: 10)
        let newer = try thread("newer", cwd: "/tmp/two", date: 20)
        let read = try thread("read", cwd: "/tmp/one", date: 30)
        model.applyThreadListSnapshot([older, newer, read])
        model.recordCompletedConversation(older.id, turnID: "turn-old", viewed: false)
        model.recordCompletedConversation(newer.id, turnID: "turn-new", viewed: false)
        model.recordCompletedConversation(read.id, turnID: "turn-read", viewed: true)
        // Both unread rows have fallen outside the current workspace/page.
        model.selectedFolder = "/tmp/one"
        model.applyThreadListSnapshot([read])
        XCTAssertEqual(model.visibleUnreadThreads.map(\.id), ["newer", "older"])
        model.searchText = "  预览 older  "
        XCTAssertEqual(model.visibleUnreadThreads.map(\.id), ["older"])
        model.searchText = "会话 newer"
        XCTAssertEqual(model.visibleUnreadThreads.map(\.id), ["newer"])
        model.searchText = ""
        model.markConversationRead(newer.id)
        XCTAssertEqual(model.visibleUnreadThreads.map(\.id), ["older"])
        XCTAssertEqual(model.selectedFolder, "/tmp/one")
        XCTAssertEqual(model.threads.map(\.id), ["read"])
        model.markConversationRead(older.id)
        XCTAssertTrue(model.visibleUnreadThreads.isEmpty)
    }

    @MainActor
    func testRestoredUnreadUsesFavoriteSnapshotWithoutRecentRows() async throws {
        let suite = "UnreadThreadFilterTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let thread = try XCTUnwrap(CodexThread(json: [
            "id": "persisted", "cwd": "/tmp/project", "preview": "旧会话", "status": "idle"
        ]))
        let model = AppModel(remoteDefaults: defaults)
        model.toggleFavoriteConversation(thread)
        model.recordCompletedConversation(thread.id, turnID: "completed", viewed: false)
        let restored = AppModel(remoteDefaults: defaults)
        await restored.refreshUnreadThreads()
        XCTAssertEqual(restored.visibleUnreadThreads.map(\.id), [thread.id])
        XCTAssertEqual(restored.unreadCompletions.unread, [thread.id])
        XCTAssertNil(restored.unreadThreadsError)
        XCTAssertFalse(restored.isLoadingUnreadThreads)
    }
    @MainActor
    func testUnloadedThreadFoundInFullListKeepsBadge() async throws {
        let suite = "UnreadLookup.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(remoteDefaults: defaults)
        let thread = try XCTUnwrap(CodexThread(json: [
            "id": "old", "cwd": "/tmp/other", "preview": "归档会话", "status": "idle"
        ]))
        model.recordCompletedConversation("old", turnID: "turn", viewed: false)
        await model.refreshUnreadThreads(readThread: { id in
            throw CodexClientError.server("thread not loaded: \(id)")
        }, findThreads: { ids in
            XCTAssertEqual(ids, ["old"])
            return [thread]
        })
        XCTAssertEqual(model.visibleUnreadThreads.map(\.id), ["old"])
        XCTAssertEqual(model.unreadCompletions.unread, ["old"])
        XCTAssertNil(model.unreadThreadsError)
    }

    @MainActor
    func testOnlyConfirmedMissingThreadIsAcknowledgedAndPersists() async throws {
        let suite = "UnreadLookup.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(remoteDefaults: defaults)
        model.recordCompletedConversation("missing", turnID: "turn", viewed: false)
        await model.refreshUnreadThreads(readThread: { id in
            throw CodexClientError.server("thread not loaded: \(id)")
        }, findThreads: { _ in [] })
        XCTAssertTrue(model.unreadCompletions.unread.isEmpty)
        let restored = AppModel(remoteDefaults: defaults)
        XCTAssertTrue(restored.unreadCompletions.unread.isEmpty)
        restored.recordCompletedConversation("missing", turnID: "turn", viewed: false)
        XCTAssertTrue(restored.unreadCompletions.unread.isEmpty)
    }

    @MainActor
    func testLookupFailurePreservesBadge() async throws {
        let suite = "UnreadLookup.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(remoteDefaults: defaults)
        model.recordCompletedConversation("unavailable", turnID: "turn", viewed: false)
        await model.refreshUnreadThreads(readThread: { id in
            throw CodexClientError.server("thread not loaded: \(id)")
        }, findThreads: { _ in throw URLError(.notConnectedToInternet) })
        XCTAssertEqual(model.unreadCompletions.unread, ["unavailable"])
        XCTAssertNotNil(model.unreadThreadsError)
    }

    @MainActor
    func testNewCompletionDuringLookupIsNotCleared() async throws {
        let suite = "UnreadLookup.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(remoteDefaults: defaults)
        model.recordCompletedConversation("new", turnID: "old-turn", viewed: false)
        await model.refreshUnreadThreads(readThread: { id in
            throw CodexClientError.server("thread not loaded: \(id)")
        }, findThreads: { _ in
            model.recordCompletedConversation("new", turnID: "new-turn", viewed: false)
            return []
        })
        XCTAssertEqual(model.unreadCompletions.unread, ["new"])
    }

    @MainActor
    func testFullLookupIncludesArchivesAllProvidersAndSubagents() {
        let params = AppServerClient.unreadThreadListParameters(archived: true)
        XCTAssertEqual(params["archived"] as? Bool, true)
        XCTAssertEqual(params["modelProviders"] as? [String], [])
        XCTAssertTrue((params["sourceKinds"] as? [String])?.contains("subAgent") == true)
        XCTAssertNil(params["cwd"])
        XCTAssertNil(params["useStateDbOnly"])
    }

}
