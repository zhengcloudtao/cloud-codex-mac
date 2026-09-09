import XCTest
@testable import CloudCodex

final class LocalFilePreviewTests: XCTestCase {
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
