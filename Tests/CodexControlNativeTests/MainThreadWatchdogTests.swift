import XCTest
@testable import CloudCodex

final class MainThreadWatchdogTests: XCTestCase {
    func testBlockedMainThreadQueuesOneHeartbeatAndReportsOnce() {
        var heartbeat = MainThreadHeartbeat()
        XCTAssertTrue(heartbeat.send(at: 10))
        XCTAssertFalse(heartbeat.send(at: 11))
        XCTAssertFalse(heartbeat.shouldReport(at: 12.9))
        XCTAssertTrue(heartbeat.shouldReport(at: 13))
        XCTAssertFalse(heartbeat.shouldReport(at: 600))
        XCTAssertEqual(heartbeat.sentAt, 10)
        heartbeat.acknowledge()
        XCTAssertTrue(heartbeat.send(at: 601))
        XCTAssertTrue(heartbeat.shouldReport(at: 604))
    }

    func testHealthyHeartbeatAndClockRegressionDoNotReportStalls() {
        var heartbeat = MainThreadHeartbeat()
        XCTAssertFalse(heartbeat.shouldReport(at: 100))
        XCTAssertTrue(heartbeat.send(at: 100))
        XCTAssertFalse(heartbeat.shouldReport(at: 99))
        heartbeat.acknowledge()
        XCTAssertFalse(heartbeat.shouldReport(at: 200))
    }
}
