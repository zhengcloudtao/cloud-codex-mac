import Foundation

@MainActor
final class AppServerClient {
    typealias JSON = [String: Any]
    typealias EventHandler = (String, JSON) -> Void

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]
    private var loadedThreadIDs: Set<String> = []
    private(set) var connected = false
    var onEvent: EventHandler?
    var onDisconnect: ((String) -> Void)?

    deinit {
        output?.readabilityHandler = nil
        errorOutput?.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
    }

    func start() async throws {
        if connected { return }
        let executable = try locateCodex()
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.handleTermination(process.terminationStatus)
            }
        }

        output = stdout.fileHandleForReading
        input = stdin.fileHandleForWriting
        errorOutput = stderr.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }
        errorOutput?.readabilityHandler = { handle in
            // Drain diagnostics so a full stderr pipe can never stall app-server.
            _ = handle.availableData
        }

        try process.run()
        self.process = process
        let response = try await request(
            "initialize",
            params: [
                "clientInfo": [
                    "name": "cloudcodex",
                    "title": "CloudCodex",
                    "version": "0.1.0"
                ],
                "capabilities": ["experimentalApi": true]
            ]
        )
        guard response["platformOs"] as? String == "macos" else {
            throw CodexClientError.invalidResponse
        }
        try send(["method": "initialized"])
        connected = true
    }

    func listThreads(limit: Int = 60, cwd: String? = nil) async throws -> ThreadPage {
        var params: JSON = [
            "limit": limit,
            "sortKey": "updated_at",
            "sortDirection": "desc",
            "useStateDbOnly": true
        ]
        if let cwd { params["cwd"] = cwd }
        let result = try await request("thread/list", params: params)
        let rows = result["data"] as? [JSON] ?? []
        return ThreadPage(
            threads: rows.compactMap(CodexThread.init(json:)),
            hasMore: result["nextCursor"] is String
        )
    }

    func listWorkspaceFolders(limit: Int = 200) async throws -> [WorkspaceFolder] {
        let result = try await request(
            "project/list",
            params: ["limit": limit, "sortKey": "recencyAt", "sortDirection": "desc"]
        )
        let projects = result["data"] as? [JSON] ?? []
        var folders: [String: WorkspaceFolder] = [:]
        for project in projects {
            let timestamp = (project["recencyAt"] as? NSNumber)?.doubleValue
                ?? (project["updatedAt"] as? NSNumber)?.doubleValue
                ?? 0
            let roots = project["roots"] as? [JSON] ?? []
            for root in roots {
                guard let path = root["path"] as? String else { continue }
                let folder = WorkspaceFolder(
                    path: path,
                    threadCount: nil,
                    latestUpdate: Date(timeIntervalSince1970: timestamp)
                )
                if folders[path] == nil || folders[path]!.latestUpdate < folder.latestUpdate {
                    folders[path] = folder
                }
            }
        }
        return folders.values.sorted { $0.latestUpdate > $1.latestUpdate }
    }

    func listModels() async throws -> [CodexModelOption] {
        let result = try await request("model/list", params: ["limit": 100])
        let rows = result["data"] as? [JSON] ?? []
        return rows.compactMap(CodexModelOption.init(json:))
    }

    func listPermissionProfiles(cwd: String?) async throws -> [PermissionProfileOption] {
        var params: JSON = ["limit": 100]
        if let cwd { params["cwd"] = cwd }
        let result = try await request("permissionProfile/list", params: params)
        let rows = result["data"] as? [JSON] ?? []
        return rows.compactMap(PermissionProfileOption.init(json:)).filter(\.isAllowed)
    }

    func readThread(_ id: String) async throws -> (CodexThread, [ChatMessage]) {
        let result = try await request(
            "thread/read",
            params: ["threadId": id, "includeTurns": false]
        )
        guard let json = result["thread"] as? JSON,
              let thread = CodexThread(json: json) else {
            throw CodexClientError.invalidResponse
        }
        let turnsResult = try await request(
            "thread/turns/list",
            params: [
                "threadId": id,
                "limit": 20,
                "itemsView": "summary",
                "sortDirection": "desc"
            ]
        )
        let newestFirst = turnsResult["data"] as? [JSON] ?? []
        return (thread, Self.parseMessages(from: newestFirst.reversed()))
    }

    func createThread(cwd: String, model: String?, permissions: String?) async throws -> CodexThread {
        var params: JSON = ["cwd": cwd, "ephemeral": false]
        if let model { params["model"] = model }
        if let permissions { params["permissions"] = permissions }
        let result = try await request(
            "thread/start",
            params: params
        )
        guard let json = result["thread"] as? JSON,
              let thread = CodexThread(json: json) else {
            throw CodexClientError.invalidResponse
        }
        loadedThreadIDs.insert(thread.id)
        return thread
    }

    func resumeThread(_ id: String) async throws {
        if loadedThreadIDs.contains(id) { return }
        _ = try await request("thread/resume", params: ["threadId": id])
        loadedThreadIDs.insert(id)
    }

    func startTurn(
        threadID: String,
        text: String,
        attachments: [ComposerAttachment],
        model: String?,
        effort: String?,
        permissions: String?
    ) async throws -> String? {
        var input: [[String: Any]] = []
        if !text.isEmpty { input.append(["type": "text", "text": text]) }
        input.append(contentsOf: attachments.map(\.userInput))
        var params: JSON = ["threadId": threadID, "input": input]
        if let model { params["model"] = model }
        if let effort { params["effort"] = effort }
        if let permissions { params["permissions"] = permissions }
        let result = try await request(
            "turn/start",
            params: params
        )
        return (result["turn"] as? JSON)?["id"] as? String
    }

    func interruptTurn(threadID: String, turnID: String) async throws {
        _ = try await request(
            "turn/interrupt",
            params: ["threadId": threadID, "turnId": turnID]
        )
    }

    private func request(_ method: String, params: JSON) async throws -> JSON {
        guard process?.isRunning == true, input != nil else {
            throw CodexClientError.notRunning
        }
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do {
                try send(["id": id, "method": method, "params": params])
            } catch {
                pending.removeValue(forKey: id)
                continuation.resume(throwing: error)
            }
        }
    }

    private func send(_ object: JSON) throws {
        guard let input else { throw CodexClientError.notRunning }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        var lineStart = buffer.startIndex
        while lineStart < buffer.endIndex,
              let newline = buffer[lineStart...].firstIndex(of: 0x0A) {
            let line = Data(buffer[lineStart..<newline])
            lineStart = buffer.index(after: newline)
            if !line.isEmpty,
               let object = try? JSONSerialization.jsonObject(with: line) as? JSON {
                handle(object)
            }
        }
        if lineStart > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<lineStart)
        }
    }

    private func handle(_ object: JSON) {
        if let idNumber = object["id"] as? NSNumber,
           let continuation = pending.removeValue(forKey: idNumber.intValue) {
            if let error = object["error"] as? JSON {
                let message = error["message"] as? String ?? "Codex 请求失败"
                continuation.resume(throwing: CodexClientError.server(message))
            } else if let result = object["result"] as? JSON {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: CodexClientError.invalidResponse)
            }
            return
        }
        if let method = object["method"] as? String,
           let params = object["params"] as? JSON {
            onEvent?(method, params)
        }
    }

    private func handleTermination(_ status: Int32) {
        connected = false
        let error = CodexClientError.process("Codex 本地服务已退出（状态码 \(status)）")
        let callbacks = pending.values
        pending.removeAll()
        callbacks.forEach { $0.resume(throwing: error) }
        onDisconnect?(error.localizedDescription)
    }

    private func locateCodex() throws -> URL {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        if let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: path)
        }
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":") {
                let candidate = String(directory) + "/codex"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return URL(fileURLWithPath: candidate)
                }
            }
        }
        throw CodexClientError.binaryNotFound
    }

    private static func parseMessages<S: Sequence>(from turns: S) -> [ChatMessage] where S.Element == JSON {
        var messages: [ChatMessage] = []
        for turn in turns {
            guard let items = turn["items"] as? [JSON] else { continue }
            for item in items {
                guard let type = item["type"] as? String else { continue }
                let id = item["id"] as? String ?? UUID().uuidString
                switch type {
                case "userMessage":
                    let content = item["content"] as? [JSON] ?? []
                    let text = content.compactMap { part -> String? in
                        switch part["type"] as? String {
                        case "text":
                            return part["text"] as? String
                        case "localImage":
                            let path = part["path"] as? String ?? "图片"
                            return "🖼 \(URL(fileURLWithPath: path).lastPathComponent)"
                        case "mention":
                            return "📎 \(part["name"] as? String ?? "文件")"
                        default:
                            return nil
                        }
                    }.joined(separator: "\n")
                    if !text.isEmpty { messages.append(.init(id: id, role: .user, text: text)) }
                case "agentMessage":
                    if let text = item["text"] as? String, !text.isEmpty {
                        messages.append(.init(id: id, role: .assistant, text: text))
                    }
                case "reasoning":
                    let summary = item["summary"] as? [String] ?? []
                    if !summary.isEmpty {
                        messages.append(.init(
                            id: id,
                            role: .activity,
                            text: summary.joined(separator: "\n"),
                            activityKind: .reasoning,
                            activityTitle: "思考摘要",
                            activityStatus: "已完成"
                        ))
                    }
                case "plan":
                    if let text = item["text"] as? String, !text.isEmpty {
                        messages.append(.init(
                            id: id,
                            role: .activity,
                            text: text,
                            activityKind: .plan,
                            activityTitle: "执行计划",
                            activityStatus: "已完成"
                        ))
                    }
                case "commandExecution":
                    if let command = item["command"] as? String {
                        let exitCode = (item["exitCode"] as? NSNumber)?.stringValue
                        var detail = "$ \(command)"
                        if let cwd = item["cwd"] as? String, !cwd.isEmpty { detail += "\n目录：\(cwd)" }
                        if let output = item["aggregatedOutput"] as? String, !output.isEmpty {
                            detail += "\n" + clippedActivityText(output)
                        }
                        let status = exitCode.map { $0 == "0" ? "已完成" : "失败（退出码 \($0)）" } ?? "已完成"
                        messages.append(.init(
                            id: id,
                            role: .activity,
                            text: detail,
                            activityKind: .command,
                            activityTitle: "执行命令",
                            activityStatus: status
                        ))
                    }
                case "fileChange":
                    let changes = item["changes"] as? [JSON] ?? []
                    let paths = changes.compactMap { change -> String? in
                        guard let path = change["path"] as? String else { return nil }
                        let type = (change["kind"] as? JSON)?["type"] as? String ?? "update"
                        let verb = type == "add" ? "新增" : (type == "delete" ? "删除" : "修改")
                        return "\(verb)  \(path)"
                    }
                    messages.append(.init(
                        id: id,
                        role: .activity,
                        text: paths.isEmpty ? "已更新工作区文件" : paths.joined(separator: "\n"),
                        activityKind: .file,
                        activityTitle: "文件变更",
                        activityStatus: "已完成"
                    ))
                case "mcpToolCall":
                    let server = item["server"] as? String ?? "MCP"
                    let tool = item["tool"] as? String ?? "工具"
                    messages.append(.init(
                        id: id,
                        role: .activity,
                        text: jsonPreview(item["arguments"]),
                        activityKind: .tool,
                        activityTitle: "调用 \(server) · \(tool)",
                        activityStatus: localizedStatus(item["status"] as? String)
                    ))
                case "dynamicToolCall":
                    let namespace = item["namespace"] as? String
                    let tool = item["tool"] as? String ?? "工具"
                    messages.append(.init(
                        id: id,
                        role: .activity,
                        text: jsonPreview(item["arguments"]),
                        activityKind: .tool,
                        activityTitle: "调用 " + [namespace, tool].compactMap { $0 }.joined(separator: " · "),
                        activityStatus: localizedStatus(item["status"] as? String)
                    ))
                case "webSearch":
                    messages.append(.init(
                        id: id,
                        role: .activity,
                        text: item["query"] as? String ?? "",
                        activityKind: .web,
                        activityTitle: "搜索网页",
                        activityStatus: "已完成"
                    ))
                case "imageView":
                    messages.append(.init(
                        id: id,
                        role: .activity,
                        text: item["path"] as? String ?? "",
                        activityKind: .tool,
                        activityTitle: "查看图片",
                        activityStatus: "已完成"
                    ))
                case "contextCompaction":
                    messages.append(.init(
                        id: id,
                        role: .activity,
                        text: "Codex 已整理较早的会话上下文。",
                        activityKind: .status,
                        activityTitle: "整理会话上下文",
                        activityStatus: "已完成"
                    ))
                default:
                    break
                }
            }
        }
        return messages
    }

    private static func clippedActivityText(_ text: String) -> String {
        let limit = 12_000
        guard text.count > limit else { return text }
        return "…已省略较早输出…\n" + String(text.suffix(limit))
    }

    private static func jsonPreview(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return clippedActivityText(text)
    }

    private static func localizedStatus(_ status: String?) -> String {
        switch status {
        case "inProgress": return "进行中"
        case "failed": return "失败"
        case "declined": return "已拒绝"
        case "interrupted": return "已停止"
        default: return "已完成"
        }
    }
}
