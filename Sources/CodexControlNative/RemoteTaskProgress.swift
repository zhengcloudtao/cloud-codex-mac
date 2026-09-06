import Foundation

/// Bounded, public activity only. Never serialize arbitrary tool arguments or raw reasoning.
struct RemoteTaskProgress: Codable, Equatable {
    struct Step: Codable, Equatable {
        var id: String
        var kind: String
        var title: String
        var status: String
        var text: String
    }
    var steps: [Step] = []
    var truncated = false
    var revision: Int64 = 0

    mutating func consume(_ method: String, _ params: [String: Any]) {
        let old = steps
        if method == "item/started" || method == "item/completed",
           let item = params["item"] as? [String: Any], let id = item["id"] as? String {
            let type = item["type"] as? String ?? ""
            let completed = method == "item/completed"
            let status = item["status"] as? String ?? ""
            var step = Step(id: id, kind: "tool", title: "工具调用", status: completed ? "completed" : "running", text: "")
            if status == "failed" || status == "declined" { step.status = "failed" }
            switch type {
            case "reasoning":
                step.kind = "reasoning"; step.title = "思考摘要"
                step.text = (item["summary"] as? [String] ?? []).joined(separator: "\n")
            case "plan":
                step.kind = "plan"; step.title = "执行计划"; step.text = item["text"] as? String ?? ""
            case "agentMessage":
                step.kind = "message"; step.title = "处理进展"; step.text = item["text"] as? String ?? ""
            case "commandExecution":
                step.kind = "command"; step.title = "执行命令"
                step.text = "$ " + (item["command"] as? String ?? "") + "\n" + (item["aggregatedOutput"] as? String ?? "")
                if completed, item["aggregatedOutput"] == nil, let previous = steps.first(where: { $0.id == id }) { step.text = previous.text }
                if let code = item["exitCode"] as? Int, code != 0 { step.status = "failed" }
            case "fileChange":
                step.kind = "file"; step.title = "文件变更"
                step.text = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }.joined(separator: "\n")
            case "mcpToolCall", "dynamicToolCall":
                step.title = "调用 " + (item["tool"] as? String ?? "工具")
            case "webSearch":
                step.title = "搜索网页"; step.text = item["query"] as? String ?? ""
            case "imageView":
                step.title = "查看图片"
            default: return
            }
            put(step)
        } else if method == "turn/plan/updated" {
            let text = (params["plan"] as? [[String: Any]] ?? []).map {
                (($0["status"] as? String == "completed") ? "- [x] " : "- [ ] ") + ($0["step"] as? String ?? "")
            }.joined(separator: "\n")
            put(Step(id: "turn-plan", kind: "plan", title: "执行计划", status: "running", text: text))
        } else if let id = params["itemId"] as? String {
            let kind: String
            let title: String
            switch method {
            case "item/reasoning/summaryTextDelta", "item/reasoning/summaryPartAdded": kind = "reasoning"; title = "思考摘要"
            case "item/commandExecution/outputDelta": kind = "command"; title = "执行命令"
            case "item/plan/delta": kind = "plan"; title = "执行计划"
            case "item/agentMessage/delta": kind = "message"; title = "处理进展"
            case "item/mcpToolCall/progress": kind = "tool"; title = "工具调用"
            default: return
            }
            var step = steps.first { $0.id == id } ?? Step(id: id, kind: kind, title: title, status: "running", text: "")
            // A delayed delta must not revive a completed step.
            guard step.status == "running" else { return }
            step.text += method == "item/reasoning/summaryPartAdded" ? "\n" : (params["delta"] as? String ?? params["message"] as? String ?? "")
            put(step)
        } else if method == "turn/completed" || method == "error" {
            for i in steps.indices where steps[i].status == "running" { steps[i].status = "interrupted" }
        }
        if old != steps { revision = max(revision + 1, Int64(Date().timeIntervalSince1970 * 1000)) }
    }

    private mutating func put(_ value: Step) {
        var step = value
        step.id = String(step.id.prefix(160)); step.title = String(step.title.prefix(120))
        if step.text.count > 2000 { step.text = "…仅显示最近输出\n" + String(step.text.suffix(1900)) }
        if let index = steps.firstIndex(where: { $0.id == step.id }) {
            if step.text.isEmpty { step.text = steps[index].text }
            steps[index] = step
        } else {
            steps.append(step)
            if steps.count > 64 { steps.removeFirst(steps.count - 64); truncated = true }
        }
    }
}
