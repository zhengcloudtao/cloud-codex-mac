import XCTest
@testable import CloudCodex

final class UserMessagePresentationTests: XCTestCase {
    func testShortPlainTextRemainsExpanded() {
        XCTAssertFalse(UserMessagePresentation.shouldCollapse("**保持星号原文**\n# 不解析为标题"))
    }

    func testLongSingleLineDefaultsToCollapsed() {
        let text = String(repeating: "server_name example.com; ", count: 30)
        XCTAssertGreaterThan(text.count, UserMessagePresentation.collapsedCharacterLimit)
        XCTAssertTrue(UserMessagePresentation.shouldCollapse(text))
    }

    func testMessageOverEightLinesDefaultsToCollapsed() {
        let text = (1...9).map { "第 \($0) 行" }.joined(separator: "\n")
        XCTAssertTrue(UserMessagePresentation.shouldCollapse(text))
    }

    func testExactlyEightShortLinesRemainExpanded() {
        let text = (1...8).map { "第 \($0) 行" }.joined(separator: "\n")
        XCTAssertFalse(UserMessagePresentation.shouldCollapse(text))
    }
}
