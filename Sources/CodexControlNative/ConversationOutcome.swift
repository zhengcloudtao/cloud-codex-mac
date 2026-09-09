import Foundation

/// Only a confirmed turn result is a completion; an idle thread alone is not.
enum ConversationOutcome: String {
    case running = "inProgress"
    case completed
    case failed
    case interrupted

    var title: String {
        switch self {
        case .running: return "执行中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .interrupted: return "已停止"
        }
    }

    var symbol: String {
        switch self {
        case .running: return "ellipsis.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .interrupted: return "stop.circle.fill"
        }
    }
}
