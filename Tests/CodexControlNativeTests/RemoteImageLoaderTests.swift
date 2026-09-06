import XCTest
@testable import CloudCodex

final class RemoteImageLoaderTests: XCTestCase {
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!

    func testInlineDataPreservesImageBytes() throws {
        let attachment = try RemoteImageLoader.inlineAttachment(png)
        XCTAssertEqual(attachment.userInput["type"] as? String, "image")
        let value = try XCTUnwrap(attachment.userInput["url"] as? String)
        XCTAssertTrue(value.hasPrefix("data:image/png;base64,"))
        XCTAssertEqual(Data(base64Encoded: String(value.split(separator: ",")[1])), png)
        XCTAssertNil(attachment.userInput["path"])
    }

    func testRejectsInvalidContentAndUnsafeURLs() {
        for data in [Data(), Data("<html>Access denied</html>".utf8), Data(repeating: 0, count: RemoteImageLoader.maxBytes + 1)] {
            XCTAssertThrowsError(try RemoteImageLoader.inlineAttachment(data))
        }
        for value in ["http://example.com/a.png", "file:///tmp/a.png", "https://localhost/a.png", "https://127.0.0.1/a.png", "https://user:password@example.com/a.png", "https://example.com:8080/a.png"] {
            XCTAssertThrowsError(try RemoteImageLoader.imageURL(value))
        }
        XCTAssertNoThrow(try RemoteImageLoader.imageURL("https://example.com/image?id=1"))
    }

    func testEmptyAndTooManyImages() async throws {
        let empty = try await RemoteImageLoader.attachments([])
        XCTAssertTrue(empty.isEmpty)
        do {
            _ = try await RemoteImageLoader.attachments(Array(repeating: "https://example.com/image.png", count: 5))
            XCTFail("must reject before downloading")
        } catch { XCTAssertTrue(error.localizedDescription.contains("4 张")) }
    }

    func testDownloadConversionAndHTTPFailuresWithLocalMocks() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let images = try await RemoteImageLoader.attachments(["https://example.com/ok"], session: session)
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0].userInput["url"] as? String, "data:image/png;base64," + png.base64EncodedString())
        for path in ["denied", "oversized", "html"] {
            do {
                _ = try await RemoteImageLoader.attachments(["https://example.com/\(path)?private-query=redacted"], session: session)
                XCTFail("must reject \(path)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("第 1 张图片"))
                XCTAssertFalse(error.localizedDescription.contains("private-query"))
            }
        }
    }
}

private final class ImageFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        let path = request.url!.lastPathComponent
        let data = path == "html" ? Data("<html>expired</html>".utf8) : Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!
        let length = path == "oversized" ? RemoteImageLoader.maxBytes + 1 : data.count
        let response = HTTPURLResponse(url: request.url!, statusCode: path == "denied" ? 403 : 200, httpVersion: nil,
                                       headerFields: ["Content-Length": String(length), "Content-Type": "application/octet-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
