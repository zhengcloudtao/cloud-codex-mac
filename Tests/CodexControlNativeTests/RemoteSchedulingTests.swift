import XCTest
@testable import CloudCodex

final class RemoteSchedulingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func thread(_ id: String, workspace: String = "/a", status: String = "idle") -> CodexThread {
        CodexThread(json: ["id": id, "cwd": workspace, "name": id, "status": status])!
    }

    private func task(_ id: String, workspace: String = "/a") -> RemoteTask {
        RemoteTask(taskId: "task-\(id)", deviceId: "mac", threadId: id, workspace: workspace,
                   prompt: "request", model: "", effort: "", status: "running")
    }

    func testBusyWriterSurvivesIdleSnapshotButExpiresForRecheck() {
        var state = RemoteSchedulingState()
        state.replace(with: [thread("busy"), thread("free", workspace: "/b")], now: now)
        state.deferBusyThread(task("busy"), now: now)
        // An app-server state-db read may report idle even while resume rejects
        // an external active writer. It must not immediately undo the deferral.
        state.replace(with: [thread("busy"), thread("free", workspace: "/b")], now: now.addingTimeInterval(9))
        let snapshot = state.snapshots(allowedPaths: ["/a", "/b"], now: now.addingTimeInterval(10))
        XCTAssertEqual(snapshot.first { $0.id == "busy" }?.status, "active")
        XCTAssertEqual(snapshot.first { $0.id == "busy" }?.updatedAt, now.timeIntervalSince1970)
        XCTAssertEqual(snapshot.first { $0.id == "free" }?.status, "idle")
        XCTAssertEqual(state.snapshots(allowedPaths: ["/a", "/b"], now: now.addingTimeInterval(31))
            .first { $0.id == "busy" }?.status, "idle")
    }

    func testBusyThreadOutsideRecentPageAndUnauthorizedWorkspaces() {
        var state = RemoteSchedulingState()
        state.replace(with: [thread("recent", workspace: "/b"), thread("secret", workspace: "/not-authorized")], now: now)
        state.deferBusyThread(task("older"), now: now)
        XCTAssertEqual(Set(state.snapshots(allowedPaths: ["/a", "/b"], now: now).map(\.id)), ["older", "recent"])
        XCTAssertEqual(state.snapshots(allowedPaths: ["/b"], now: now).map(\.id), ["recent"])
    }

    func testFailedReadsCannotKeepAnOldActiveSnapshotForever() {
        var state = RemoteSchedulingState()
        state.replace(with: [thread("external", status: "active")], now: now)
        XCTAssertEqual(state.snapshots(allowedPaths: ["/a"], now: now.addingTimeInterval(31)).first?.status, "unknown")
        let locallyRunning = state.snapshots(allowedPaths: ["/a"], locallyRunning: [thread("external")], now: now.addingTimeInterval(31))
        XCTAssertEqual(locallyRunning.count, 1)
        XCTAssertEqual(locallyRunning.first?.status, "active")
        XCTAssertEqual(locallyRunning.first?.updatedAt, 0)
    }

    @MainActor
    func testHeartbeatIsUnaffectedBySidebarSelectionAndClearingVisibleList() throws {
        let suite = "RemoteSchedulingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(remoteDefaults: defaults)
        model.folderCatalog = ["/a", "/b"].map { WorkspaceFolder(path: $0, latestUpdate: now) }
        let a = thread("a", status: "active"), b = thread("b", workspace: "/b")
        model.applyRemoteSchedulingSnapshot([a, b])
        model.threads = [a]
        model.selectedFolder = "/a"
        let original = model.makeRemoteHeartbeat(ready: true)
        model.threads = []
        model.selectedFolder = "/b"
        XCTAssertEqual(model.makeRemoteHeartbeat(ready: true).threads, original.threads)
        model.threads = [b]
        XCTAssertEqual(model.makeRemoteHeartbeat(ready: true).threads, original.threads)
        XCTAssertEqual(model.threads.map(\.id), ["b"], "Background heartbeat must not alter the UI")
    }

    func testQueueSummaryDecodesAndDoesNotClaimAllTasksAreBlocked() throws {
        let response = try JSONDecoder().decode(RemoteHeartbeatResponse.self, from: Data(#"{"paired":true,"queueSummary":{"queuedCount":4,"blockedCount":3}}"#.utf8))
        XCTAssertEqual(response.queueSummary?.waitingDescription, "4 条任务排队中，3 条等待会话空闲；其余继续领取")
        XCTAssertNil(RemoteQueueSummary(queuedCount: 0, blockedCount: 0).waitingDescription)
        XCTAssertEqual(RemoteQueueSummary(queuedCount: 3, blockedCount: 3).waitingDescription, "3 条任务排队中，等待会话空闲或释放")
    }

    @MainActor
    func testLateAndCanceledRefreshesDoNotReplaceNewSnapshot() async throws {
        let suite = "RemoteSchedulingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(remoteDefaults: defaults)
        model.folderCatalog = [WorkspaceFolder(path: "/a", latestUpdate: now)]
        var continuation: CheckedContinuation<[CodexThread], Error>?
        let older = Task { @MainActor in
            await model.refreshRemoteSchedulingSnapshot {
                try await withCheckedThrowingContinuation { continuation = $0 }
            }
        }
        while continuation == nil { await Task.yield() }
        await model.refreshRemoteSchedulingSnapshot { [self.thread("new")] }
        continuation?.resume(returning: [thread("old")])
        await older.value
        XCTAssertEqual(model.makeRemoteHeartbeat(ready: true).threads.map(\.id), ["new"])

        continuation = nil
        let canceled = Task { @MainActor in
            await model.refreshRemoteSchedulingSnapshot {
                try await withCheckedThrowingContinuation { continuation = $0 }
            }
        }
        while continuation == nil { await Task.yield() }
        canceled.cancel()
        continuation?.resume(returning: [thread("canceled")])
        await canceled.value
        XCTAssertEqual(model.makeRemoteHeartbeat(ready: true).threads.map(\.id), ["new"])
    }
}
