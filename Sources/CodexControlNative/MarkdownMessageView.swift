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

/// Returns one bounded page while carrying fenced-code state across raw page
/// boundaries. Without this, a page that begins inside a code block can make a
/// later closing fence look like a new opening fence and swallow all headings
/// and lists that follow it.
enum MarkdownPageWindow {
    static func pages(_ text: String, limit: Int) -> [String] {
        guard limit > 0, !text.isEmpty else { return [text] }
        let lines = text.components(separatedBy: .newlines)
        var result: [String] = []
        var currentLines: [String] = []
        var currentCount = 0
        var fenceAtPageStart: String?
        var openFence: String?

        func finishPage() {
            guard !currentLines.isEmpty else { return }
            var page = currentLines.joined(separator: "\n")
            if let fenceAtPageStart { page = fenceAtPageStart + "\n" + page }
            if openFence != nil { page += "\n```" }
            result.append(page)
            currentLines.removeAll(keepingCapacity: true)
            currentCount = 0
            fenceAtPageStart = openFence
        }

        for line in lines {
            let lineCost = line.count + (currentLines.isEmpty ? 0 : 1)
            if !currentLines.isEmpty, currentCount + lineCost > limit {
                finishPage()
            }
            currentLines.append(line)
            currentCount += line.count + (currentLines.count == 1 ? 0 : 1)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                openFence = openFence == nil ? trimmed : nil
            }
        }
        finishPage()
        return result.isEmpty ? [""] : result
    }
}

private struct MarkdownBlocksView: View, Equatable {
    let blocks: [MarkdownBlock]
    let expandsHorizontally: Bool

    @ViewBuilder
    var body: some View {
        let content = VStack(alignment: .leading, spacing: 10) {
            ReliableSelectableAttributedText(text: MarkdownTextDocument.appKitAttributed(from: blocks))
                .frame(maxWidth: UserMessagePresentation.maximumContentWidth, alignment: .leading)

            ForEach(Array(imageBlocks.enumerated()), id: \.offset) { _, block in
                if case .image(let alt, let target) = block {
                    MarkdownImage(alt: alt, target: target)
                }
            }
        }

        if expandsHorizontally {
            content.frame(maxWidth: .infinity, alignment: .leading)
        } else {
            // Keep short text compact, but still honor the available width.
            content.fixedSize(horizontal: false, vertical: true)
        }
    }

    private var imageBlocks: [MarkdownBlock] {
        blocks.filter {
            if case .image = $0 { return true }
            return false
        }
    }
}

enum MarkdownTextDocument {
    static func attributed(from blocks: [MarkdownBlock]) -> AttributedString {
        var document = AttributedString()
        let textualBlocks = blocks.filter {
            if case .image = $0 { return false }
            return true
        }

        for (index, block) in textualBlocks.enumerated() {
            if index > 0 {
                let previous = textualBlocks[index - 1]
                document.append(AttributedString(isList(previous) && isList(block) ? "\n" : "\n\n"))
            }
            document.append(attributed(block))
        }
        return document
    }

    static func appKitAttributed(from blocks: [MarkdownBlock]) -> NSAttributedString {
        let document = NSMutableAttributedString()
        let textualBlocks = blocks.filter {
            if case .image = $0 { return false }
            return true
        }

        for (index, block) in textualBlocks.enumerated() {
            if index > 0 {
                let previous = textualBlocks[index - 1]
                document.append(NSAttributedString(
                    string: isList(previous) && isList(block) ? "\n" : "\n\n",
                    attributes: [.font: preferredAppKitFont(.body)]
                ))
            }
            document.append(appKitAttributed(block))
        }

        // NSTextView otherwise falls back to a fixed black foreground for
        // attributed runs that only specify a font. Fill only missing colors
        // so ordinary text follows light/dark mode while quotes keep their
        // secondary color and links keep NSTextView's blue link styling.
        var uncoloredRanges: [NSRange] = []
        document.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: document.length)
        ) { value, range, _ in
            if value == nil { uncoloredRanges.append(range) }
        }
        for range in uncoloredRanges {
            document.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
        }
        return document
    }

    private static func attributed(_ block: MarkdownBlock) -> AttributedString {
        switch block {
        case .heading(let level, let text):
            return inline(text, font: headingFont(level))
        case .paragraph(let text):
            return inline(text, font: .body)
        case .bullet(let text):
            return prefix("•  ", followedBy: inline(text, font: .body), font: .body.weight(.semibold))
        case .numbered(let number, let text):
            return prefix("\(number).  ", followedBy: inline(text, font: .body), font: .body.monospacedDigit().weight(.medium))
        case .quote(let text):
            var value = prefix("│  ", followedBy: inline(text, font: .body), font: .body.weight(.semibold))
            value.foregroundColor = .secondary
            return value
        case .code(let language, let code):
            var value = AttributedString()
            if let language, !language.isEmpty {
                var label = AttributedString(language.uppercased() + "\n")
                label.font = .caption2.weight(.semibold)
                label.foregroundColor = .secondary
                value.append(label)
            }
            var source = AttributedString(code)
            source.font = .system(.callout, design: .monospaced)
            source.backgroundColor = Color.black.opacity(0.18)
            value.append(source)
            return value
        case .rule:
            var value = AttributedString("────────────────────────")
            value.foregroundColor = .secondary
            return value
        case .table(let headers, let rows):
            let allRows = [headers] + rows
            var value = AttributedString(allRows.map { $0.joined(separator: "  │  ") }.joined(separator: "\n"))
            value.font = .system(.callout, design: .monospaced)
            return value
        case .image:
            return AttributedString()
        }
    }

    private static func inline(_ text: String, font: Font) -> AttributedString {
        var value = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        value.font = font
        return value
    }

    private static func prefix(_ prefix: String, followedBy content: AttributedString, font: Font) -> AttributedString {
        var marker = AttributedString(prefix)
        marker.font = font
        var value = marker
        value.append(content)
        return value
    }

    private static func appKitAttributed(_ block: MarkdownBlock) -> NSAttributedString {
        switch block {
        case .heading(let level, let text):
            return inlineAppKit(text, font: headingAppKitFont(level))
        case .paragraph(let text):
            return inlineAppKit(text, font: preferredAppKitFont(.body))
        case .bullet(let text):
            return prefixAppKit(
                "•  ",
                content: inlineAppKit(text, font: preferredAppKitFont(.body)),
                font: preferredAppKitFont(.body, weight: .semibold)
            )
        case .numbered(let number, let text):
            return prefixAppKit(
                "\(number).  ",
                content: inlineAppKit(text, font: preferredAppKitFont(.body)),
                font: NSFont.monospacedDigitSystemFont(
                    ofSize: preferredAppKitFont(.body).pointSize,
                    weight: .medium
                )
            )
        case .quote(let text):
            let value = NSMutableAttributedString(attributedString: prefixAppKit(
                "│  ",
                content: inlineAppKit(text, font: preferredAppKitFont(.body)),
                font: preferredAppKitFont(.body, weight: .semibold)
            ))
            value.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: value.length))
            return value
        case .code(let language, let code):
            let value = NSMutableAttributedString()
            if let language, !language.isEmpty {
                value.append(NSAttributedString(
                    string: language.uppercased() + "\n",
                    attributes: [
                        .font: preferredAppKitFont(.caption2, weight: .semibold),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                ))
            }
            value.append(NSAttributedString(
                string: code,
                attributes: [
                    .font: NSFont.monospacedSystemFont(
                        ofSize: preferredAppKitFont(.callout).pointSize,
                        weight: .regular
                    ),
                    .backgroundColor: NSColor.black.withAlphaComponent(0.18)
                ]
            ))
            return value
        case .rule:
            return NSAttributedString(
                string: "────────────────────────",
                attributes: [
                    .font: preferredAppKitFont(.body),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        case .table(let headers, let rows):
            let allRows = [headers] + rows
            return NSAttributedString(
                string: allRows.map { $0.joined(separator: "  │  ") }.joined(separator: "\n"),
                attributes: [.font: NSFont.monospacedSystemFont(
                    ofSize: preferredAppKitFont(.callout).pointSize,
                    weight: .regular
                )]
            )
        case .image:
            return NSAttributedString()
        }
    }

    private static func inlineAppKit(_ text: String, font: NSFont) -> NSAttributedString {
        let value = (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
        let result = NSMutableAttributedString()
        for run in value.runs {
            var resolvedFont = font
            if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true {
                resolvedFont = NSFontManager.shared.convert(resolvedFont, toHaveTrait: .boldFontMask)
            }
            if run.inlinePresentationIntent?.contains(.emphasized) == true {
                resolvedFont = NSFontManager.shared.convert(resolvedFont, toHaveTrait: .italicFontMask)
            }
            if run.inlinePresentationIntent?.contains(.code) == true {
                resolvedFont = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
            }
            let renderedRun = NSMutableAttributedString(attributedString: NSAttributedString(AttributedString(value[run.range])))
            renderedRun.addAttribute(.font, value: resolvedFont, range: NSRange(location: 0, length: renderedRun.length))
            result.append(renderedRun)
        }
        return result
    }

    private static func prefixAppKit(_ prefix: String, content: NSAttributedString, font: NSFont) -> NSAttributedString {
        let value = NSMutableAttributedString(string: prefix, attributes: [.font: font])
        value.append(content)
        return value
    }

    private static func isList(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .bullet, .numbered: return true
        default: return false
        }
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.weight(.bold)
        case 2: return .title3.weight(.bold)
        case 3: return .headline
        default: return .subheadline.weight(.semibold)
        }
    }

    private static func headingAppKitFont(_ level: Int) -> NSFont {
        switch level {
        case 1: return preferredAppKitFont(.title2, weight: .bold)
        case 2: return preferredAppKitFont(.title3, weight: .bold)
        case 3: return preferredAppKitFont(.headline, weight: .semibold)
        default: return preferredAppKitFont(.subheadline, weight: .semibold)
        }
    }

    private static func preferredAppKitFont(_ style: NSFont.TextStyle, weight: NSFont.Weight = .regular) -> NSFont {
        let preferred = NSFont.preferredFont(forTextStyle: style)
        return NSFont.systemFont(ofSize: preferred.pointSize, weight: weight)
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
    @Environment(\.openURL) private var openURL
    private var localURL: URL? { ImagePreviewLink.localURL(target) }

    var body: some View {
        if let url = localURL, let image = NSImage(contentsOf: url) {
            VStack(alignment: .leading, spacing: 0) {
                Button { openURL(url) } label: {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 520, maxHeight: 360, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(alt.isEmpty ? "在 CloudCodex 中预览图片" : "在 CloudCodex 中预览\(alt)")

                Divider()
                HStack(spacing: 8) {
                    Label(url.lastPathComponent, systemImage: "photo")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("在 Finder 中显示", systemImage: "folder")
                    }
                    .buttonStyle(.borderless)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
            .help(alt.isEmpty ? target : alt)
        } else {
            Group {
                if let url = URL(string: target), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
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
    }

    private var imageFallback: some View {
        Label("\(alt.isEmpty ? "图片" : alt) · 图片无法读取，请检查原文件是否仍在", systemImage: "photo")
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
        var seen: Set<String> = []
        return blocks.flatMap { block -> [MarkdownBlock] in
            switch block {
            case .image(_, let target):
                seen.insert(ImagePreviewLink.localURL(target)?.path ?? target)
                return [block]
            case .paragraph(let text), .bullet(let text), .numbered(_, let text):
                let previews = ImagePreviewLink.previews(in: text).filter { preview in
                    guard case .image(_, let target) = preview else { return false }
                    return seen.insert(target).inserted
                }
                return [block] + previews
            default: return [block]
            }
        }
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

/// Preview only explicit local image links. Ordinary web links must not trigger
/// background downloads, and paths in fenced code are not image instructions.
enum ImagePreviewLink {
    static func localURL(_ target: String) -> URL? {
        var path = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("<"), path.hasSuffix(">") { path = String(path.dropFirst().dropLast()) }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if let url = URL(string: path), url.isFileURL,
           url.host == nil || url.host == "" || url.host == "localhost" { return url }
        return nil
    }

    static func previews(in text: String) -> [MarkdownBlock] {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!!)\[([^\]]*)\]\((<[^>]+>|[^\n]+?)\)"#) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            let label = ns.substring(with: match.range(at: 1))
            let target = ns.substring(with: match.range(at: 2))
            guard let url = localURL(target),
                  ["png", "jpg", "jpeg", "webp", "gif", "heic", "tif", "tiff", "bmp", "icns"].contains(url.pathExtension.lowercased()) else { return nil }
            return .image(alt: label, target: url.path)
        }
    }
}
