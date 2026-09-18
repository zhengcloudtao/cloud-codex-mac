import XCTest
@testable import CloudCodex

@MainActor
final class StalledTurnRecoveryTests: XCTestCase {
    private func thread(_ status: String) -> CodexThread {
        CodexThread(json: [
            "id": "thread",
            "cwd": "/tmp/project",
            "status": ["type": status]
        ])!
    }

    func testMatchingPersistedTerminalTurnRepairsMissedCompletionEvent() {
        let model = AppModel()
        model.selectedThreadID = "thread"
        model.threads = [thread("active")]
        model.handleEvent("turn/started", [
            "threadId": "thread",
            "turn": ["id": "turn-one"]
        ])

        let repaired = model.reconcileLocalTurnSnapshot(
            ThreadActivitySnapshot(
                thread: thread("idle"),
                turn: TurnRuntimeState(
                    id: "turn-one",
                    status: "completed",
                    startedAt: nil,
                    completedAt: Date()
                ),
                messages: []
            ),
            threadID: "thread"
        )

        XCTAssertTrue(repaired)
        XCTAssertFalse(model.isSending)
        XCTAssertNil(model.activeTurnID)
        XCTAssertEqual(model.threadOutcomes["thread"], .completed)
        XCTAssertEqual(model.threads.first?.status, "idle")
    }

    func testActivePersistedTurnDoesNotGetCleared() {
        let model = AppModel()
        model.selectedThreadID = "thread"
        model.handleEvent("turn/started", [
            "threadId": "thread",
            "turn": ["id": "turn-one"]
        ])

        let repaired = model.reconcileLocalTurnSnapshot(
            ThreadActivitySnapshot(
                thread: thread("active"),
                turn: TurnRuntimeState(
                    id: "turn-one",
                    status: "inProgress",
                    startedAt: Date(),
                    completedAt: nil
                ),
                messages: []
            ),
            threadID: "thread",
            now: Date().addingTimeInterval(120)
        )

        XCTAssertFalse(repaired)
        XCTAssertTrue(model.isSending)
        XCTAssertEqual(model.activeTurnID, "turn-one")
    }

    func testIdleThreadWithoutExpectedTurnUsesGracePeriodBeforeRecovery() {
        let model = AppModel()
        model.selectedThreadID = "thread"
        model.handleEvent("turn/started", [
            "threadId": "thread",
            "turn": ["id": "turn-one"]
        ])
        let idleSnapshot = ThreadActivitySnapshot(thread: thread("idle"), turn: nil, messages: [])

        XCTAssertFalse(model.reconcileLocalTurnSnapshot(
            idleSnapshot,
            threadID: "thread",
            now: Date().addingTimeInterval(10)
        ))
        XCTAssertTrue(model.isSending)

        XCTAssertTrue(model.reconcileLocalTurnSnapshot(
            idleSnapshot,
            threadID: "thread",
            now: Date().addingTimeInterval(AppModel.localTurnReconciliationGrace + 1)
        ))
        XCTAssertFalse(model.isSending)
        XCTAssertEqual(model.threadOutcomes["thread"], .interrupted)
        XCTAssertEqual(model.messages.first { $0.id == "turn-progress" }?.activityTitle, "连接中断")
        XCTAssertEqual(model.messages.first { $0.id == "turn-progress" }?.activityStatus, "失败")
    }

    func testAppServerDisconnectClearsAllOptimisticRuns() {
        let model = AppModel()
        model.selectedThreadID = "thread"
        model.handleEvent("turn/started", [
            "threadId": "thread",
            "turn": ["id": "turn-one"]
        ])

        model.handleClientDisconnect("Codex 本地服务已退出（状态码 9）")

        XCTAssertFalse(model.isSending)
        XCTAssertNil(model.activeTurnID)
        XCTAssertEqual(model.connectionText, "未连接")
        XCTAssertEqual(model.threadOutcomes["thread"], .interrupted)
        XCTAssertEqual(model.messages.first { $0.id == "turn-progress" }?.activityTitle, "连接中断")
        XCTAssertEqual(model.messages.first { $0.id == "turn-progress" }?.activityStatus, "失败")
        XCTAssertFalse(model.messages.contains { $0.isStreaming })
    }
}
