import XCTest
import AppKit
import Quartz
@testable import CloudCodex

final class LocalFilePreviewTests: XCTestCase {
    @MainActor
    func testPreviewWindowCanCloseAndReopenWithQuickLookContent() throws {
        _ = NSApplication.shared
        let controller = LocalFilePreviewWindowController()
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        image.unlockFocus()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tiff")
        try XCTUnwrap(image.tiffRepresentation).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        for _ in 0..<3 {
            controller.show(LocalFilePreviewTarget(url: url))
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let window = try XCTUnwrap(NSApplication.shared.windows.first {
                $0.title == url.lastPathComponent && $0.isVisible
            })
            func findPreview(_ view: NSView) -> QLPreviewView? {
                if let preview = view as? QLPreviewView { return preview }
                return view.subviews.lazy.compactMap { findPreview($0) }.first
            }
            let preview = try XCTUnwrap(findPreview(try XCTUnwrap(window.contentView)))
            XCTAssertFalse(preview.shouldCloseWithWindow)
            XCTAssertTrue(window.styleMask.contains(.resizable))
            window.performClose(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            XCTAssertFalse(window.isVisible)
        }
    }

    func testMarkdownExtensionsUseFormattedPreview() {
        XCTAssertTrue(LocalFilePreviewTarget(url: URL(fileURLWithPath: "/tmp/README.md")).isMarkdown)
        XCTAssertTrue(LocalFilePreviewTarget(url: URL(fileURLWithPath: "/tmp/Guide.MARKDOWN")).isMarkdown)
        XCTAssertFalse(LocalFilePreviewTarget(url: URL(fileURLWithPath: "/tmp/schema.sql")).isMarkdown)
    }

    func testAbsolutePathWithSpacesAndLineNumber() throws {
        let url = try XCTUnwrap(URL(string: "/tmp/My%20Project/seed.sql:12:3"))
        XCTAssertEqual(LocalFilePreviewTarget.resolve(url, cwd: nil)?.url.path, "/tmp/My Project/seed.sql")
    }

    func testRelativeFileUsesConversationWorkspace() throws {
        let url = try XCTUnwrap(URL(string: "scripts/seed.sql"))
        XCTAssertEqual(LocalFilePreviewTarget.resolve(url, cwd: "/tmp/project")?.url.path, "/tmp/project/scripts/seed.sql")
        XCTAssertNil(LocalFilePreviewTarget.resolve(url, cwd: nil))
    }

    func testWebAndRemoteFileURLsAreNotLocalPreviews() throws {
        for value in ["https://example.com/file.sql", "file://remote/share/file.sql", "mailto:test@example.com"] {
            XCTAssertNil(LocalFilePreviewTarget.resolve(try XCTUnwrap(URL(string: value)), cwd: "/tmp"))
        }
        XCTAssertEqual(LocalFilePreviewTarget.resolve(URL(fileURLWithPath: "/tmp/seed.sql"), cwd: nil)?.url.path, "/tmp/seed.sql")
    }

    func testReadsTextWithoutExecutingAndReportsMissingFile() throws {
        let source = URL(fileURLWithPath: #filePath)
        let text = try XCTUnwrap(LocalFilePreviewTarget.readText(source))
        XCTAssertTrue(text.contains("final class LocalFilePreviewTests"))
        XCTAssertThrowsError(try LocalFilePreviewTarget.readText(source.appendingPathComponent("missing.sql")))
    }
}
