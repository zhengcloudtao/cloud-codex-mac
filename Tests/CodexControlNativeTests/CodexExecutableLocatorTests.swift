import XCTest
@testable import CloudCodex

final class CodexExecutableLocatorTests: XCTestCase {
    func testBundledCandidatesIncludeCurrentChatGPTCLIPath() {
        XCTAssertEqual(
            CodexExecutableLocator.bundledCandidates.first,
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        )
    }

    func testLocateFallsBackToExecutableOnPATH() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudCodexLocatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appendingPathComponent("codex")
        XCTAssertTrue(FileManager.default.createFile(atPath: executable.path, contents: Data()))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: executable.path
        )

        let located = try CodexExecutableLocator.locate(
            bundledCandidates: [],
            environment: ["PATH": directory.path]
        )
        XCTAssertEqual(located.standardizedFileURL, executable.standardizedFileURL)
    }
}
