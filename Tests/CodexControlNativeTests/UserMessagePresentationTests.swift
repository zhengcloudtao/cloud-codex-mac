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

    func testCollapsedTextKeepsOnlyTheVisibleEightLines() {
        let text = (1...10).map { "第 \($0) 行" }.joined(separator: "\n")
        let collapsed = UserMessagePresentation.collapsedText(text)
        XCTAssertTrue(collapsed.hasSuffix("…"))
        XCTAssertTrue(collapsed.contains("第 8 行"))
        XCTAssertFalse(collapsed.contains("第 9 行"))
    }

    func testCollapsedTextDoesNotAlterShortMessages() {
        let text = "这条短消息应当保持原样"
        XCTAssertEqual(UserMessagePresentation.collapsedText(text), text)
    }

    func testSelectableTextRejectsNearZeroLayoutProposal() {
        XCTAssertEqual(
            ReliableSelectableText.resolvedMaximumWidth(proposedWidth: 1, naturalWidth: 360),
            360
        )
    }

    func testSelectableTextCapsLongMessageWidth() {
        XCTAssertEqual(
            ReliableSelectableText.resolvedMaximumWidth(proposedWidth: nil, naturalWidth: 1_200),
            UserMessagePresentation.maximumContentWidth
        )
    }

    func testSelectableTextLeavesRoomForBubblePadding() {
        XCTAssertEqual(UserMessagePresentation.maximumContentWidth, 692)
        XCTAssertEqual(
            ReliableSelectableText.resolvedMaximumWidth(proposedWidth: 700, naturalWidth: 1_200),
            692
        )
    }

    func testShortSingleLineUsesNaturalWidthInsteadOfProvisionalNarrowProposal() {
        XCTAssertEqual(
            ReliableSelectableText.resolvedWidth(
                proposedWidth: 260,
                naturalWidth: 345,
                hasExplicitLineBreak: false
            ),
            345
        )
    }

    func testShortChineseMessageUsesAvailableBubbleWidthInsteadOfWrappingLastGlyphs() {
        XCTAssertEqual(
            ReliableSelectableText.resolvedWidth(
                proposedWidth: 520,
                naturalWidth: 345,
                hasExplicitLineBreak: false
            ),
            520
        )
    }

    func testLongOrMultilineTextStillHonorsNarrowContainerProposal() {
        XCTAssertEqual(
            ReliableSelectableText.resolvedWidth(
                proposedWidth: 260,
                naturalWidth: 1_200,
                hasExplicitLineBreak: false
            ),
            260
        )
        XCTAssertEqual(
            ReliableSelectableText.resolvedWidth(
                proposedWidth: 260,
                naturalWidth: 345,
                hasExplicitLineBreak: true
            ),
            260
        )
    }
}
