import SwiftUI

struct UserInputRequestsPanel: View {
    let requests: [UserInputRequest]
    let submit: (String, [String: String]) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(requests) { request in
                    UserInputRequestCard(request: request) { submit(request.id, $0) }
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(maxHeight: 360)
        .background(Color.orange.opacity(0.035))
    }
}

private struct UserInputRequestCard: View {
    let request: UserInputRequest
    let submit: ([String: String]) -> Void
    @State private var selectedOptions: [String: String] = [:]
    @State private var customAnswers: [String: String] = [:]
    @FocusState private var focusedQuestionID: String?

    private var answers: [String: String] {
        Dictionary(uniqueKeysWithValues: request.questions.map { question in
            let custom = (customAnswers[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (question.id, custom.isEmpty ? (selectedOptions[question.id] ?? "") : custom)
        })
    }

    private var isComplete: Bool {
        request.questions.allSatisfy {
            !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Codex 需要你的输入", systemImage: "questionmark.bubble.fill")
                    .font(.headline).foregroundStyle(.orange)
                Spacer()
                Text(request.isBlocking ? "等待回答" : "需要回答")
                    .font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            ForEach(request.questions) { question in
                VStack(alignment: .leading, spacing: 8) {
                    Text(question.header).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(question.question).font(.callout.weight(.medium)).textSelection(.enabled)
                    ForEach(question.options, id: \.label) { option in
                        Button {
                            selectedOptions[question.id] = option.label
                            customAnswers[question.id] = ""
                        } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: selectedOptions[question.id] == option.label ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selectedOptions[question.id] == option.label ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).fontWeight(.medium)
                                    if !option.description.isEmpty {
                                        Text(option.description).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).padding(8)
                        .background(selectedOptions[question.id] == option.label ? Color.accentColor.opacity(0.1) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                    if question.options.isEmpty || question.allowsOther {
                        if question.isSecret {
                            SecureField("输入回答", text: answerBinding(question.id))
                                .textFieldStyle(.roundedBorder).focused($focusedQuestionID, equals: question.id)
                        } else {
                            TextField(question.options.isEmpty ? "输入回答" : "其他回答", text: answerBinding(question.id), axis: .vertical)
                                .lineLimit(1...4).textFieldStyle(.roundedBorder)
                                .focused($focusedQuestionID, equals: question.id)
                        }
                    }
                }
            }
            if let error = request.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(ceil(request.expiresAt.timeIntervalSince(context.date))))
                    Text("回答会提交给当前 GPT‑6 任务；\(remaining) 秒后自动跳过。")
                        .font(.caption).foregroundStyle(remaining <= 10 ? Color.orange : Color.secondary)
                }
                Spacer()
                Button(request.isSubmitting ? "正在提交…" : "提交并继续") { submit(answers) }
                    .buttonStyle(.borderedProminent).disabled(!isComplete || request.isSubmitting)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.orange.opacity(0.35)))
        .onAppear {
            if let first = request.questions.first(where: { $0.options.isEmpty }) { focusedQuestionID = first.id }
        }
    }

    private func answerBinding(_ id: String) -> Binding<String> {
        Binding(get: { customAnswers[id] ?? "" }, set: { value in
            customAnswers[id] = value
            if !value.isEmpty { selectedOptions[id] = nil }
        })
    }
}
