import Foundation

/// Presentation only: keep the event journal intact and preserve message order.
/// Assistant replies and user messages remain outside the compact activity log.
enum ConversationTimelineEntry: Identifiable, Equatable {
    case message(ChatMessage)
    case process(ConversationProcessGroup)

    var id: String {
        switch self {
        case .message(let message): return "message:\(message.id)"
        case .process(let group): return group.id
        }
    }
}

struct ConversationProcessGroup: Identifiable, Equatable {
    let messages: [ChatMessage]
    let steps: [ChatMessage]
    let progress: ChatMessage?
    let failureCount: Int

    init(messages: [ChatMessage]) {
        self.messages = messages
        steps = messages.filter { $0.id != "turn-progress" }
        progress = messages.first { $0.id == "turn-progress" }
        failureCount = steps.filter(\.isFailedActivity).count
    }

    // External snapshots remove the synthetic progress row on completion.
    // Do not let that collapse a log the user currently has open.
    var id: String { "process:\(steps.first?.id ?? progress?.id ?? "empty")" }
    var latestStep: ChatMessage? { steps.last }
    var hasFailure: Bool { failureCount > 0 || progress?.isFailedActivity == true }
    var wasStopped: Bool { messages.contains { $0.activityStatus == "已停止" } }

    func status(isCurrent: Bool) -> String {
        if isCurrent { return latestStep?.isStreaming == true ? "执行中" : "思考中" }
        if hasFailure { return "有失败记录" }
        if wasStopped { return "已停止" }
        return "已结束"
    }
}

extension ChatMessage {
    var isFailedActivity: Bool {
        ["失败", "发送失败", "已拒绝"].contains(activityStatus ?? "")
    }
}

enum ConversationTimeline {
    static func entries(from messages: [ChatMessage]) -> [ConversationTimelineEntry] {
        var entries: [ConversationTimelineEntry] = []
        var activities: [ChatMessage] = []
        var activityTurnID: String?

        func flush() {
            guard !activities.isEmpty else { return }
            entries.append(.process(.init(messages: activities)))
            activities.removeAll(keepingCapacity: true)
            activityTurnID = nil
        }

        for message in messages {
            if message.role != .activity || message.id.hasPrefix("connection-notice-") {
                flush()
                entries.append(.message(message))
            } else {
                if let previousTurn = activityTurnID, let nextTurn = message.turnID, previousTurn != nextTurn {
                    flush()
                }
                activityTurnID = activityTurnID ?? message.turnID
                activities.append(message)
            }
        }
        flush()
        return entries
    }
}
