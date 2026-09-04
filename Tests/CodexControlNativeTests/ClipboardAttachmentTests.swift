import AppKit
import XCTest
@testable import CloudCodex

@MainActor
final class ClipboardAttachmentTests: XCTestCase {
    func testRawPNGClipboardDataBecomesAttachment() throws {
        let model = AppModel()
        let pasteboard = NSPasteboard(name: .init("CloudCodexTests.\(UUID().uuidString)"))
        pasteboard.clearContents()

        let image = makeImage()
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let pngData = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertTrue(pasteboard.setData(pngData, forType: .png))

        XCTAssertTrue(model.pasteImages(from: pasteboard))
        let attachment = try XCTUnwrap(model.attachments.first)
        defer { try? FileManager.default.removeItem(at: attachment.url) }

        XCTAssertEqual(try Data(contentsOf: attachment.url), pngData)
        XCTAssertEqual(attachment.userInput["type"] as? String, "localImage")
    }

    func testBitmapClipboardContentBecomesPNGAttachment() throws {
        let model = AppModel()
        let pasteboard = NSPasteboard(name: .init("CloudCodexTests.\(UUID().uuidString)"))
        pasteboard.clearContents()

        let image = makeImage()
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

    func testCommandVPastesImageThroughNativeTextView() throws {
        let textView = ComposerNSTextView()
        var pasteInvocationCount = 0
        textView.pasteImages = {
            pasteInvocationCount += 1
            return true
        }
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "v",
            charactersIgnoringModifiers: "v",
            isARepeat: false,
            keyCode: 9
        ))

        XCTAssertTrue(textView.performKeyEquivalent(with: event))
        XCTAssertEqual(pasteInvocationCount, 1)
    }

    private func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 8, height: 6))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 6).fill()
        image.unlockFocus()
        return image
    }
}
