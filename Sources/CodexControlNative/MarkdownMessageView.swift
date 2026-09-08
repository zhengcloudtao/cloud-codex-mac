import AppKit
import Foundation
import SwiftUI

struct MarkdownMessageView: View, Equatable {
    let markdown: String
    let expandsHorizontally: Bool

    init(markdown: String, expandsHorizontally: Bool = true) {
        self.markdown = markdown
        self.expandsHorizontally = expandsHorizontally
    }

    private var blocks: [MarkdownBlock] {
        MarkdownBlockParser.parse(markdown)
    }

    var body: some View {
        MarkdownBlocksView(blocks: blocks, expandsHorizontally: expandsHorizontally)
    }
}

/// Parse a bounded preview away from the main actor. Cancellation and the
/// task identity prevent a slow older parse from replacing newer output.
struct StreamingMarkdownContent: View {
    let text: String
    @State private var blocks: [MarkdownBlock] = []
    @State private var isTruncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isTruncated {
                Text("正在生成，仅预览最新内容；完整内容在完成后可查看")
                    .font(.caption).foregroundStyle(.secondary)
            }
            MarkdownBlocksView(blocks: blocks, expandsHorizontally: true).equatable()
        }
        .task(id: text) {
            let input = text
            let parsed = await Task.detached(priority: .userInitiated) {
                let preview = StreamingMarkdownWindow.preview(input)
                return (MarkdownBlockParser.parse(preview.markdown), preview.isTruncated)
            }.value
            guard !Task.isCancelled else { return }
            blocks = parsed.0
            isTruncated = parsed.1
        }
    }
}

enum StreamingMarkdownWindow {
    static func preview(_ text: String, limit: Int = 6_000) -> (markdown: String, isTruncated: Bool) {
        guard text.count > limit else { return (text, false) }
        var start = text.index(text.endIndex, offsetBy: -limit)
        // Do not start half way through a bullet, link or Markdown delimiter.
        if let newline = text[start...].firstIndex(of: "\n") {
            start = text.index(after: newline)
        }
        var openFence: String?
        text[..<start].enumerateLines { line, _ in
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                openFence = openFence == nil ? line : nil
            }
        }
        let prefix = openFence.map { $0 + "\n" } ?? ""
        return (prefix + text[start...], true)
    }
}

private struct MarkdownBlocksView: View, Equatable {
    let blocks: [MarkdownBlock]
    let expandsHorizontally: Bool

    @ViewBuilder
    var body: some View {
        let content = VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)

        if expandsHorizontally {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content.fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            InlineMarkdownText(text: text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 4 : 1)
        case .paragraph(let text):
            InlineMarkdownText(text: text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").font(.body.weight(.semibold))
                InlineMarkdownText(text: text).font(.body)
            }
        case .numbered(let number, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number).")
                    .font(.body.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                InlineMarkdownText(text: text).font(.body)
            }
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.65))
                    .frame(width: 3)
                InlineMarkdownText(text: text)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        case .code(let language, let code):
            MarkdownCodeBlock(language: language, code: code)
        case .rule:
            Divider().padding(.vertical, 3)
        case .table(let headers, let rows):
            MarkdownTable(headers: headers, rows: rows)
        case .image(let alt, let target):
            MarkdownImage(alt: alt, target: target)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.bold)
        case 2: return .title3.weight(.bold)
        case 3: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }
}

private struct InlineMarkdownText: View {
    let text: String

    var body: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
        } else {
            Text(text)
        }
    }
}

private struct MarkdownCodeBlock: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.035))
                Divider().opacity(0.45)
            }
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(12)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
    }
}

private struct MarkdownTable: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(headers.indices, id: \.self) { index in
                        MarkdownTableCell(text: headers[index], emphasized: true)
                    }
                }
                ForEach(rows.indices, id: \.self) { rowIndex in
                    GridRow {
                        ForEach(headers.indices, id: \.self) { columnIndex in
                            MarkdownTableCell(
                                text: columnIndex < rows[rowIndex].count ? rows[rowIndex][columnIndex] : "",
                                emphasized: false
                            )
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }
}

private struct MarkdownTableCell: View {
    let text: String
    let emphasized: Bool

    var body: some View {
        InlineMarkdownText(text: text)
            .font(emphasized ? .callout.weight(.semibold) : .callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minWidth: 90, maxWidth: 260, alignment: .leading)
            .background(emphasized ? Color.secondary.opacity(0.12) : Color.clear)
            .overlay(Rectangle().stroke(Color.secondary.opacity(0.13), lineWidth: 0.5))
    }
}

private struct MarkdownImage: View {
    let alt: String
    let target: String

    var body: some View {
        Group {
            if target.hasPrefix("/"), let image = NSImage(contentsOfFile: target) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if let url = URL(string: target), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else if phase.error != nil {
                        imageFallback
                    } else {
                        ProgressView().frame(height: 100)
                    }
                }
            } else {
                imageFallback
            }
        }
        .frame(maxWidth: 520, maxHeight: 360, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        .help(alt.isEmpty ? target : alt)
    }

    private var imageFallback: some View {
        Label(alt.isEmpty ? target : alt, systemImage: "photo")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(12)
    }
}

enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case numbered(number: Int, text: String)
    case quote(String)
    case code(language: String?, text: String)
    case rule
    case table(headers: [String], rows: [[String]])
    case image(alt: String, target: String)
}

enum MarkdownBlockParser {
    static func parse(_ markdown: String) -> [MarkdownBlock] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                let languageText = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[index])
                    index += 1
                }
                blocks.append(.code(language: languageText.isEmpty ? nil : languageText,
                                    text: codeLines.joined(separator: "\n")))
                if index < lines.count { index += 1 }
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                index += 1
                continue
            }

            if let image = parseImage(trimmed) {
                flushParagraph()
                blocks.append(image)
                index += 1
                continue
            }

            if index + 1 < lines.count,
               trimmed.contains("|"),
               isTableSeparator(lines[index + 1]) {
                flushParagraph()
                let headers = tableCells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !candidate.isEmpty, candidate.contains("|") else { break }
                    rows.append(tableCells(candidate))
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph()
                blocks.append(.rule)
            } else if trimmed.hasPrefix("> ") {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(2))))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                blocks.append(.bullet(String(trimmed.dropFirst(2))))
            } else if let numbered = parseNumbered(trimmed) {
                flushParagraph()
                blocks.append(numbered)
            } else {
                paragraph.append(trimmed)
            }
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        let count = line.prefix { $0 == "#" }.count
        guard (1...6).contains(count), line.dropFirst(count).first == " " else { return nil }
        return .heading(level: count, text: String(line.dropFirst(count + 1)))
    }

    private static func parseNumbered(_ line: String) -> MarkdownBlock? {
        guard let dot = line.firstIndex(of: "."), dot < line.endIndex else { return nil }
        let numberText = String(line[..<dot])
        guard let number = Int(numberText) else { return nil }
        let afterDot = line.index(after: dot)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        return .numbered(number: number, text: String(line[line.index(after: afterDot)...]))
    }

    private static func parseImage(_ line: String) -> MarkdownBlock? {
        guard line.hasPrefix("!["), line.hasSuffix(")"),
              let separator = line.range(of: "](") else { return nil }
        let altStart = line.index(line.startIndex, offsetBy: 2)
        let alt = String(line[altStart..<separator.lowerBound])
        let targetStart = separator.upperBound
        let targetEnd = line.index(before: line.endIndex)
        return .image(alt: alt, target: String(line[targetStart..<targetEnd]))
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let normalized = cell.replacingOccurrences(of: ":", with: "")
                .trimmingCharacters(in: .whitespaces)
            return normalized.count >= 3 && normalized.allSatisfy { $0 == "-" }
        }
    }

    private static func tableCells(_ line: String) -> [String] {
        var cells = line.split(separator: "|", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }
}
