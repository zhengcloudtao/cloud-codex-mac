import Foundation
import SwiftUI

/// Ordinary assistant questions do not arrive as requestUserInput events.
/// Offer a bounded, adjacent list as draft suggestions, never as tool answers.
enum AssistantReplyChoices {
    static func options(in messages: [ChatMessage]) -> [String] {
        guard let message = messages.last(where: { $0.role != .activity }),
              message.role == .assistant, !message.isStreaming,
              message.text.count <= 12_000 else { return [] }
        let blocks = MarkdownBlockParser.parse(message.text)
        var candidates: [[String]] = []
        for (index, block) in blocks.enumerated() {
            guard case .paragraph(let prompt) = block,
                  prompt.contains("?") || prompt.contains("？") else { continue }
            var choices: [String] = []
            optionList: for following in blocks.dropFirst(index + 1) {
                let text: String
                switch following {
                case .bullet(let value), .numbered(_, let value): text = value
                default: break optionList
                }
                let plain = String((try? AttributedString(markdown: text,
                    options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))?.characters
                    ?? AttributedString(text).characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !plain.isEmpty, plain.count <= 120,
                      !text.contains("["), !text.contains("`"),
                      !choices.contains(plain) else { choices.removeAll(); break }
                choices.append(plain)
            }
            if (2...5).contains(choices.count) { candidates.append(choices) }
        }
        // Multiple questions need an explicit form to avoid mixing answers.
        return candidates.count == 1 ? candidates[0] : []
    }

    static func draft(selecting option: String, options: [String], current: String) -> String {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || options.contains(trimmed) { return option }
        if current.components(separatedBy: .newlines).contains(option) { return current }
        return current + (current.hasSuffix("\n") ? "" : "\n") + option
    }
}

struct AssistantReplyChoicesView: View {
    let options: [String]
    let draft: String
    let select: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("选择回答 · 点击填入，可补充后发送")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(options, id: \.self) { option in
                Button { select(option) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: draft == option ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(draft == option ? Color.accentColor : Color.secondary)
                        Text(option).font(.callout).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(draft == option ? 0.12 : 0.04),
                                in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择回答：\(option)")
                .help("填入输入框，发送前可以继续编辑")
            }
        }
    }
}
