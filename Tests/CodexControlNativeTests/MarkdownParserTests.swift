import XCTest
@testable import CloudCodex

final class MarkdownParserTests: XCTestCase {
    func testCommonMarkdownBlocksAreParsed() {
        let markdown = """
        # 标题

        普通段落包含 **粗体**、`代码` 和 [链接](https://example.com)。

        - 第一项
        1. 第二项

        > 引用内容

        ```bash
        git status
        ```

        | 名称 | 状态 |
        | --- | --- |
        | CloudCodex | 完成 |
        """

        let blocks = MarkdownBlockParser.parse(markdown)
        XCTAssertTrue(blocks.contains(.heading(level: 1, text: "标题")))
        XCTAssertTrue(blocks.contains(.bullet("第一项")))
        XCTAssertTrue(blocks.contains(.numbered(number: 1, text: "第二项")))
        XCTAssertTrue(blocks.contains(.quote("引用内容")))
        XCTAssertTrue(blocks.contains(.code(language: "bash", text: "git status")))
        XCTAssertTrue(blocks.contains(.table(headers: ["名称", "状态"], rows: [["CloudCodex", "完成"]])))
    }

    func testUnclosedStreamingCodeFenceStillRendersAsCode() {
        let blocks = MarkdownBlockParser.parse("```swift\nlet value = 1")
        XCTAssertEqual(blocks, [.code(language: "swift", text: "let value = 1")])
    }

    func testStandaloneLocalImageIsParsed() {
        let blocks = MarkdownBlockParser.parse("![截图](/tmp/example.png)")
        XCTAssertEqual(blocks, [.image(alt: "截图", target: "/tmp/example.png")])
    }
}
