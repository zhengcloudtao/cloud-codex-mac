import Foundation

struct ThreadResumePresentation {
    let title: String
    let detail: String
    let originalError: String?

    init(_ notice: String?) {
        let raw = notice?.trimmingCharacters(in: .whitespacesAndNewlines)
        originalError = raw.flatMap { $0.isEmpty ? nil : $0 }
        if raw?.lowercased().contains("cannot resume an unloaded multi-agent v2 sub-agent through its parent") == true {
            title = "请先打开主会话"
            detail = "这个并行子任务尚未加载。请先打开它所属的主会话，再返回此处重试。历史记录仍可查看。"
        } else {
            title = "暂时无法继续会话"
            detail = "会话恢复未完成，历史记录仍可查看。请稍后重试。"
        }
    }
}
