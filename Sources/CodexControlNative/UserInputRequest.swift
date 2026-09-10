import Foundation

enum AppServerRequestID: Equatable {
    case number(Int)
    case string(String)

    init?(_ value: Any) {
        if let value = value as? NSNumber { self = .number(value.intValue) }
        else if let value = value as? String { self = .string(value) }
        else { return nil }
    }

    var jsonValue: Any {
        switch self {
        case .number(let value): return value
        case .string(let value): return value
        }
    }

    var stableID: String {
        switch self {
        case .number(let value): return "number:\(value)"
        case .string(let value): return "string:\(value)"
        }
    }
}

struct UserInputRequest: Identifiable, Equatable {
    struct Option: Equatable {
        let label: String
        let description: String
    }

    struct Question: Identifiable, Equatable {
        let id: String
        let header: String
        let question: String
        let options: [Option]
        let allowsOther: Bool
        let isSecret: Bool
    }

    let requestID: AppServerRequestID
    let threadID: String
    let turnID: String
    let itemID: String
    let isBlocking: Bool
    let questions: [Question]
    let expiresAt: Date
    var isSubmitting = false
    var error: String?

    var id: String { requestID.stableID }

    func responsePayload(answers: [String: String]) -> [String: Any] {
        ["answers": Dictionary(uniqueKeysWithValues: questions.map {
            ($0.id, ["answers": [answers[$0.id] ?? ""]])
        })]
    }

    var skippedResponsePayload: [String: Any] {
        ["answers": Dictionary(uniqueKeysWithValues: questions.map {
            ($0.id, ["answers": ["跳过（1 分钟内未回答）"]])
        })]
    }

    init?(requestID: AppServerRequestID, params: [String: Any], receivedAt: Date = Date(), timeout: TimeInterval = 60) {
        guard let threadID = params["threadId"] as? String,
              let turnID = params["turnId"] as? String,
              let itemID = params["itemId"] as? String,
              let rows = params["questions"] as? [[String: Any]] else { return nil }
        let questions = rows.compactMap { row -> Question? in
            guard let id = row["id"] as? String,
                  let header = row["header"] as? String,
                  let question = row["question"] as? String else { return nil }
            let options = (row["options"] as? [[String: Any]] ?? []).compactMap { option -> Option? in
                guard let label = option["label"] as? String,
                      let description = option["description"] as? String else { return nil }
                return Option(label: label, description: description)
            }
            return Question(id: id, header: header, question: question, options: options,
                            allowsOther: row["isOther"] as? Bool ?? false,
                            isSecret: row["isSecret"] as? Bool ?? false)
        }
        guard questions.count == rows.count, !questions.isEmpty else { return nil }
        self.requestID = requestID
        self.threadID = threadID
        self.turnID = turnID
        self.itemID = itemID
        self.isBlocking = params["isBlocking"] as? Bool ?? true
        self.questions = questions
        self.expiresAt = receivedAt.addingTimeInterval(max(0, timeout))
    }
}
