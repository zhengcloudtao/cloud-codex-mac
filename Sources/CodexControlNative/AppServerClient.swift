import Foundation

@MainActor
final class AppServerClient {
    typealias JSON = [String: Any]
    typealias EventHandler = (String, JSON) -> Void
    typealias ServerRequestHandler = (AppServerRequestID, String, JSON) -> Void

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private let decodingWorker = JSONLineDecodingWorker()
    private let turnMetadataReader = TurnMetadataReader()
    private var nextID = 1
    private struct PendingRequest {
        let continuation: CheckedContinuation<JSON, Error>
        let timeoutTask: Task<Void, Never>
    }
    private var pending: [Int: PendingRequest] = [:]
    private var loadedThreadIDs: Set<String> = []
    private struct ActivityHistory {
        var turnID: String
        var tailCursor: String?
        var messages: [ChatMessage] = []
        var isComplete = false
        var updatedAt: Date?
    }
    private var activityHistoryByThread: [String: ActivityHistory] = [:]
    // `thread/items/list` was introduced after some app-server versions that
    // still support the regular thread and turn reads. Remember an unsupported
    // response for this process so selecting every subsequent conversation does
    // not keep asking for an optional endpoint the server cannot provide.
    private var threadItemsListAvailability: Bool? = nil
    private(set) var connected = false
    var onEvent: EventHandler?
    var onServerRequest: ServerRequestHandler?
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
        let decodingWorker = self.decodingWorker
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            decodingWorker.append(data) { objects in
                guard !objects.isEmpty else { return }
                Task { @MainActor [weak self] in
                    self?.handle(objects)
                }
            }
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

    func readRemoteUsage() async throws -> RemoteUsageSnapshot {
        RemoteUsageSnapshot.parse(try await request("account/rateLimits/read", params: [:]))
    }
    func readAccountOverview() async throws -> AccountOverview {
        AccountOverview.parse(try await request("account/rateLimits/read", params: [:]))
    }

    func consumeRemoteReset(_ attempt: RemoteResetAttempt) async throws -> String {
        let snapshot = try await request("account/rateLimits/read", params: [:])
        let summary = snapshot["rateLimitResetCredits"] as? JSON
        let credits = summary?["credits"] as? [JSON] ?? []
        guard let credit = credits.first(where: { row in
            guard let id = row["id"] as? String else { return false }
            return RemoteUsageSnapshot.creditReference(id) == attempt.creditRef
        }), let id = credit["id"] as? String else { return "unavailable" }
        if credit["status"] as? String == "redeemed" { return "alreadyRedeemed" }
        if let expiry = (credit["expiresAt"] as? NSNumber)?.doubleValue, expiry <= Date().timeIntervalSince1970 { return "expired" }
        guard credit["resetType"] as? String == "codexRateLimits" else { return "unavailable" }
        let response = try await request("account/rateLimitResetCredit/consume", params: ["creditId": id, "idempotencyKey": attempt.id])
        guard let outcome = response["outcome"] as? String,
              ["reset", "alreadyRedeemed", "nothingToReset", "noCredit"].contains(outcome) else { throw CodexClientError.invalidResponse }
        return outcome
    }

    func listThreads(limit: Int = 60, cwd: String? = nil) async throws -> ThreadPage {
        let result = try await request("thread/list", params: Self.threadListParameters(limit: limit, cwd: cwd))
        let rows = result["data"] as? [JSON] ?? []
        return ThreadPage(
            threads: rows.compactMap(CodexThread.init(json:)),
            hasMore: result["nextCursor"] is String
        )
    }

    static func threadListParameters(limit: Int = 60, cwd: String? = nil) -> JSON {
        var params: JSON = [
            "limit": limit,
            // User-message recency, not assistant output or completion time.
            "sortKey": "recency_at",
            "sortDirection": "desc",
            "useStateDbOnly": true
        ]
        if let cwd { params["cwd"] = cwd }
        return params
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
        // thread/read is read-only and does not acquire a writer. Only successful
        // thread/start or thread/resume may populate loadedThreadIDs.
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
        let messages = await Task.detached(priority: .userInitiated) {
            Self.parseMessages(from: newestFirst.reversed())
        }.value
        return (thread, messages)
    }

    /// Read-only reconciliation of exact persisted turns, never resume/start/interrupt.
    func readRemoteRecovery(_ tasks: [RemoteRecoveryTask]) async throws -> [String: RemoteTaskStatusBody] {
        guard let first = tasks.first else { return [:] }
        let state = try await readThreadState(first.threadId)
        guard tasks.allSatisfy({ $0.threadId == first.threadId && $0.workspace == state.cwd }) else {
            throw RemoteControlError.server("待核对任务的会话工作区不匹配")
        }
        var pending = tasks.filter { !$0.turnId.isEmpty }
        var updates: [String: RemoteTaskStatusBody] = [:]
        var cursor: String?
        var seen: Set<String> = []
        // Bounded requests. Missing/unsupported/active turns remain running, never guessed failed.
        for _ in 0..<20 where !pending.isEmpty {
            try Task.checkCancellation()
            var params: JSON = ["threadId": first.threadId, "limit": 50, "itemsView": "summary", "sortDirection": "desc"]
            if let cursor { params["cursor"] = cursor }
            let page = try await request("thread/turns/list", params: params)
            guard let turns = page["data"] as? [JSON] else { throw CodexClientError.invalidResponse }
            for turn in turns {
                let matched = pending.filter { $0.turnId == turn["id"] as? String }
                for task in matched { updates[task.taskId] = task.terminalUpdate(from: turn) }
                pending.removeAll { $0.turnId == turn["id"] as? String }
            }
            guard let next = page["nextCursor"] as? String, !next.isEmpty, seen.insert(next).inserted else { break }
            cursor = next
        }
        return updates
    }

    func readRemoteHistory(_ read: RemoteHistoryRead) async throws -> RemoteHistoryPage {
        let state = try await readThreadState(read.threadId)
        guard state.cwd == read.workspace else { throw RemoteControlError.server("会话工作区不匹配") }
        var params: JSON = ["threadId": read.threadId, "limit": 1, "itemsView": "full", "sortDirection": "desc"]
        if !read.cursor.isEmpty { params["cursor"] = read.cursor }
        let response = try await request("thread/turns/list", params: params)
        let ids = Set((response["data"] as? [JSON] ?? []).compactMap { $0["id"] as? String })
        let metadata = await readTurnModelMetadata(for: state, turnIDs: ids)
        return Self.remoteHistoryPage(response, metadata: metadata)
    }

    /// The relay's actual model is sourced only from the exact persisted turn,
    /// never from a request, thread summary, or the currently selected composer.
    func withActualTurnSettings(_ body: RemoteTaskStatusBody) async -> RemoteTaskStatusBody {
        guard !body.threadId.isEmpty, !body.turnId.isEmpty,
              let thread = try? await readThreadState(body.threadId) else { return body }
        let metadata = await readTurnModelMetadata(for: thread, turnIDs: [body.turnId])
        return body.withActualSettings(metadata[body.turnId])
    }

    nonisolated static func remoteHistoryPage(_ response: JSON, metadata: [String: TurnModelMetadata] = [:]) -> RemoteHistoryPage {
        let turns = (response["data"] as? [JSON] ?? []).reversed().map { original -> JSON in
            var turn = original
            turn["items"] = (original["items"] as? [JSON] ?? []).compactMap { originalItem -> JSON? in
                var item = originalItem
                let type = item["type"] as? String ?? ""
                guard ["userMessage", "agentMessage", "reasoning", "plan", "commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch", "imageView"].contains(type) else { return nil }
                item.removeValue(forKey: "arguments")
                if type == "userMessage" {
                    item["content"] = (item["content"] as? [JSON] ?? []).map { part -> JSON in
                        if ["image", "localImage"].contains(part["type"] as? String ?? "") {
                            return ["type": "text", "text": "［图片附件，请在 Mac 查看原图］"]
                        }
                        return part
                    }
                }
                return item
            }
            return turn
        }
        let messages = Self.parseMessages(from: turns, metadataByTurnID: metadata).map { message in
            RemoteHistoryMessage(id: "\(message.turnID ?? ""):\(message.id)",
                role: message.role == .user ? "user" : (message.role == .assistant ? "assistant" : "activity"),
                text: message.text, title: message.activityTitle ?? "",
                timestamp: message.timestamp?.timeIntervalSince1970,
                model: message.model ?? "", effort: message.reasoningEffort ?? "",
                attachments: message.attachments.map { $0.name })
        }
        return RemoteHistoryPage(messages: messages, nextCursor: response["nextCursor"] as? String)
    }

    func readThreadState(_ id: String) async throws -> CodexThread {
        let result = try await request(
            "thread/read",
            params: ["threadId": id, "includeTurns": false]
        )
        guard let json = result["thread"] as? JSON,
              let thread = CodexThread(json: json) else {
            throw CodexClientError.invalidResponse
        }
        return thread
    }

    func readTurnModelMetadata(
        for thread: CodexThread,
        turnIDs: Set<String>
    ) async -> [String: TurnModelMetadata] {
        guard let path = thread.path, !turnIDs.isEmpty else { return [:] }
        return await turnMetadataReader.metadata(filePath: path, turnIDs: turnIDs)
    }

    func readLatestThreadActivity(
        _ id: String,
        knownThread: CodexThread? = nil
    ) async throws -> ThreadActivitySnapshot {
        let thread: CodexThread
        if let knownThread {
            thread = knownThread
        } else {
            thread = try await readThreadState(id)
        }
        let turnsResult = try await request(
            "thread/turns/list",
            params: [
                "threadId": id,
                "limit": 1,
                // Read turn metadata cheaply; actual process items are fetched
                // below via the paginated item endpoint, not from this summary.
                "itemsView": "summary",
                "sortDirection": "desc"
            ]
        )
        let latestTurn = (turnsResult["data"] as? [JSON])?.first
        let runtime = latestTurn.flatMap(Self.parseTurnRuntime)
        let turnIDs = Set(latestTurn.flatMap { $0["id"] as? String }.map { [$0] } ?? [])
        let metadata = await readTurnModelMetadata(for: thread, turnIDs: turnIDs)
        guard let latestTurn, let runtime else {
            return ThreadActivitySnapshot(thread: thread, turn: runtime, messages: [])
        }
        var history = activityHistoryByThread[id].flatMap { $0.turnID == runtime.id ? $0 : nil }
            ?? ActivityHistory(turnID: runtime.id)
        if history.updatedAt != thread.updatedAt { history.isComplete = false }
        if threadItemsListAvailability == false {
            return ThreadActivitySnapshot(thread: thread, turn: runtime, messages: history.messages)
        }
        if !history.isComplete {
            // Summary contains only user/final messages. Read actual activities
            // in small pages, retaining the last page cursor for the next poll
            // so a still-running item can grow without re-reading the whole turn.
            for _ in 0..<8 {
                try Task.checkCancellation()
                var params: JSON = ["threadId": id, "turnId": runtime.id,
                                    "limit": 24, "sortDirection": "asc"]
                if let cursor = history.tailCursor { params["cursor"] = cursor }
                let page: JSON
                do {
                    page = try await request("thread/items/list", params: params)
                    threadItemsListAvailability = true
                } catch {
                    guard Self.isUnsupportedThreadItemsListError(error) else { throw error }
                    threadItemsListAvailability = false
                    // The normal thread read already supplied the user and final
                    // messages. Keep that usable view and stop retrying this
                    // optional activity stream for this app-server connection.
                    history.isComplete = true
                    history.updatedAt = thread.updatedAt
                    activityHistoryByThread[id] = history
                    return ThreadActivitySnapshot(thread: thread, turn: runtime, messages: history.messages)
                }
                let entries = page["data"] as? [JSON] ?? []
                let decoded = await Task.detached(priority: .userInitiated) {
                    var turn = latestTurn
                    turn["items"] = entries.compactMap { $0["item"] as? JSON }
                    return Self.parseMessages(from: [turn], metadataByTurnID: metadata)
                }.value
                history.messages = ConversationHistory.merge(snapshot: decoded, cached: history.messages)
                if let next = page["nextCursor"] as? String, next != history.tailCursor {
                    history.tailCursor = next
                } else {
                    history.isComplete = !runtime.isActive
                    break
                }
            }
            // Only normalized, clipped activity text is cached, never raw tool
            // output. Additional pages continue on the next lightweight poll.
            history.updatedAt = thread.updatedAt
            activityHistoryByThread[id] = history
        }
        return ThreadActivitySnapshot(thread: thread, turn: runtime, messages: history.messages)
    }

    func hasMoreActivityHistory(_ threadID: String) -> Bool {
        activityHistoryByThread[threadID]?.isComplete == false
    }

    nonisolated static func isUnsupportedThreadItemsListError(_ error: Error) -> Bool {
        let message: String
        if case let CodexClientError.server(serverMessage) = error {
            message = serverMessage
        } else {
            message = error.localizedDescription
        }
        return message.localizedCaseInsensitiveContains("thread/items/list")
            && message.localizedCaseInsensitiveContains("not supported")
    }

    func shouldRefreshActivity(_ thread: CodexThread) -> Bool {
        hasMoreActivityHistory(thread.id) || activityHistoryByThread[thread.id]?.updatedAt != thread.updatedAt
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
        permissions: String?,
        serviceTierForTurn: String?,
        approvalPolicy: String? = nil,
        approvalsReviewer: String? = nil
    ) async throws -> String? {
        let params = Self.turnStartParameters(
            threadID: threadID,
            text: text,
            attachments: attachments,
            model: model,
            effort: effort,
            permissions: permissions,
            serviceTierForTurn: serviceTierForTurn,
            approvalPolicy: approvalPolicy,
            approvalsReviewer: approvalsReviewer
        )
        let result = try await request(
            "turn/start",
            params: params
        )
        return (result["turn"] as? JSON)?["id"] as? String
    }

    static func turnStartParameters(
        threadID: String,
        text: String,
        attachments: [ComposerAttachment],
        model: String?,
        effort: String?,
        permissions: String?,
        serviceTierForTurn: String?,
        approvalPolicy: String? = nil,
        approvalsReviewer: String? = nil
    ) -> JSON {
        var input: [[String: Any]] = []
        if !text.isEmpty { input.append(["type": "text", "text": text]) }
        input.append(contentsOf: attachments.map(\.userInput))
        var params: JSON = ["threadId": threadID, "input": input]
        if let model { params["model"] = model }
        if let effort { params["effort"] = effort }
        if let permissions { params["permissions"] = permissions }
        if let serviceTierForTurn { params["serviceTierForTurn"] = serviceTierForTurn }
        if let approvalPolicy { params["approvalPolicy"] = approvalPolicy }
        if let approvalsReviewer { params["approvalsReviewer"] = approvalsReviewer }
        return params
    }

    func interruptTurn(threadID: String, turnID: String) async throws {
        _ = try await request(
            "turn/interrupt",
            params: ["threadId": threadID, "turnId": turnID]
        )
    }

    func steerTurn(threadID: String, turnID: String, text: String, attachments: [ComposerAttachment]) async throws {
        var input: [JSON] = text.isEmpty ? [] : [["type": "text", "text": text]]
        input.append(contentsOf: attachments.map(\.userInput))
        _ = try await request("turn/steer", params: [
            "threadId": threadID, "expectedTurnId": turnID, "input": input
        ])
    }

    private func request(_ method: String, params: JSON) async throws -> JSON {
        guard process?.isRunning == true, input != nil else {
            throw CodexClientError.notRunning
        }
        let id = nextID
        nextID += 1
        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                guard !Task.isCancelled else { return }
                self?.timeoutRequest(id, method: method)
            }
            pending[id] = PendingRequest(
                continuation: continuation,
                timeoutTask: timeoutTask
            )
            do {
                try send(["id": id, "method": method, "params": params])
            } catch {
                pending.removeValue(forKey: id)?.timeoutTask.cancel()
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

    func respond(to requestID: AppServerRequestID, result: JSON) throws {
        try send(["id": requestID.jsonValue, "result": result])
    }

    private func handle(_ objects: [JSON]) {
        for object in objects {
            handle(object)
        }
    }

    private func handle(_ object: JSON) {
        // A bidirectional JSON-RPC server request can reuse a numeric id from
        // our outbound request namespace. A method identifies it as a request,
        // so dispatch it before looking for an outbound response.
        if let method = object["method"] as? String,
           let params = object["params"] as? JSON {
            if let rawID = object["id"], let requestID = AppServerRequestID(rawID) {
                onServerRequest?(requestID, method, params)
                return
            }
            onEvent?(method, params)
            return
        }
        if let idNumber = object["id"] as? NSNumber,
           let request = pending.removeValue(forKey: idNumber.intValue) {
            request.timeoutTask.cancel()
            if let error = object["error"] as? JSON {
                let message = error["message"] as? String ?? "Codex 请求失败"
                request.continuation.resume(throwing: CodexClientError.server(message))
            } else if let result = object["result"] as? JSON {
                request.continuation.resume(returning: result)
            } else {
                request.continuation.resume(throwing: CodexClientError.invalidResponse)
            }
            return
        }
    }

    private func handleTermination(_ status: Int32) {
        connected = false
        loadedThreadIDs.removeAll()
        let error = CodexClientError.process("Codex 本地服务已退出（状态码 \(status)）")
        let callbacks = pending.values
        pending.removeAll()
        callbacks.forEach {
            $0.timeoutTask.cancel()
            $0.continuation.resume(throwing: error)
        }
        onDisconnect?(error.localizedDescription)
    }

    private func timeoutRequest(_ id: Int, method: String) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: CodexClientError.timeout(method))
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

    nonisolated static func parseMessages<S: Sequence>(
        from turns: S,
        metadataByTurnID: [String: TurnModelMetadata] = [:]
    ) -> [ChatMessage] where S.Element == JSON {
        var messages: [ChatMessage] = []
        for turn in turns {
            let turnID = turn["id"] as? String
            let turnMetadata = turnID.flatMap { metadataByTurnID[$0] }
            let turnStartedAt = Self.unixDate(turn["startedAt"])
            let turnCompletedAt = Self.unixDate(turn["completedAt"])
            guard let items = turn["items"] as? [JSON] else { continue }
            for item in items {
                guard let type = item["type"] as? String else { continue }
                let id = item["id"] as? String ?? UUID().uuidString
                let messageStart = messages.count
                switch type {
                case "userMessage":
                    let content = item["content"] as? [JSON] ?? []
                    let rawText = content.compactMap { part in
                        part["type"] as? String == "text" ? part["text"] as? String : nil
                    }.joined(separator: "\n")
                    let text = UserMessageContentParser.visibleText(from: rawText)
                    let attachments = content.compactMap { part -> ChatMessageAttachment? in
                        switch part["type"] as? String {
                        case "localImage":
                            guard let path = part["path"] as? String else { return nil }
                            return ChatMessageAttachment(path: path, kind: .image)
                        case "mention":
                            let path = part["path"] as? String ?? ""
                            let name = part["name"] as? String ?? (path.isEmpty ? "文件" : nil)
                            return ChatMessageAttachment(path: path, name: name, kind: .file)
                        default:
                            return nil
                        }
                    }
                    if !text.isEmpty || !attachments.isEmpty {
                        messages.append(.init(
                            id: id,
                            role: .user,
                            text: text,
                            attachments: attachments,
                            timestamp: turnStartedAt,
                            turnID: turnID,
                            model: turnMetadata?.model,
                            reasoningEffort: turnMetadata?.reasoningEffort
                        ))
                    }
                case "agentMessage":
                    if let text = item["text"] as? String, !text.isEmpty {
                        messages.append(.init(
                            id: id,
                            role: .assistant,
                            text: text,
                            timestamp: turnCompletedAt,
                            turnID: turnID,
                            model: turnMetadata?.model,
                            reasoningEffort: turnMetadata?.reasoningEffort
                        ))
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
                case "imageGeneration":
                    if let image = GeneratedImageMessage.fromItem(item) { messages.append(image) }
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
                for index in messageStart..<messages.count {
                    messages[index].turnID = turnID
                    // Only explicit running statuses are active: a finished
                    // tool in an active turn must not keep spinning forever.
                    if messages[index].role == .activity,
                       let status = item["status"] as? String {
                        messages[index].isStreaming = status == "inProgress"
                        messages[index].activityStatus = localizedStatus(status)
                    }
                }
            }
        }
        return messages
    }

    nonisolated private static func unixDate(_ value: Any?) -> Date? {
        let rawValue: Double?
        if let number = value as? NSNumber {
            rawValue = number.doubleValue
        } else if let number = value as? Double {
            rawValue = number
        } else if let number = value as? Int {
            rawValue = Double(number)
        } else {
            rawValue = nil
        }
        guard let rawValue, rawValue > 0 else { return nil }
        let seconds = rawValue > 100_000_000_000 ? rawValue / 1_000 : rawValue
        return Date(timeIntervalSince1970: seconds)
    }

    private static func parseTurnRuntime(_ turn: JSON) -> TurnRuntimeState? {
        guard let id = turn["id"] as? String,
              let status = turn["status"] as? String else { return nil }
        let startedAt = (turn["startedAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue)
        }
        let completedAt = (turn["completedAt"] as? NSNumber).map {
            Date(timeIntervalSince1970: $0.doubleValue)
        }
        return TurnRuntimeState(id: id, status: status, startedAt: startedAt, completedAt: completedAt)
    }

    nonisolated private static func clippedActivityText(_ text: String) -> String {
        let limit = 12_000
        guard text.count > limit else { return text }
        return "…已省略较早输出…\n" + String(text.suffix(limit))
    }

    nonisolated private static func jsonPreview(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return clippedActivityText(text)
    }

    nonisolated private static func localizedStatus(_ status: String?) -> String {
        switch status {
        case "inProgress": return "进行中"
        case "failed": return "失败"
        case "declined": return "已拒绝"
        case "interrupted": return "已停止"
        default: return "已完成"
        }
    }
}

/// Reads the per-turn model recorded in Codex's local JSONL session without
/// putting large history files on the main actor. The cache only scans bytes
/// appended since the previous request, which keeps active-task polling cheap.
actor TurnMetadataReader {
    private struct FileCache {
        var scannedThrough: UInt64 = 0
        var metadataByTurnID: [String: TurnModelMetadata] = [:]
    }

    private var caches: [String: FileCache] = [:]
    private let chunkSize: UInt64 = 1_048_576
    private let overlapSize: UInt64 = 16_384

    func metadata(filePath: String, turnIDs: Set<String>) -> [String: TurnModelMetadata] {
        guard !turnIDs.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
              let sizeNumber = attributes[.size] as? NSNumber else { return [:] }

        let fileSize = sizeNumber.uint64Value
        var cache = caches[filePath] ?? FileCache()
        if fileSize < cache.scannedThrough {
            cache = FileCache()
        }

        if fileSize > cache.scannedThrough,
           let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: filePath)) {
            scan(
                handle: handle,
                primaryRange: cache.scannedThrough..<fileSize,
                fileSize: fileSize,
                metadataByTurnID: &cache.metadataByTurnID
            )
            try? handle.close()
            cache.scannedThrough = fileSize
            caches[filePath] = cache
        }

        return Dictionary(uniqueKeysWithValues: turnIDs.compactMap { turnID in
            cache.metadataByTurnID[turnID].map { (turnID, $0) }
        })
    }

    private func scan(
        handle: FileHandle,
        primaryRange: Range<UInt64>,
        fileSize: UInt64,
        metadataByTurnID: inout [String: TurnModelMetadata]
    ) {
        var blockStart = primaryRange.lowerBound
        while blockStart < primaryRange.upperBound {
            let blockEnd = min(primaryRange.upperBound, blockStart + chunkSize)
            let readStart = blockStart > overlapSize ? blockStart - overlapSize : 0
            let readEnd = min(fileSize, blockEnd + overlapSize)
            do {
                try handle.seek(toOffset: readStart)
                guard let data = try handle.read(upToCount: Int(readEnd - readStart)),
                      !data.isEmpty else { break }
                parseTurnContexts(
                    String(decoding: data, as: UTF8.self),
                    metadataByTurnID: &metadataByTurnID
                )
            } catch {
                break
            }
            blockStart = blockEnd
        }
    }

    private func parseTurnContexts(
        _ text: String,
        metadataByTurnID: inout [String: TurnModelMetadata]
    ) {
        let marker = "\"type\":\"turn_context\""
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let markerRange = text.range(of: marker, range: searchStart..<text.endIndex) {
            let lineStart = text[..<markerRange.lowerBound].lastIndex(of: "\n")
                .map { text.index(after: $0) }
                ?? text.startIndex
            let lineEnd = text[markerRange.upperBound...].firstIndex(of: "\n") ?? text.endIndex
            let line = String(text[lineStart..<lineEnd])
            if let data = line.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               object["type"] as? String == "turn_context",
               let payload = object["payload"] as? [String: Any],
               let turnID = payload["turn_id"] as? String {
                metadataByTurnID[turnID] = TurnModelMetadata(
                    model: payload["model"] as? String,
                    reasoningEffort: payload["effort"] as? String
                )
            }
            searchStart = markerRange.upperBound
        }
    }
}

/// Incrementally splits and decodes app-server's newline-delimited JSON away
/// from the main actor. `scannedByteCount` prevents every incoming chunk from
/// rescanning a partially received multi-megabyte JSON line from its beginning.
struct JSONLineDecoder {
    typealias JSON = [String: Any]

    private var buffer = Data()
    private var scannedByteCount = 0

    mutating func consume(_ data: Data) -> [JSON] {
        guard !data.isEmpty else { return [] }
        buffer.append(data)

        var objects: [JSON] = []
        var lineStart = buffer.startIndex
        var searchStart = buffer.index(
            buffer.startIndex,
            offsetBy: min(scannedByteCount, buffer.count)
        )

        while searchStart < buffer.endIndex,
              let newline = buffer[searchStart...].firstIndex(of: 0x0A) {
            if lineStart < newline {
                let line = Data(buffer[lineStart..<newline])
                if let object = try? JSONSerialization.jsonObject(with: line) as? JSON {
                    objects.append(object)
                }
            }
            lineStart = buffer.index(after: newline)
            searchStart = lineStart
        }

        if lineStart > buffer.startIndex {
            buffer = Data(buffer[lineStart...])
        }
        // The remaining suffix was already searched and contains no newline.
        // The next call only needs to inspect bytes appended after this point.
        scannedByteCount = buffer.count
        return objects
    }
}

private final class JSONLineDecodingWorker: @unchecked Sendable {
    typealias JSON = [String: Any]

    private let queue = DispatchQueue(
        label: "com.zhengyuntao.cloudcodex.app-server-decoder",
        qos: .userInitiated
    )
    private var decoder = JSONLineDecoder()

    func append(_ data: Data, completion: @escaping ([JSON]) -> Void) {
        queue.async { [self] in
            completion(decoder.consume(data))
        }
    }
}
