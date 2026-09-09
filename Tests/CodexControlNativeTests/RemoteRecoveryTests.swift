import XCTest
@testable import CloudCodex

final class RemoteRecoveryTests: XCTestCase {
    let task = RemoteRecoveryTask(taskId: "task", threadId: "thread", turnId: "turn", workspace: "/project")

    func testOnlyExactTerminalTurnCanReleaseQueue() {
        for status in ["inProgress", "active", "notLoaded", "unknown", ""] {
            XCTAssertNil(task.terminalUpdate(from: ["id": "turn", "status": status]))
        }
        XCTAssertNil(task.terminalUpdate(from: ["id": "later-turn", "status": "completed"]))
        XCTAssertNil(task.terminalUpdate(from: [:]))
        for status in ["completed", "failed", "interrupted"] {
            let body = task.terminalUpdate(from: ["id": "turn", "status": status])
            XCTAssertEqual(body?.status, status == "completed" ? "completed" : "failed")
            XCTAssertEqual(body?.turnId, "turn")
            XCTAssertEqual(body?.recovery, true)
        }
    }

    func testRecoveryUsesFinalAnswerAndBoundsOutput() {
        let body = task.terminalUpdate(from: ["id": "turn", "status": "completed", "items": [
            ["type": "agentMessage", "text": "progress"], ["type": "reasoning", "text": "private"],
            ["type": "agentMessage", "text": String(repeating: "字", count: 60_001)]
        ]])
        XCTAssertEqual(body?.result.count, 60_000)
        XCTAssertEqual(body?.error, "")
        XCTAssertNil(body?.progress)
        XCTAssertNil(body?.fileDiff)
    }

    func testOlderHeartbeatStillDecodes() throws {
        let response = try JSONDecoder().decode(RemoteHeartbeatResponse.self, from: Data("{\"paired\":true}".utf8))
        XCTAssertTrue(response.paired)
        XCTAssertNil(response.runningTasks)
    }

    @MainActor
    func testOptInReadOnlyRecoveryProtocol() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let thread = env["CLOUDCODEX_RECOVERY_THREAD"], let workspace = env["CLOUDCODEX_RECOVERY_WORKSPACE"],
              let ids = env["CLOUDCODEX_RECOVERY_TURNS"] else { throw XCTSkip("Opt-in read-only recovery protocol check") }
        let tasks = ids.split(separator: ",").map { RemoteRecoveryTask(taskId: String($0), threadId: thread, turnId: String($0), workspace: workspace) }
        let client = AppServerClient()
        try await client.start()
        let updates = try await client.readRemoteRecovery(tasks)
        XCTAssertEqual(updates.count, tasks.count)
        for task in tasks { print("Recovery check: \(task.turnId) -> \(updates[task.taskId]?.status ?? "unresolved")") }
    }
}
