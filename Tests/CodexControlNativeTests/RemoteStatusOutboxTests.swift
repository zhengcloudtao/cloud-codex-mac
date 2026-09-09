import XCTest
@testable import CloudCodex

@MainActor
final class RemoteStatusOutboxTests: XCTestCase {
    func testPersistsUntilExactAcknowledgementAndSeparatesDevices() throws {
        let suite = "CloudCodex.outbox.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let body = RemoteTaskStatusBody(status: "failed", threadId: "thread", turnId: "turn", result: "saved output", error: "interrupted")
        let first = RemoteStatusOutbox(defaults: defaults)
        first.enqueue(deviceID: "a", taskID: "task", body: body)
        let restarted = RemoteStatusOutbox(defaults: defaults)
        XCTAssertEqual(restarted.pending(deviceID: "a")["task"], body)
        XCTAssertTrue(restarted.pending(deviceID: "b").isEmpty)
        let newer = RemoteTaskStatusBody(status: "failed", threadId: "thread", turnId: "turn", result: "newer output", error: "interrupted")
        restarted.enqueue(deviceID: "a", taskID: "task", body: newer)
        restarted.acknowledge(deviceID: "a", taskID: "task", body: body)
        XCTAssertEqual(restarted.pending(deviceID: "a")["task"], newer)
        restarted.acknowledge(deviceID: "a", taskID: "task", body: newer)
        XCTAssertTrue(RemoteStatusOutbox(defaults: defaults).pending(deviceID: "a").isEmpty)
    }

    func testLateRequeueCannotReplaceTerminalReport() {
        let suite = "CloudCodex.outbox.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let box = RemoteStatusOutbox(defaults: defaults)
        let finished = RemoteTaskStatusBody(status: "completed", threadId: "t", turnId: "r", result: "done", error: "")
        box.enqueue(deviceID: "a", taskID: "t", body: finished)
        box.enqueue(deviceID: "a", taskID: "t", body: RemoteTaskStatusBody(status: "queued", threadId: "t", turnId: "", result: "", error: ""))
        XCTAssertEqual(box.pending(deviceID: "a")["t"], finished)
    }
}
