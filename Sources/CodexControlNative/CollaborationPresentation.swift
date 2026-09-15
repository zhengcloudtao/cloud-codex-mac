import Foundation

struct CollaborationChildTask: Identifiable, Hashable {
    let threadID: String
    var name: String
    var status: String
    var detail: String

    var id: String { threadID }
    var isRunning: Bool { status == "等待启动" || status == "执行中" }
    var hasFailed: Bool { status == "失败" || status == "不可用" }
}

struct CollaborationItemPresentation {
    let title: String
    let text: String
    let status: String
    let isStreaming: Bool
    let childTasks: [CollaborationChildTask]

    static func parse(_ item: [String: Any], completed: Bool) -> Self? {
        switch item["type"] as? String {
        case "collabAgentToolCall":
            let tool = item["tool"] as? String ?? "协作任务"
            let callStatus = item["status"] as? String ?? (completed ? "completed" : "inProgress")
            let receiverIDs = item["receiverThreadIds"] as? [String] ?? []
            let states = item["agentsStates"] as? [String: [String: Any]] ?? [:]
            let childTasks = receiverIDs.enumerated().map { index, threadID in
                let state = states[threadID]
                return CollaborationChildTask(
                    threadID: threadID,
                    name: "子任务 \(index + 1)",
                    status: childStatus(state?["status"] as? String),
                    detail: state?["message"] as? String ?? ""
                )
            }
            return .init(
                title: toolTitle(tool, count: receiverIDs.count),
                text: item["prompt"] as? String ?? "",
                status: callStatusLabel(callStatus),
                isStreaming: callStatus == "inProgress",
                childTasks: childTasks
            )

        case "subAgentActivity":
            guard let threadID = item["agentThreadId"] as? String else { return nil }
            let path = item["agentPath"] as? String ?? "子任务"
            let kind = item["kind"] as? String ?? "started"
            let name = path.split(separator: "/").last.map(String.init) ?? path
            let status = activityStatus(kind)
            return .init(
                title: "子任务 · \(name)",
                text: activityDetail(kind),
                status: status,
                isStreaming: status == "执行中" || status == "等待启动",
                childTasks: [.init(threadID: threadID, name: name, status: status, detail: "")]
            )

        default:
            return nil
        }
    }

    private static func toolTitle(_ tool: String, count: Int) -> String {
        switch tool {
        case "spawnAgent": return count > 0 ? "拆分并行子任务 · \(count) 个" : "拆分并行子任务"
        case "sendInput", "sendMessage", "followupTask": return "发送子任务消息"
        case "resumeAgent": return "继续子任务"
        case "wait": return "等待子任务"
        case "interruptAgent": return "停止子任务"
        case "closeAgent": return "关闭子任务"
        case "listAgents": return "检查子任务状态"
        default: return "协作 · \(tool)"
        }
    }

    private static func callStatusLabel(_ status: String) -> String {
        switch status {
        case "inProgress": return "进行中"
        case "failed": return "失败"
        case "interrupted": return "已停止"
        default: return "已完成"
        }
    }

    private static func childStatus(_ status: String?) -> String {
        switch status {
        case "pendingInit": return "等待启动"
        case "running": return "执行中"
        case "interrupted": return "已停止"
        case "completed": return "已完成"
        case "errored": return "失败"
        case "shutdown": return "已关闭"
        case "notFound": return "不可用"
        default: return "等待状态"
        }
    }

    private static func activityStatus(_ kind: String) -> String {
        switch kind {
        case "completed": return "已完成"
        case "interrupted": return "已停止"
        case "started", "interacted": return "执行中"
        default: return "等待状态"
        }
    }

    private static func activityDetail(_ kind: String) -> String {
        switch kind {
        case "completed": return "子任务已经完成并返回结果。"
        case "interrupted": return "子任务已经停止。"
        case "interacted": return "主任务正在与该子任务协作。"
        default: return "子任务已经启动。"
        }
    }
}
