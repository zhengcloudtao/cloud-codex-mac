import Foundation

struct ComposerPredictionTaskID: Hashable {
    let source: ComposerPredictionSource?
    let connection: String
}

struct ComposerPredictionSource: Hashable {
    let threadID: String
    let turnID: String

    static let prompt = """
    Suggest the short message the user is most likely to type next, based on this conversation.
    Write from the user's perspective and match their language and tone. Prefer a concrete natural
    follow-up to the last exchange. Do not invent requirements, actions, approvals, or facts.
    If the next step is unclear or the task is complete with no natural follow-up, return null.
    This is a text prediction only: do not use tools, execute commands, modify files, ask questions,
    or continue the task. Return only JSON with one field, "suggestion", containing the message or null.
    """
}

enum ComposerPredictionState: Equatable {
    case pending
    case ready(String)
    case unavailable
    case consumed
}
