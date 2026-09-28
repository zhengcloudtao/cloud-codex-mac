import Foundation
import XCTest
@testable import CloudCodex

final class FileChangePresentationTests: XCTestCase {
    func testAggregatedGitDiffBecomesPerFileChanges() {
        let diff = """
        diff --git a/A.swift b/A.swift
        --- a/A.swift
        +++ b/A.swift
        @@ -1 +1 @@
        -old
        +new
        diff --git a/New File.swift b/New File.swift
        --- /dev/null
        +++ b/New File.swift
        @@ -0,0 +1,2 @@
        +one
        +two
        """

        let changes = ConversationFileChange.parseUnifiedDiff(diff)

        XCTAssertEqual(changes.map(\.path), ["A.swift", "New File.swift"])
        XCTAssertEqual(changes.map(\.kind), [.update, .add])
        XCTAssertEqual(changes.reduce(0) { $0 + $1.addedLines }, 3)
        XCTAssertEqual(changes.reduce(0) { $0 + $1.deletedLines }, 1)
    }

    func testDiffPresentationClassifiesChangesAndTracksBothLineNumbers() {
        let lines = UnifiedDiffPresentation.lines(from: """
        diff --git a/A.swift b/A.swift
        --- a/A.swift
        +++ b/A.swift
        @@ -10,2 +20,3 @@
         same
        -old
        +new
        +extra
        """)

        XCTAssertEqual(lines.map(\.kind), [
            .metadata, .metadata, .metadata, .hunk, .context, .deletion, .addition, .addition
        ])
        XCTAssertEqual(lines[4].oldLine, 10)
        XCTAssertEqual(lines[4].newLine, 20)
        XCTAssertEqual(lines[5].oldLine, 11)
        XCTAssertNil(lines[5].newLine)
        XCTAssertNil(lines[6].oldLine)
        XCTAssertEqual(lines[6].newLine, 21)
        XCTAssertEqual(lines[7].newLine, 22)
    }

    func testSelectableDiffDocumentOmitsLineNumbersDiffMarkersAndHunkHeaders() {
        let diff = "@@ -1,2 +1,2 @@\n-old\n+new\n context"
        let lines = UnifiedDiffPresentation.lines(from: diff)

        let document = UnifiedDiffTextDocument.attributed(from: lines)

        XCTAssertEqual(document.string, "\nold\nnew\ncontext")
        XCTAssertFalse(document.string.contains("   1"))
        XCTAssertFalse(document.string.contains("@@"))
        XCTAssertFalse(document.string.contains("\n-old"))
        XCTAssertFalse(document.string.contains("\n+new"))
    }

    func testReversePatchChecksAndRestoresCurrentPostImage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudCodexFileUndo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("File With Spaces.swift")
        try Data("new\n".utf8).write(to: file)
        let change = ConversationFileChange(
            path: file.path,
            diff: "@@ -1 +1 @@\n-old\n+new",
            kind: .update
        )

        try await FileChangePatchReverter.revert([change], in: directory.path)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old\n")
    }

    func testReversePatchRefusesFilesOutsideTheConversationWorkspace() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudCodexFileUndo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let change = ConversationFileChange(
            path: "/tmp/outside.swift",
            diff: "@@ -1 +1 @@\n-old\n+new",
            kind: .update
        )

        XCTAssertThrowsError(try FileChangePatchReverter.patchText(for: [change], workspace: workspace.path))
    }

    func testReverseAggregatedPatchDoesNotDuplicateHeaders() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudCodexFileUndo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("A.swift")
        try Data("new\n".utf8).write(to: file)
        let diff = "diff --git a/A.swift b/A.swift\n--- a/A.swift\n+++ b/A.swift\n@@ -1 +1 @@\n-old\n+new"
        let changes = ConversationFileChange.parseUnifiedDiff(diff)

        try await FileChangePatchReverter.revert(changes, in: directory.path)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "old\n")
    }
}
