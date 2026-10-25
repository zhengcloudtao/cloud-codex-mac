import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import CloudCodex

final class StartupAnimationTests: XCTestCase {
    func testForegroundKeepsEntireImageInsideDifferentWindowShapes() {
        let image = CGSize(width: 960, height: 540)
        for container in [CGSize(width: 1220, height: 780), CGSize(width: 1140, height: 900),
                          CGSize(width: 1800, height: 640), CGSize(width: 680, height: 500)] {
            let size = StartupAnimationLayout.fittedSize(image: image, container: container)
            XCTAssertLessThanOrEqual(size.width, container.width + 0.001)
            XCTAssertLessThanOrEqual(size.height, container.height + 0.001)
            XCTAssertEqual(size.width / size.height, 16.0 / 9.0, accuracy: 0.001)
            XCTAssertTrue(abs(size.width - container.width) < 0.001 || abs(size.height - container.height) < 0.001)
        }
    }

    func testFillCoversWindowWithoutStretching() {
        let wide = StartupAnimationLayout.filledSize(image: CGSize(width: 960, height: 540),
                                                     container: CGSize(width: 1220, height: 780))
        XCTAssertEqual(wide.height, 780, accuracy: 0.001)
        XCTAssertGreaterThan(wide.width, 1220)
        XCTAssertEqual(wide.width / wide.height, 16.0 / 9.0, accuracy: 0.001)
        let tall = StartupAnimationLayout.filledSize(image: CGSize(width: 540, height: 960),
                                                     container: CGSize(width: 1220, height: 780))
        XCTAssertEqual(tall.width, 1220, accuracy: 0.001)
        XCTAssertGreaterThan(tall.height, 780)
    }

    func testDurationIsBoundedAndHandlesCorruptPreferences() {
        XCTAssertEqual(StartupAnimationPreference.duration(-1), 1)
        XCTAssertEqual(StartupAnimationPreference.duration(30), 10)
        XCTAssertEqual(StartupAnimationPreference.duration(.nan), 3)
        XCTAssertEqual(StartupAnimationPreference.duration(.infinity), 3)
        XCTAssertEqual(StartupAnimationPreference.duration(4.5), 4.5)
    }

    @MainActor func testStartupCanOnlyBeClaimedOncePerSession() {
        let session = StartupAnimationSession()
        XCTAssertTrue(session.claim())
        XCTAssertFalse(session.claim())
        XCTAssertFalse(session.claim())
        XCTAssertTrue(StartupAnimationSession().claim())
    }

    func testImportCopiesAnimatedGIFAndFailedReplacementPreservesIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.gif")
        let destination = root.appendingPathComponent("personalization")
        try makeGIF(at: source, frames: 2)
        let original = try Data(contentsOf: source)
        let imported = try StartupAnimationStore.importAnimation(from: source, directory: destination)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: imported)), original)
        try Data("not a GIF".utf8).write(to: source)
        XCTAssertThrowsError(try StartupAnimationStore.importAnimation(from: source, directory: destination))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: imported)), original)
        try makeGIF(at: source, frames: 1)
        XCTAssertThrowsError(try StartupAnimationStore.validatedData(from: source))
        XCTAssertThrowsError(try StartupAnimationStore.validatedData(from: root.appendingPathComponent("missing.gif")))
    }

    private func makeGIF(at url: URL, frames: Int) throws {
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil))
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for index in 0..<frames {
            context.setFillColor(CGColor(red: CGFloat(index), green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
