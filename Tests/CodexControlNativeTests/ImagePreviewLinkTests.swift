import XCTest
@testable import CloudCodex

final class ImagePreviewLinkTests: XCTestCase {
    func testCompletedGenerationUsesProtocolSavedPath() {
        let item: [String: Any] = ["id": "image-task", "type": "imageGeneration", "status": "completed", "savedPath": "/tmp/result.png"]
        let message = GeneratedImageMessage.fromItem(item)
        XCTAssertEqual(message?.id, "image-task-generated-image")
        XCTAssertEqual(message?.role, .assistant)
        XCTAssertEqual(MarkdownBlockParser.parse(message?.text ?? ""), [.image(alt: "生成的图片", target: "</tmp/result.png>")])
        XCTAssertNil(GeneratedImageMessage.fromItem(["id": "x", "type": "imageGeneration", "status": "inProgress", "savedPath": "/tmp/result.png"]))
    }
    func testGeneratedPNGLinkGetsPreviewAndKeepsOriginalLink() {
        let text = "- [透明背景 PNG 原图](</tmp/Java 工作台/icon.png>)"
        XCTAssertEqual(MarkdownBlockParser.parse(text), [
            .bullet("[透明背景 PNG 原图](</tmp/Java 工作台/icon.png>)"),
            .image(alt: "透明背景 PNG 原图", target: "/tmp/Java 工作台/icon.png")
        ])
    }
    func testOnlyLocalImagesAreAutomaticallyPreviewed() {
        XCTAssertTrue(ImagePreviewLink.previews(in: "[网页](https://example.com/a.png) [应用](/tmp/a.app) [文档](/tmp/a.md)").isEmpty)
        XCTAssertEqual(ImagePreviewLink.previews(in: "[图片](file:///tmp/a%20b.png)"), [.image(alt: "图片", target: "/tmp/a b.png")])
        XCTAssertNil(ImagePreviewLink.localURL("file://server/share/a.png"))
    }
    func testCodeIsNotPreviewedAndDuplicateLinksPreviewOnce() {
        XCTAssertEqual(MarkdownBlockParser.parse("```\n[图片](/tmp/a.png)\n```"), [.code(language: nil, text: "[图片](/tmp/a.png)")])
        let blocks = MarkdownBlockParser.parse("- [原图](/tmp/a.png)\n- [下载](/tmp/a.png)")
        XCTAssertEqual(blocks.filter { if case .image = $0 { return true }; return false }.count, 1)
    }
}
