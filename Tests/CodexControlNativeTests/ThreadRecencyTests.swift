import XCTest
@testable import CloudCodex

@MainActor
final class ThreadRecencyTests: XCTestCase {
    func testRecentAndProjectListsSelectLatestUserRecencyBeforeLimiting() {
        for cwd in [nil, "/tmp/project"] as [String?] {
            let params = AppServerClient.threadListParameters(cwd: cwd)
            XCTAssertEqual(params["sortKey"] as? String, "recency_at")
            XCTAssertEqual(params["sortDirection"] as? String, "desc")
            XCTAssertEqual(params["limit"] as? Int, 60)
            XCTAssertEqual(params["cwd"] as? String, cwd)
        }
    }

    func testDisplayedTimestampIgnoresLaterAssistantUpdates() throws {
        let thread = try XCTUnwrap(CodexThread(json: [
            "id": "one", "cwd": "/tmp/project", "recencyAt": 100, "updatedAt": 900
        ]))
        XCTAssertEqual(thread.updatedAt.timeIntervalSince1970, 100)
    }

    @MainActor
    func testRefreshKeepsServerUserRecencyOrderDespiteCompletionTimes() throws {
        let newerQuestion = try XCTUnwrap(CodexThread(json: [
            "id": "new-question", "cwd": "/tmp/project", "recencyAt": 200, "updatedAt": 200
        ]))
        let laterAnswer = try XCTUnwrap(CodexThread(json: [
            "id": "old-question", "cwd": "/tmp/project", "recencyAt": 100, "updatedAt": 900
        ]))
        let model = AppModel()
        model.applyThreadListSnapshot([newerQuestion, laterAnswer])
        XCTAssertEqual(model.visibleThreads.map(\.id), ["new-question", "old-question"])
        model.applyVisibleThreadStatuses(["old-question": "idle"])
        XCTAssertEqual(model.visibleThreads.map(\.id), ["new-question", "old-question"])
        model.selectedThreadID = "old-question"
        model.applyThreadListSnapshot([newerQuestion])
        XCTAssertEqual(model.visibleThreads.map(\.id), ["new-question", "old-question"])
    }
}
