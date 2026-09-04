import AppKit
import XCTest
@testable import CloudCodex

@MainActor
final class ClipboardAttachmentTests: XCTestCase {
    func testBitmapClipboardContentBecomesPNGAttachment() throws {
        let model = AppModel()
        let pasteboard = NSPasteboard(name: .init("CloudCodexTests.\(UUID().uuidString)"))
        pasteboard.clearContents()

        let image = NSImage(size: NSSize(width: 8, height: 6))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 6).fill()
        image.unlockFocus()
        XCTAssertTrue(pasteboard.writeObjects([image]))

        XCTAssertTrue(model.pasteImages(from: pasteboard))
        let attachment = try XCTUnwrap(model.attachments.first)
        defer { try? FileManager.default.removeItem(at: attachment.url) }

        XCTAssertTrue(attachment.isImage)
        XCTAssertEqual(attachment.url.pathExtension, "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.url.path))
        XCTAssertNotNil(NSImage(contentsOf: attachment.url))
        XCTAssertEqual(attachment.userInput["type"] as? String, "localImage")
        XCTAssertEqual(attachment.userInput["path"] as? String, attachment.url.path)
    }

    func testCopiedImageFileUsesExistingAttachmentPathWithoutDuplicates() throws {
        let model = AppModel()
        let pasteboard = NSPasteboard(name: .init("CloudCodexTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        let imageURL = URL(fileURLWithPath: "/tmp/cloudcodex-copied-image.png")
        XCTAssertTrue(pasteboard.writeObjects([imageURL as NSURL]))

        XCTAssertTrue(model.pasteImages(from: pasteboard))
        XCTAssertTrue(model.pasteImages(from: pasteboard))
        XCTAssertEqual(model.attachments.map(\.url), [imageURL])
    }

    func testTextClipboardContentIsLeftForTextEditor() {
        let model = AppModel()
        let pasteboard = NSPasteboard(name: .init("CloudCodexTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("普通文字", forType: .string)

        XCTAssertFalse(model.pasteImages(from: pasteboard))
        XCTAssertTrue(model.attachments.isEmpty)
        XCTAssertNil(model.errorMessage)
    }
}
