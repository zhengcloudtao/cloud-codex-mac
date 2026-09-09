import XCTest
@testable import CloudCodex

final class UnreadCompletionTests: XCTestCase {
    func testCountsConversationsAndAcknowledgesDuplicateTurns() {
        var state = UnreadCompletions()
        state.complete(threadID: "one", turnID: "a", viewed: false)
        state.complete(threadID: "one", turnID: "b", viewed: false)
        state.complete(threadID: "two", turnID: "c", viewed: false)
        XCTAssertEqual(state.unread.count, 2)
        state.markRead("one")
        state.complete(threadID: "one", turnID: "b", viewed: false)
        XCTAssertEqual(state.unread, ["two"])
        state.complete(threadID: "one", turnID: "d", viewed: false)
        XCTAssertEqual(state.unread.count, 2)
    }

    func testForegroundCompletionAndPersistence() throws {
        var state = UnreadCompletions()
        state.complete(threadID: "one", turnID: "a", viewed: true)
        XCTAssertTrue(state.unread.isEmpty)
        state.complete(threadID: "two", turnID: "b", viewed: false)
        let restored = try JSONDecoder().decode(UnreadCompletions.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored, state)
    }

    @MainActor
    func testModelRestoresUnreadAndClickingSelectedConversationClearsIt() throws {
        let suite = "UnreadCompletionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(remoteDefaults: defaults)
        model.recordCompletedConversation("one", turnID: "a", viewed: false)
        let restored = AppModel(remoteDefaults: defaults)
        XCTAssertEqual(restored.unreadCompletions.unread, ["one"])
        restored.selectedThreadID = "one"
        restored.selectThread("one")
        XCTAssertTrue(restored.unreadCompletions.unread.isEmpty)
        restored.recordCompletedConversation("one", turnID: "a", viewed: false)
        XCTAssertTrue(restored.unreadCompletions.unread.isEmpty)
    }
}
