import AppKit
import XCTest
@testable import CloudCodex

final class MarkdownLinkRoutingTests: XCTestCase {
    func testRenderedAbsoluteMarkdownPathRoutesToCloudCodexPreview() throws {
        let markdown = "[打开游戏客户端前端多语言改造说明.md](</Users/zhengyuntao/coding/webx/Ole Game/源码/game-all/docs/游戏客户端前端多语言改造说明.md>)"
        let rendered = MarkdownTextDocument.appKitAttributed(from: [.paragraph(markdown)])
        let link = try XCTUnwrap(rendered.attribute(.link, at: 0, effectiveRange: nil))
        var openedURL: URL?
        let coordinator = ReliableSelectableAttributedText.Coordinator { openedURL = $0 }

        XCTAssertTrue(coordinator.textView(NSTextView(), clickedOnLink: link, at: 0))
        XCTAssertEqual(
            openedURL?.path,
            "/Users/zhengyuntao/coding/webx/Ole Game/源码/game-all/docs/游戏客户端前端多语言改造说明.md"
        )
    }

    func testNativeTextLinkUsesCloudCodexOpenURLAction() throws {
        var openedURL: URL?
        let coordinator = ReliableSelectableAttributedText.Coordinator { openedURL = $0 }
        let encodedPath = "/tmp/My%20Project/guide.md"

        XCTAssertTrue(coordinator.textView(NSTextView(), clickedOnLink: encodedPath, at: 0))
        XCTAssertEqual(openedURL?.path, "/tmp/My Project/guide.md")
    }

    func testUnknownNativeTextLinkFallsBackToAppKit() {
        let coordinator = ReliableSelectableAttributedText.Coordinator { _ in
            XCTFail("An unsupported link value must not be opened")
        }

        XCTAssertFalse(coordinator.textView(NSTextView(), clickedOnLink: NSObject(), at: 0))
    }
}
