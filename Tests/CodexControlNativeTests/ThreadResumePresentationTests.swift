import XCTest
@testable import CloudCodex

final class ThreadResumePresentationTests: XCTestCase {
    func testUnloadedSubagentExplainsParentRecoveryAndPreservesDiagnostic() {
        let raw = "cannot resume an unloaded multi-agent v2 sub-agent through its parent; resume the parent first, or use thread/read to inspect it"
        let value = ThreadResumePresentation(raw)
        XCTAssertEqual(value.title, "请先打开主会话")
        XCTAssertTrue(value.detail.contains("先打开它所属的主会话"))
        XCTAssertEqual(value.originalError, raw)
    }

    func testOtherFailureDoesNotSuggestParentRecovery() {
        let value = ThreadResumePresentation("Connection timed out")
        XCTAssertEqual(value.title, "暂时无法继续会话")
        XCTAssertFalse(value.detail.contains("主会话"))
        XCTAssertEqual(value.originalError, "Connection timed out")
    }

    func testMissingDiagnosticHasNoEmptyDetails() {
        XCTAssertNil(ThreadResumePresentation(nil).originalError)
        XCTAssertNil(ThreadResumePresentation("  \n").originalError)
    }
}
