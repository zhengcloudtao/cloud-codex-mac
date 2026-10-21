import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import CloudCodex

final class RemoteHistoryTests: XCTestCase {
    private func imageData(width: Int = 20, height: Int = 30) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return bytes as Data
    }

    func testGeneratedImagesAndUserImagesRemainInAuthorizedHistory() throws {
        let data = try imageData()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let generated = (0..<4).map { ["id": "image-\($0)", "type": "imageGeneration", "status": "completed", "savedPath": file.path] }
        let items: [[String: Any]] = [
            ["id": "user", "type": "userMessage", "content": [["type": "localImage", "path": file.path]]]
        ] + generated + [["id": "answer", "type": "agentMessage", "text": "已生成四款企鹅"]]
        let page = AppServerClient.remoteHistoryPage(["data": [["id": "turn", "items": items]]])
        XCTAssertEqual(page.messages.count, 6)
        XCTAssertEqual(page.messages.first?.role, "user")
        XCTAssertEqual(page.messages.compactMap(\.images).flatMap { $0 }.count, 5)
        XCTAssertEqual(page.messages.filter { $0.role == "assistant" && $0.images != nil }.count, 4)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(page), as: UTF8.self).contains(file.path))
        for image in page.messages.compactMap(\.images).flatMap({ $0 }) {
            XCTAssertEqual(image.mimeType, "image/png")
            let bytes = try XCTUnwrap(Data(base64Encoded: image.data))
            XCTAssertLessThanOrEqual(bytes.count, RemoteHistoryImageEncoder.maxImageBytes)
            XCTAssertNotNil(CGImageSourceCreateWithData(bytes as CFData, nil))
        }
        XCTAssertEqual(page.messages.last?.text, "已生成四款企鹅")
    }

    func testImageBudgetFailureAndNoArbitraryMarkdownFileReads() throws {
        let encoded = "data:image/png;base64," + (try imageData()).base64EncodedString()
        let content = (0..<10).map { _ in ["type": "image", "url": encoded] }
        let page = AppServerClient.remoteHistoryPage(["data": [["id": "turn", "items": [
            ["id": "user", "type": "userMessage", "content": content],
            ["id": "missing", "type": "imageGeneration", "status": "completed", "savedPath": "/missing/image.png"],
            ["id": "answer", "type": "agentMessage", "text": "![文本链接](/private/example.png)"]
        ]]]])
        XCTAssertEqual(page.messages.first?.images?.count, 8)
        XCTAssertTrue(page.messages.first?.text.contains("请在 Mac 查看原图") == true)
        XCTAssertTrue(page.messages[1].text.contains("暂时无法同步"))
        XCTAssertNil(page.messages.last?.images, "plain Markdown must never trigger arbitrary local file reads")
        XCTAssertNil(RemoteHistoryImageEncoder.encode("https://example.test/image.png", name: "图片"))
        XCTAssertNil(RemoteHistoryImageEncoder.encode("data:image/png;base64,invalid", name: "图片"))
        let big = "data:image/png;base64," + (try imageData(width: 2000, height: 1000)).base64EncodedString()
        let image = try XCTUnwrap(RemoteHistoryImageEncoder.encode(big, name: "图片"))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(try XCTUnwrap(Data(base64Encoded: image.data)) as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertLessThanOrEqual(try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int), 1600)
    }

    func testGeneratedImageResultSurvivesMissingOriginalFile() throws {
        let page = AppServerClient.remoteHistoryPage(["data": [["id": "turn", "items": [
            ["id": "generated", "type": "imageGeneration", "status": "completed",
             "savedPath": "/missing/original.png", "result": (try imageData()).base64EncodedString()]
        ]]]])
        XCTAssertEqual(page.messages.first?.images?.count, 1)
        XCTAssertFalse(page.messages.first?.text.contains("无法同步") == true)
    }

    func testCompleteTextChronologyCursorAndPublicContentOnly() {
        let long = String(repeating: "完整回答", count: 20000)
        let response: [String: Any] = ["nextCursor": "older-cursor", "data": [
            ["id": "new", "startedAt": 123, "items": [
                ["id": "u", "type": "userMessage", "content": [["type": "text", "text": "问题"], ["type": "image", "url": "data:image/png;base64,private"]]],
                ["id": "r", "type": "reasoning", "summary": ["公开摘要"], "content": ["private-reasoning"]],
                ["id": "tool", "type": "mcpToolCall", "tool": "search", "arguments": ["private": "secret"]],
                ["id": "a", "type": "agentMessage", "text": long]
            ]],
            ["id": "old", "items": [["id": "old-a", "type": "agentMessage", "text": "较早回答"]]]
        ]]
        let page = AppServerClient.remoteHistoryPage(response, metadata: ["new": TurnModelMetadata(model: "test-model", reasoningEffort: "high")])
        XCTAssertEqual(page.nextCursor, "older-cursor")
        XCTAssertEqual(page.messages.first?.text, "较早回答")
        XCTAssertEqual(page.messages.last?.text, long)
        XCTAssertEqual(page.messages.last?.model, "test-model")
        XCTAssertFalse(page.messages.map(\.text).joined().contains("private"))
        XCTAssertTrue(page.messages.contains { $0.role == "user" && $0.text.contains("问题") && $0.text.contains("图片附件") })
    }
}
