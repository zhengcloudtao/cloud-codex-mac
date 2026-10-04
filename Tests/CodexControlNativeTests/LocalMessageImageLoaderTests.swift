import CoreGraphics
import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
import SwiftUI
@testable import CloudCodex

final class LocalMessageImageLoaderTests: XCTestCase {
    @MainActor
    func testInlinePreviewKeepsHeightWhileBackgroundImageArrives() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("wide-preview.png")
        try writeImage(to: url, width: 2400, height: 600)
        let beforeLoads = await LocalMessageImageLoader.shared.decodeCount
        let view = NSHostingView(rootView: MarkdownImage(alt: "本地测试图片", target: url.path).frame(width: 400))
        let window = NSWindow(contentRect: CGRect(x: -4000, y: -4000, width: 400, height: 420),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        let initialHeight = view.fittingSize.height
        XCTAssertGreaterThan(initialHeight, 360)
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(20))
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(view.fittingSize.height, initialHeight, accuracy: 1)
        }
        let afterLoads = await LocalMessageImageLoader.shared.decodeCount
        XCTAssertEqual(afterLoads, beforeLoads + 1, "The mounted view must load its local image exactly once")
        XCTAssertEqual(view.fittingSize.height, initialHeight, accuracy: 1,
                       "Image decoding above the reading position must not grow/shrink the document")
    }

    func testLargeImageDecodesOnceAtPreviewResolutionAcrossRepeatedRequests() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preview.png")
        try writeImage(to: url, width: 2400, height: 1600)
        let loader = LocalMessageImageLoader()
        let first = await loader.thumbnail(at: url)
        let image = try XCTUnwrap(first)
        XCTAssertEqual(image.width, 1040)
        XCTAssertEqual(Double(image.height), 1040 * 1600 / 2400.0, accuracy: 1)
        for _ in 0..<120 {
            let next = await loader.thumbnail(at: url)
            XCTAssertTrue(next === image)
        }
        let count = await loader.decodeCount
        XCTAssertEqual(count, 1, "Scrolling/status refreshes should reuse the decoded preview")
    }

    func testReplacingAndDeletingOriginalInvalidatesCachedPreview() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("preview.png")
        try writeImage(to: url, width: 40, height: 20)
        let loader = LocalMessageImageLoader()
        let first = await loader.thumbnail(at: url)
        XCTAssertEqual(first?.width, 40)
        try writeImage(to: url, width: 30, height: 60)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        let changed = await loader.thumbnail(at: url)
        XCTAssertEqual(changed?.height, 60)
        try FileManager.default.removeItem(at: url)
        let missing = await loader.thumbnail(at: url)
        XCTAssertNil(missing)
        try writeImage(to: url, width: 25, height: 25)
        let recreated = await loader.thumbnail(at: url)
        XCTAssertEqual(recreated?.width, 25)
        let count = await loader.decodeCount
        XCTAssertEqual(count, 3)
    }

    func testUnreadableImageReturnsNoPreview() async throws {
        let directory = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: url)
        let image = await LocalMessageImageLoader().thumbnail(at: url)
        XCTAssertNil(image)
    }

    private func fixtureDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CloudCodexPreview-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeImage(to url: URL, width: Int, height: Int) throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
