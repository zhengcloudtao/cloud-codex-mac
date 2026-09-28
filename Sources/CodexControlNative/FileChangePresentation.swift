import AppKit
import Foundation

struct ConversationFileChange: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case add, update, delete

        var label: String {
            switch self {
            case .add: return "新增"
            case .update: return "修改"
            case .delete: return "删除"
            }
        }
    }

    let path: String
    let diff: String
    let kind: Kind

    var id: String { path }
    var addedLines: Int { Self.lineCounts(in: diff).added }
    var deletedLines: Int { Self.lineCounts(in: diff).deleted }

    init(path: String, diff: String, kind: Kind) {
        self.path = path
        self.diff = diff
        self.kind = kind
    }

    init?(json: [String: Any]) {
        guard let path = json["path"] as? String, !path.isEmpty else { return nil }
        let rawKind = (json["kind"] as? [String: Any])?["type"] as? String ?? "update"
        self.init(
            path: path,
            diff: json["diff"] as? String ?? "",
            kind: Kind(rawValue: rawKind) ?? .update
        )
    }

    private static func lineCounts(in diff: String) -> (added: Int, deleted: Int) {
        var added = 0
        var deleted = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+") && !line.hasPrefix("+++") { added += 1 }
            if line.hasPrefix("-") && !line.hasPrefix("---") { deleted += 1 }
        }
        return (added, deleted)
    }

    static func parseUnifiedDiff(_ diff: String) -> [ConversationFileChange] {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var sections: [[String]] = []
        var current: [String] = []
        for line in lines {
            if line.hasPrefix("diff --git ") {
                if !current.isEmpty { sections.append(current) }
                current = [line]
            } else if !current.isEmpty {
                current.append(line)
            }
        }
        if !current.isEmpty { sections.append(current) }

        return sections.compactMap { section in
            let oldHeader = section.first(where: { $0.hasPrefix("--- ") }).map { headerPath($0, marker: "--- ") }
            let newHeader = section.first(where: { $0.hasPrefix("+++ ") }).map { headerPath($0, marker: "+++ ") }
            let kind: Kind = oldHeader == "/dev/null" ? .add : (newHeader == "/dev/null" ? .delete : .update)
            let rawPath = kind == .delete ? oldHeader : newHeader
            guard var path = rawPath, path != "/dev/null", !path.isEmpty else { return nil }
            if path.hasPrefix("a/") || path.hasPrefix("b/") { path.removeFirst(2) }
            return ConversationFileChange(path: path, diff: section.joined(separator: "\n"), kind: kind)
        }
    }

    private static func headerPath(_ line: String, marker: String) -> String {
        var path = String(line.dropFirst(marker.count))
        if let tab = path.firstIndex(of: "\t") { path = String(path[..<tab]) }
        if path.hasPrefix("\"") && path.hasSuffix("\"") {
            path.removeFirst()
            path.removeLast()
            path = path.replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        return path
    }
}

struct ConversationFileChangeGroup: Identifiable, Hashable {
    let turnID: String
    let changes: [ConversationFileChange]

    var id: String { "file-changes:\(turnID)" }
    var addedLines: Int { changes.reduce(0) { $0 + $1.addedLines } }
    var deletedLines: Int { changes.reduce(0) { $0 + $1.deletedLines } }
    var combinedDiff: String {
        changes.map { change in
            "# \(change.kind.label) \(change.path)\n\(change.diff)"
        }.joined(separator: "\n\n")
    }

    init(turnID: String, changes: [ConversationFileChange]) {
        self.turnID = turnID
        var order: [String] = []
        var merged: [String: ConversationFileChange] = [:]
        for change in changes {
            if merged[change.path] == nil { order.append(change.path) }
            if let previous = merged[change.path], !previous.diff.isEmpty, !change.diff.isEmpty {
                merged[change.path] = ConversationFileChange(
                    path: change.path,
                    diff: previous.diff + "\n" + change.diff,
                    kind: change.kind
                )
            } else {
                merged[change.path] = change
            }
        }
        self.changes = order.compactMap { merged[$0] }
    }
}

enum FileChangePatchReverter {
    enum RevertError: LocalizedError {
        case emptyPatch
        case invalidWorkspace
        case pathOutsideWorkspace(String)
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .emptyPatch: return "这个修改记录没有可用于撤销的差异。"
            case .invalidWorkspace: return "当前会话的工作区不存在，无法安全撤销。"
            case .pathOutsideWorkspace(let path): return "文件不在当前工作区内，已停止撤销：\(path)"
            case .commandFailed(let detail): return "无法撤销这些修改。文件可能在本轮之后又被改过。\(detail.isEmpty ? "" : "\n\(detail)")"
            }
        }
    }

    static func revert(_ changes: [ConversationFileChange], in workspace: String) async throws {
        let patch = try patchText(for: changes, workspace: workspace)
        try await Task.detached(priority: .userInitiated) {
            let check = try runGitApply(patch: patch, workspace: workspace, checkOnly: true)
            guard check.status == 0 else { throw RevertError.commandFailed(check.output) }
            let apply = try runGitApply(patch: patch, workspace: workspace, checkOnly: false)
            guard apply.status == 0 else { throw RevertError.commandFailed(apply.output) }
        }.value
    }

    static func patchText(for changes: [ConversationFileChange], workspace: String) throws -> String {
        let workspaceURL = URL(fileURLWithPath: workspace).standardizedFileURL
        guard FileManager.default.fileExists(atPath: workspaceURL.path) else { throw RevertError.invalidWorkspace }
        let sections = try changes.compactMap { change -> String? in
            guard !change.diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let relativePath = try relativePath(change.path, workspace: workspaceURL)
            if change.diff.hasPrefix("diff --git ") { return change.diff }
            let oldPath = change.kind == .add ? "/dev/null" : "a/\(relativePath)"
            let newPath = change.kind == .delete ? "/dev/null" : "b/\(relativePath)"
            return "diff --git a/\(relativePath) b/\(relativePath)\n--- \(oldPath)\n+++ \(newPath)\n\(change.diff)"
        }
        guard !sections.isEmpty else { throw RevertError.emptyPatch }
        return sections.joined(separator: "\n") + "\n"
    }

    private static func relativePath(_ path: String, workspace: URL) throws -> String {
        let standardized: URL
        if path.hasPrefix("/") {
            standardized = URL(fileURLWithPath: path).standardizedFileURL
        } else {
            standardized = workspace.appendingPathComponent(path).standardizedFileURL
        }
        let prefix = workspace.path.hasSuffix("/") ? workspace.path : workspace.path + "/"
        guard standardized.path.hasPrefix(prefix) else { throw RevertError.pathOutsideWorkspace(path) }
        return String(standardized.path.dropFirst(prefix.count))
    }

    private static func runGitApply(
        patch: String,
        workspace: String,
        checkOnly: Bool
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = URL(fileURLWithPath: workspace)
        process.arguments = ["apply", "--reverse", "--whitespace=nowarn"] + (checkOnly ? ["--check"] : []) + ["-"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data(patch.utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}

struct DiffDisplayLine: Identifiable, Hashable {
    enum Kind: Hashable {
        case metadata, hunk, context, addition, deletion
    }

    let id: Int
    let text: String
    let oldLine: Int?
    let newLine: Int?
    let kind: Kind
}

enum UnifiedDiffPresentation {
    static func lines(from diff: String) -> [DiffDisplayLine] {
        var oldLine: Int?
        var newLine: Int?
        return diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, raw in
            let text = String(raw)
            if text.hasPrefix("@@"), let starts = hunkStarts(text) {
                oldLine = starts.old
                newLine = starts.new
                return .init(id: index, text: text, oldLine: nil, newLine: nil, kind: .hunk)
            }
            if text.hasPrefix("+") && !text.hasPrefix("+++") {
                let line = DiffDisplayLine(id: index, text: text, oldLine: nil, newLine: newLine, kind: .addition)
                newLine = newLine.map { $0 + 1 }
                return line
            }
            if text.hasPrefix("-") && !text.hasPrefix("---") {
                let line = DiffDisplayLine(id: index, text: text, oldLine: oldLine, newLine: nil, kind: .deletion)
                oldLine = oldLine.map { $0 + 1 }
                return line
            }
            if text.hasPrefix(" ") {
                let line = DiffDisplayLine(id: index, text: text, oldLine: oldLine, newLine: newLine, kind: .context)
                oldLine = oldLine.map { $0 + 1 }
                newLine = newLine.map { $0 + 1 }
                return line
            }
            return .init(id: index, text: text, oldLine: nil, newLine: nil, kind: .metadata)
        }
    }

    private static func hunkStarts(_ line: String) -> (old: Int, new: Int)? {
        guard let oldMarker = line.range(of: "@@ -"),
              let separator = line.range(of: " +", range: oldMarker.upperBound..<line.endIndex) else { return nil }
        let oldPart = line[oldMarker.upperBound..<separator.lowerBound]
        let newStart = separator.upperBound
        guard let newEnd = line[newStart...].firstIndex(where: { $0 == "," || $0 == " " }),
              let old = Int(oldPart.split(separator: ",").first ?? ""),
              let new = Int(line[newStart..<newEnd]) else { return nil }
        return (old, new)
    }
}

enum UnifiedDiffTextDocument {
    static func attributed(from lines: [DiffDisplayLine]) -> NSAttributedString {
        let document = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = 22
        paragraph.maximumLineHeight = 22

        for (index, line) in lines.enumerated() {
            let lineBreak = index < lines.count - 1 ? "\n" : ""
            document.append(NSAttributedString(
                string: selectableText(for: line) + lineBreak,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: foregroundColor(for: line.kind),
                    .paragraphStyle: paragraph
                ]
            ))
        }
        return document
    }

    private static func selectableText(for line: DiffDisplayLine) -> String {
        switch line.kind {
        case .addition, .deletion, .context:
            return String(line.text.dropFirst())
        case .hunk:
            return ""
        case .metadata:
            return line.text
        }
    }

    private static func foregroundColor(for kind: DiffDisplayLine.Kind) -> NSColor {
        switch kind {
        case .addition: return .systemGreen
        case .deletion: return .systemRed
        case .hunk: return .systemBlue
        case .metadata: return .secondaryLabelColor
        case .context: return .labelColor
        }
    }
}
