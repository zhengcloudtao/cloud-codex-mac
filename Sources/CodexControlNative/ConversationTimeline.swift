import Foundation

/// Presentation only: keep the event journal intact and preserve message order.
/// Assistant replies and user messages remain outside the compact activity log.
enum ConversationTimelineEntry: Identifiable, Equatable {
    case message(ChatMessage)
    case process(ConversationProcessGroup)
    case fileChanges(ConversationFileChangeGroup)

    var id: String {
        switch self {
        case .message(let message): return "message:\(message.id)"
        case .process(let group): return group.id
        case .fileChanges(let group): return group.id
        }
    }

    var turnID: String? {
        switch self {
        case .message(let message): return message.turnID
        case .process(let group): return group.turnID
        case .fileChanges(let group): return group.turnID
        }
    }
}

struct ConversationProcessGroup: Identifiable, Equatable {
    let messages: [ChatMessage]
    let steps: [ChatMessage]
    let progress: ChatMessage?
    let failureCount: Int
    private let summarizedChildTasks: [CollaborationChildTask]

    init(messages: [ChatMessage], summarizedChildTasks: [CollaborationChildTask] = []) {
        self.messages = messages
        steps = messages.filter { $0.id != "turn-progress" }
        progress = messages.first { $0.id == "turn-progress" }
        failureCount = steps.filter(\.isFailedActivity).count
        self.summarizedChildTasks = summarizedChildTasks
    }

    // External snapshots remove the synthetic progress row on completion.
    // Do not let that collapse a log the user currently has open.
    var id: String { "process:\(steps.first?.id ?? progress?.id ?? "empty")" }
    var latestStep: ChatMessage? { steps.last }
    var childTasks: [CollaborationChildTask] {
        var order: [String] = []
        var merged: [String: CollaborationChildTask] = [:]
        for tasks in steps.map(\.collaborationChildTasks) + [summarizedChildTasks] {
            for task in tasks {
                if merged[task.threadID] == nil { order.append(task.threadID) }
                if var existing = merged[task.threadID] {
                    if !task.name.hasPrefix("子任务 ") { existing.name = task.name }
                    if task.status != "等待状态" { existing.status = task.status }
                    if !task.detail.isEmpty { existing.detail = task.detail }
                    merged[task.threadID] = existing
                } else {
                    merged[task.threadID] = task
                }
            }
        }
        return order.compactMap { merged[$0] }
    }
    var turnID: String? { messages.compactMap(\.turnID).last }
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
    static func latestChildTasks(from messages: [ChatMessage]) -> [CollaborationChildTask] {
        guard let latestTurnID = messages.reversed().first(where: {
            !$0.collaborationChildTasks.isEmpty && $0.turnID != nil
        })?.turnID else { return [] }
        return ConversationProcessGroup(
            messages: messages.filter { $0.turnID == latestTurnID }
        ).childTasks
    }

    static func entries(from messages: [ChatMessage]) -> [ConversationTimelineEntry] {
        var entries: [ConversationTimelineEntry] = []
        var activities: [ChatMessage] = []
        var activityTurnID: String?
        var fileChangesByTurn: [String: [ConversationFileChange]] = [:]
        var aggregateFileChangeTurns: Set<String> = []

        func flush() {
            guard !activities.isEmpty else { return }
            entries.append(.process(.init(messages: activities)))
            activities.removeAll(keepingCapacity: true)
            activityTurnID = nil
        }

        for message in messages {
            if let turnID = message.turnID, !message.fileChanges.isEmpty {
                if message.id.hasPrefix("turn-diff-") {
                    fileChangesByTurn[turnID] = message.fileChanges
                    aggregateFileChangeTurns.insert(turnID)
                } else if !aggregateFileChangeTurns.contains(turnID) {
                    fileChangesByTurn[turnID, default: []].append(contentsOf: message.fileChanges)
                }
                continue
            }
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

        // Assistant progress messages split one Codex turn into several compact
        // process cards. Collaboration usually starts near the top of that turn,
        // which can be outside the default viewport by the time work finishes.
        // Summarize every child on the final process card for the same turn so
        // the named tasks and current states remain visible at the bottom.
        var tasksByTurn: [String: [CollaborationChildTask]] = [:]
        for message in messages {
            guard let turnID = message.turnID, !message.collaborationChildTasks.isEmpty else { continue }
            tasksByTurn[turnID, default: []].append(contentsOf: message.collaborationChildTasks)
        }
        var finalProcessIndexByTurn: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            guard case .process(let group) = entry, let turnID = group.turnID else { continue }
            finalProcessIndexByTurn[turnID] = index
        }
        for (turnID, tasks) in tasksByTurn {
            guard let index = finalProcessIndexByTurn[turnID],
                  case .process(let group) = entries[index] else { continue }
            entries[index] = .process(.init(messages: group.messages, summarizedChildTasks: tasks))
        }

        guard !fileChangesByTurn.isEmpty else { return entries }
        var lastEntryByTurn: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            if let turnID = entry.turnID { lastEntryByTurn[turnID] = index }
        }
        var result: [ConversationTimelineEntry] = []
        for (index, entry) in entries.enumerated() {
            result.append(entry)
            guard let turnID = entry.turnID,
                  lastEntryByTurn[turnID] == index,
                  let changes = fileChangesByTurn[turnID], !changes.isEmpty else { continue }
            result.append(.fileChanges(.init(turnID: turnID, changes: changes)))
        }
        let representedTurns = Set(result.compactMap(\.turnID))
        for (turnID, changes) in fileChangesByTurn where !representedTurns.contains(turnID) {
            result.append(.fileChanges(.init(turnID: turnID, changes: changes)))
        }
        return result
    }
}
