import XCTest
@testable import CloudCodex

final class ThreadWriterPresenceTests: XCTestCase {
    func testOnlyExternalLockHoldersCount() {
        let folder = URL(fileURLWithPath: "/tmp/writers")
        let id = "01a173fa-d980-70f0-9334-a5ed2d592d2a"
        let other = "01a17615-464b-7c20-9e0f-075cbdd17ee2"
        let text = "p100\nf4\nk1\nn/tmp/writers/\(id).lock\np200\nf8\nkW\nn/tmp/writers/\(other).lock\nf9\nn/tmp/writers/\(id).lock\nf10\nk1\nn/tmp/writers/.coordination.lock\nf11\nk1\nn/tmp/elsewhere/\(id).lock\n"
        XCTAssertEqual(ThreadWriterPresence.parse(text, folder: folder, ownPID: 100), [other])
        XCTAssertTrue(ThreadWriterPresence.parse("", folder: folder, ownPID: 100).isEmpty)
    }

    @MainActor
    func testUnselectedRowsUpdateAndReleaseWithoutChangingOutcome() {
        let model = AppModel()
        model.selectedThreadID = "another"
        model.handleEvent("turn/completed", ["threadId": "external", "turn": ["id": "turn", "status": "interrupted"]])
        model.applyWriterPresence(["external"])
        XCTAssertTrue(model.isThreadOpenedElsewhere("external"))
        XCTAssertFalse(model.isThreadOpenedElsewhere("another"))
        XCTAssertEqual(model.threadOutcomes["external"], .interrupted)
        model.applyWriterPresence([])
        XCTAssertFalse(model.isThreadOpenedElsewhere("external"))
        XCTAssertEqual(model.selectedThreadID, "another")
    }
}
