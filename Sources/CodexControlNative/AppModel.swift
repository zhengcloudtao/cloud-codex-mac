import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var threads: [CodexThread] = []
    @Published var folderCatalog: [WorkspaceFolder] = []
    @Published var selectedFolder: String?
    @Published var selectedThreadID: String?
    @Published var messages: [ChatMessage] = []
    @Published var composerText = ""
    @Published var searchText = ""
    @Published var connectionText = "正在连接…"
    @Published var isLoading = false
    @Published var isSending = false
    @Published var isExternalThreadProcessing = false
    @Published var threadOwnershipNotice: String?
    @Published var hasMoreThreads = false
    @Published var errorMessage: String?
    @Published var showingNewThread = false
    @Published var newThreadFolder = ""
    @Published var newThreadPrompt = ""
    @Published var modelOptions: [CodexModelOption] = []
    @Published var permissionProfiles: [PermissionProfileOption] = []
    @Published var selectedModelID: String?
    @Published var selectedEffort: String?
    @Published var selectedPermissionID: String? = ":danger-full-access"
    @Published var attachments: [ComposerAttachment] = []
    @Published var isRecording = false
    @Published var activeTurnID: String?
    @Published private(set) var workspaceOrganization = WorkspaceOrganization()
    @Published var showingCategoryManager = false
    @Published var showingCategoryEditor = false
    @Published var editingCategoryID: String?
    @Published var categoryNameDraft = ""
    @Published var categoryEditorError: String?

    private let client = AppServerClient()
    private let speech = SpeechInputController()
    private var hasStarted = false
    private var threadRequestGeneration = 0
    private var selectedThreadMonitorTask: Task<Void, Never>?
    private var threadStatusMonitorTask: Task<Void, Never>?
    private var turnProgressHintTask: Task<Void, Never>?
    private let workspaceOrganizationKey = "CloudCodex.workspaceOrganization.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: workspaceOrganizationKey),
           let saved = try? JSONDecoder().decode(WorkspaceOrganization.self, from: data) {
            workspaceOrganization = saved
        }
        speech.onTranscript = { [weak self] transcript in self?.composerText = transcript }
        speech.onRecordingChanged = { [weak self] recording in self?.isRecording = recording }
        speech.onError = { [weak self] message in self?.errorMessage = message }
    }

    var folders: [WorkspaceFolder] {
        folderCatalog
    }

    var workspaceCategories: [WorkspaceCategory] {
        workspaceOrganization.categories
    }

    var uncategorizedFolders: [WorkspaceFolder] {
        workspaceOrganization.orderedFolders(
            folderCatalog.filter { workspaceOrganization.categoryID(forFolder: $0.path) == nil }
        )
    }

    func folders(inCategory categoryID: String) -> [WorkspaceFolder] {
        workspaceOrganization.orderedFolders(
            folderCatalog.filter { workspaceOrganization.categoryID(forFolder: $0.path) == categoryID }
        )
    }

    func categoryID(forFolder path: String) -> String? {
        workspaceOrganization.categoryID(forFolder: path)
    }

    func assignFolders(_ paths: [String], to categoryID: String?) {
        workspaceOrganization.assignFolders(paths, to: categoryID)
        saveWorkspaceOrganization()
    }

    func moveFolders(_ paths: [String], to categoryID: String?, before targetPath: String? = nil) {
        workspaceOrganization.moveFolders(
            paths,
            to: categoryID,
            before: targetPath,
            knownFolderPaths: folderCatalog.map(\.path)
        )
        saveWorkspaceOrganization()
    }

    func beginCreatingCategory() {
        editingCategoryID = nil
        categoryNameDraft = ""
        categoryEditorError = nil
        showingCategoryEditor = true
    }

    func beginRenamingCategory(_ category: WorkspaceCategory) {
        editingCategoryID = category.id
        categoryNameDraft = category.name
        categoryEditorError = nil
        showingCategoryEditor = true
    }

    func saveCategoryEditor() {
        let name = categoryNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            categoryEditorError = "分类名称不能为空。"
            return
        }
        let succeeded: Bool
        if let editingCategoryID {
            succeeded = workspaceOrganization.renameCategory(id: editingCategoryID, to: name)
        } else {
            succeeded = workspaceOrganization.addCategory(named: name) != nil
        }
        guard succeeded else {
            categoryEditorError = "已经存在同名分类，请换一个名称。"
            return
        }
        saveWorkspaceOrganization()
        showingCategoryEditor = false
    }

    func deleteCategory(_ id: String) {
        workspaceOrganization.deleteCategory(id: id)
        saveWorkspaceOrganization()
    }

    func moveCategory(_ id: String, offset: Int) {
        workspaceOrganization.moveCategory(id: id, offset: offset)
        saveWorkspaceOrganization()
    }

    func moveCategory(_ id: String, relativeTo targetID: String, placeAfter: Bool) {
        workspaceOrganization.moveCategory(id: id, relativeTo: targetID, placeAfter: placeAfter)
        saveWorkspaceOrganization()
    }

    func moveCategoryToEnd(_ id: String) {
        workspaceOrganization.moveCategoryToEnd(id: id)
        saveWorkspaceOrganization()
    }

    private func saveWorkspaceOrganization() {
        guard let data = try? JSONEncoder().encode(workspaceOrganization) else { return }
        UserDefaults.standard.set(data, forKey: workspaceOrganizationKey)
    }

    var visibleThreads: [CodexThread] {
        threads.filter { thread in
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesSearch = query.isEmpty
                || thread.displayName.localizedCaseInsensitiveContains(query)
                || thread.visiblePreview.localizedCaseInsensitiveContains(query)
            return matchesSearch
        }
    }

    var selectedThread: CodexThread? {
        threads.first { $0.id == selectedThreadID }
    }

    var selectedModel: CodexModelOption? {
        modelOptions.first { $0.id == selectedModelID }
    }

    var selectedPermission: PermissionProfileOption? {
        permissionProfiles.first { $0.id == selectedPermissionID }
    }

    var availableEfforts: [String] {
        selectedModel?.supportedEfforts ?? []
    }

    var canSend: Bool {
        (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
            && !isSending
            && !isExternalThreadProcessing
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        client.onEvent = { [weak self] method, params in self?.handleEvent(method, params) }
        client.onDisconnect = { [weak self] message in
            self?.connectionText = "未连接"
            self?.errorMessage = message
        }
        do {
            try await client.start()
            connectionText = "已连接本机 Codex"
            await loadComposerOptions(cwd: nil)
            await loadFolderCatalog()
            await refreshThreads()
            startThreadStatusMonitor()
        } catch {
            connectionText = "连接失败"
            errorMessage = error.localizedDescription
        }
    }

    func refreshThreads() async {
        threadRequestGeneration += 1
        let generation = threadRequestGeneration
        let requestedFolder = selectedFolder
        isLoading = true
        defer {
            if generation == threadRequestGeneration { isLoading = false }
        }
        do {
            let page = try await client.listThreads(limit: 60, cwd: requestedFolder)
            guard generation == threadRequestGeneration,
                  requestedFolder == selectedFolder else { return }
            threads = page.threads
            hasMoreThreads = page.hasMore
            if selectedFolder == nil {
                mergeRecentFolders(from: page.threads)
            } else if let path = selectedFolder,
                      let index = folderCatalog.firstIndex(where: { $0.path == path }) {
                folderCatalog[index].threadCount = page.hasMore ? nil : page.threads.count
            }
        } catch {
            guard generation == threadRequestGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func startThreadStatusMonitor() {
        threadStatusMonitorTask?.cancel()
        threadStatusMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.syncVisibleThreadStatuses()
            }
        }
    }

    /// Refresh only the lightweight thread summaries currently represented in
    /// the list. This deliberately avoids loading turns or message history.
    private func syncVisibleThreadStatuses() async {
        let requestedFolder = selectedFolder
        do {
            let page = try await client.listThreads(limit: 60, cwd: requestedFolder)
            guard requestedFolder == selectedFolder else { return }
            let statuses = Dictionary(uniqueKeysWithValues: page.threads.map { ($0.id, $0.status) })
            for index in threads.indices {
                let threadID = threads[index].id
                guard let status = statuses[threadID] else { continue }
                // Keep the optimistic light on while this app is submitting or
                // streaming a turn; app-server's list snapshot can lag briefly.
                if isSending, threadID == selectedThreadID { continue }
                threads[index].status = status
            }
        } catch {
            // Status lights are best-effort and must never interrupt the task.
        }
    }

    private func setThreadRunning(_ threadID: String, running: Bool) {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[index].status = running ? "active" : "idle"
    }

    func selectFolder(_ path: String?) {
        selectedThreadMonitorTask?.cancel()
        selectedThreadMonitorTask = nil
        isExternalThreadProcessing = false
        threadOwnershipNotice = nil
        selectedFolder = path
        selectedThreadID = nil
        threads = []
        messages = []
        hasMoreThreads = false
        searchText = ""
        Task {
            await loadPermissionProfiles(cwd: path)
            await refreshThreads()
        }
    }

    func selectThread(_ id: String?) {
        selectedThreadMonitorTask?.cancel()
        selectedThreadMonitorTask = nil
        isExternalThreadProcessing = false
        threadOwnershipNotice = nil
        selectedThreadID = id
        guard let id else {
            messages = []
            return
        }
        selectedThreadMonitorTask = Task { [weak self] in
            guard let self else { return }
            await self.loadSelectedThread()
            await self.syncLatestExternalActivity(threadID: id)
            while !Task.isCancelled, self.selectedThreadID == id {
                let delaySeconds: UInt64 = self.isExternalThreadProcessing ? 2 : 5
                try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self.syncLatestExternalActivity(threadID: id)
            }
        }
    }

    func loadSelectedThread() async {
        guard let id = selectedThreadID else {
            messages = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let (updated, loadedMessages) = try await client.readThread(id)
            if let index = threads.firstIndex(where: { $0.id == id }) { threads[index] = updated }
            if selectedThreadID == id {
                messages = loadedMessages
                if let model = updated.model,
                   modelOptions.contains(where: { $0.id == model }) {
                    selectModel(model, preferredEffort: updated.reasoningEffort)
                }
                await loadPermissionProfiles(cwd: updated.cwd)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func sendMessage() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoingAttachments = attachments
        guard (!text.isEmpty || !outgoingAttachments.isEmpty),
              let id = selectedThreadID, !isSending, !isExternalThreadProcessing else { return }

        speech.stop()
        composerText = ""
        attachments = []
        isSending = true
        isExternalThreadProcessing = false
        setThreadRunning(id, running: true)
        threadOwnershipNotice = nil
        let localAttachments = outgoingAttachments.map {
            ChatMessageAttachment(
                path: $0.url.path,
                name: $0.url.lastPathComponent,
                kind: $0.isImage ? .image : .file
            )
        }
        let localMessageID = "local-\(UUID().uuidString)"
        messages.append(.init(
            id: localMessageID,
            role: .user,
            text: text,
            attachments: localAttachments
        ))
        beginTurnProgress()
        do {
            try await client.resumeThread(id)
            activeTurnID = try await client.startTurn(
                threadID: id,
                text: text,
                attachments: outgoingAttachments,
                model: selectedModel?.model,
                effort: selectedEffort,
                permissions: selectedPermissionID
            )
        } catch {
            handleSendFailure(
                error,
                threadID: id,
                localMessageID: localMessageID,
                text: text,
                outgoingAttachments: outgoingAttachments
            )
        }
    }

    func handleSendFailure(
        _ error: Error,
        threadID: String,
        localMessageID: String,
        text: String,
        outgoingAttachments: [ComposerAttachment]
    ) {
        rollbackOptimisticSend(
            threadID: threadID,
            localMessageID: localMessageID,
            text: text,
            outgoingAttachments: outgoingAttachments
        )
        if Self.isActiveWriterError(error) {
            errorMessage = nil
            threadOwnershipNotice = "此会话已在 Codex 主应用中打开。关闭原窗口后，再点击发送即可继续。"
        } else {
            errorMessage = error.localizedDescription
        }
    }

    func rollbackOptimisticSend(
        threadID: String,
        localMessageID: String,
        text: String,
        outgoingAttachments: [ComposerAttachment]
    ) {
        isSending = false
        activeTurnID = nil
        setThreadRunning(threadID, running: false)
        turnProgressHintTask?.cancel()
        turnProgressHintTask = nil
        messages.removeAll { $0.id == localMessageID || $0.id == "turn-progress" }
        guard selectedThreadID == threadID else { return }
        composerText = text
        attachments = outgoingAttachments
    }

    static func isActiveWriterError(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("active writer")
    }

    func cancelTurn() async {
        guard let threadID = selectedThreadID, let turnID = activeTurnID else { return }
        do {
            try await client.interruptTurn(threadID: threadID, turnID: turnID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func syncLatestExternalActivity(threadID: String) async {
        guard selectedThreadID == threadID, !isSending else { return }
        do {
            let thread = try await client.readThreadState(threadID)
            guard selectedThreadID == threadID, !isSending else { return }
            let snapshot: ThreadActivitySnapshot
            if thread.status == "active" || isExternalThreadProcessing {
                snapshot = try await client.readLatestThreadActivity(
                    threadID,
                    knownThread: thread
                )
            } else {
                snapshot = ThreadActivitySnapshot(thread: thread, turn: nil, messages: [])
            }
            guard selectedThreadID == threadID, !isSending else { return }
            applyExternalActivitySnapshot(snapshot, threadID: threadID)
        } catch {
            // Monitoring is best-effort. The primary app-server connection and
            // manual refresh remain available if another Codex process is busy.
        }
    }

    func applyExternalActivitySnapshot(_ snapshot: ThreadActivitySnapshot, threadID: String) {
        guard selectedThreadID == threadID, !isSending else { return }
        if let index = threads.firstIndex(where: { $0.id == threadID }) {
            threads[index] = snapshot.thread
        }

        let wasStartedAt = messages.first(where: { $0.id == "turn-progress" })?.startedAt
        let latestIDs = Set(snapshot.messages.map(\.id))
        var merged = messages.filter { $0.id != "turn-progress" && !latestIDs.contains($0.id) }
        let isActive = snapshot.turn?.isActive == true || snapshot.thread.status == "active"

        if isActive {
            let startedAt = snapshot.turn?.startedAt ?? wasStartedAt ?? Date()
            let progress = ChatMessage(
                id: "turn-progress",
                role: .activity,
                text: "Codex 主应用正在处理这个任务，最新进度会自动同步。",
                isStreaming: true,
                activityKind: .status,
                activityTitle: "Codex 正在处理",
                activityStatus: "进行中",
                startedAt: startedAt
            )
            if let lastUserIndex = snapshot.messages.lastIndex(where: { $0.role == .user }) {
                merged.append(contentsOf: snapshot.messages[...lastUserIndex])
                merged.append(progress)
                let nextIndex = snapshot.messages.index(after: lastUserIndex)
                if nextIndex < snapshot.messages.endIndex {
                    merged.append(contentsOf: snapshot.messages[nextIndex...])
                }
            } else {
                merged.append(progress)
                merged.append(contentsOf: snapshot.messages)
            }
        } else {
            merged.append(contentsOf: snapshot.messages)
        }

        messages = merged
        isExternalThreadProcessing = isActive
    }

    func chooseNewThreadFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择 Codex 工作文件夹"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            newThreadFolder = url.path
        }
    }

    func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.title = "添加到 Codex"
        panel.prompt = "添加"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            let newItems = panel.urls
                .filter { url in !attachments.contains(where: { $0.url == url }) }
                .map { ComposerAttachment(url: $0) }
            attachments.append(contentsOf: newItems)
        }
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    func toggleDictation() {
        speech.toggle(currentText: composerText)
    }

    func selectModel(_ id: String, preferredEffort: String? = nil) {
        guard let option = modelOptions.first(where: { $0.id == id }) else { return }
        selectedModelID = id
        if let preferredEffort, option.supportedEfforts.contains(preferredEffort) {
            selectedEffort = preferredEffort
        } else if let selectedEffort, option.supportedEfforts.contains(selectedEffort) {
            self.selectedEffort = selectedEffort
        } else {
            selectedEffort = option.defaultEffort
        }
    }

    func prepareNewThread() {
        newThreadFolder = selectedFolder ?? FileManager.default.homeDirectoryForCurrentUser.path
        newThreadPrompt = ""
        showingNewThread = true
    }

    func createThread() async {
        let folder = newThreadFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty else { return }
        isLoading = true
        do {
            let thread = try await client.createThread(
                cwd: folder,
                model: selectedModel?.model,
                permissions: selectedPermissionID
            )
            threads.insert(thread, at: 0)
            selectedFolder = folder
            selectedThreadID = thread.id
            messages = []
            showingNewThread = false
            let prompt = newThreadPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            isLoading = false
            if !prompt.isEmpty {
                composerText = prompt
                await sendMessage()
            }
            await refreshThreads()
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    private func loadFolderCatalog() async {
        do {
            folderCatalog = try await client.listWorkspaceFolders()
        } catch {
            // Older app-server builds may not expose project/list. Recent thread
            // folders will still populate the sidebar on the next request.
            folderCatalog = []
        }
    }

    private func loadComposerOptions(cwd: String?) async {
        do {
            modelOptions = try await client.listModels()
            let preferred = selectedThread?.model
                ?? modelOptions.first(where: { $0.id == selectedModelID })?.id
                ?? modelOptions.first(where: { $0.id == "gpt-5.6-sol" })?.id
                ?? modelOptions.first?.id
            if let preferred { selectModel(preferred, preferredEffort: selectedThread?.reasoningEffort) }
        } catch {
            errorMessage = "无法读取 Codex 模型列表：\(error.localizedDescription)"
        }
        await loadPermissionProfiles(cwd: cwd)
    }

    private func loadPermissionProfiles(cwd: String?) async {
        do {
            permissionProfiles = try await client.listPermissionProfiles(cwd: cwd)
            if !permissionProfiles.contains(where: { $0.id == selectedPermissionID }) {
                selectedPermissionID = permissionProfiles.first(where: { $0.id == ":danger-full-access" })?.id
                    ?? permissionProfiles.first?.id
            }
        } catch {
            errorMessage = "无法读取 Codex 权限模式：\(error.localizedDescription)"
        }
    }

    private func mergeRecentFolders(from recentThreads: [CodexThread]) {
        let grouped = Dictionary(grouping: recentThreads, by: \.cwd)
        for (path, rows) in grouped {
            let latest = rows.map(\.updatedAt).max() ?? .distantPast
            if let index = folderCatalog.firstIndex(where: { $0.path == path }) {
                folderCatalog[index].threadCount = rows.count
            } else {
                folderCatalog.append(.init(path: path, threadCount: rows.count, latestUpdate: latest))
            }
        }
        folderCatalog.sort { $0.latestUpdate > $1.latestUpdate }
    }

    func handleEvent(_ method: String, _ params: [String: Any]) {
        guard let eventThreadID = params["threadId"] as? String else {
            if method == "error", let error = params["error"] as? [String: Any] {
                isSending = false
                activeTurnID = nil
                finishTurnProgress(status: "失败")
                errorMessage = error["message"] as? String ?? "Codex 发生错误"
            }
            return
        }
        if method == "turn/started" {
            setThreadRunning(eventThreadID, running: true)
        } else if method == "turn/completed" {
            setThreadRunning(eventThreadID, running: false)
        }

        guard eventThreadID == selectedThreadID else {
            if method == "turn/completed" { Task { await syncVisibleThreadStatuses() } }
            return
        }

        switch method {
        case "turn/started":
            if let turn = params["turn"] as? [String: Any] {
                activeTurnID = turn["id"] as? String ?? activeTurnID
            }
            upsertActivity(
                id: "turn-progress",
                kind: .status,
                title: "Codex 正在处理",
                text: "请求已发送，正在等待 Codex 返回第一条实时进度…",
                status: "进行中",
                isStreaming: true
            )
            if let index = messages.firstIndex(where: { $0.id == "turn-progress" }),
               messages[index].startedAt == nil {
                messages[index].startedAt = Date()
            }
        case "item/started":
            guard let item = params["item"] as? [String: Any] else { return }
            updateActivityItem(item, completed: false)
        case "item/reasoning/summaryTextDelta":
            guard let delta = params["delta"] as? String else { return }
            appendActivity(
                id: params["itemId"] as? String ?? "reasoning",
                kind: .reasoning,
                title: "思考摘要",
                delta: delta
            )
        case "item/reasoning/summaryPartAdded":
            upsertActivity(
                id: params["itemId"] as? String ?? "reasoning",
                kind: .reasoning,
                title: "思考摘要",
                text: "正在整理当前推理结果…",
                status: "进行中",
                isStreaming: true
            )
        case "item/reasoning/textDelta":
            guard let delta = params["delta"] as? String else { return }
            let itemID = params["itemId"] as? String ?? "reasoning"
            appendActivity(
                id: "\(itemID)-live",
                kind: .reasoning,
                title: "实时推理",
                delta: delta
            )
        case "item/plan/delta":
            guard let delta = params["delta"] as? String else { return }
            appendActivity(
                id: params["itemId"] as? String ?? "plan",
                kind: .plan,
                title: "制定计划",
                delta: delta
            )
        case "turn/plan/updated":
            let steps = params["plan"] as? [[String: Any]] ?? []
            let planCompleted = !steps.isEmpty && steps.allSatisfy { ($0["status"] as? String) == "completed" }
            let text = steps.map { step -> String in
                let status = step["status"] as? String ?? "pending"
                let mark = status == "completed" ? "✓" : (status == "inProgress" ? "●" : "○")
                return "\(mark) \(step["step"] as? String ?? "")"
            }.joined(separator: "\n")
            upsertActivity(
                id: "plan-\(params["turnId"] as? String ?? "current")",
                kind: .plan,
                title: "执行计划",
                text: text,
                status: planCompleted ? "已完成" : "进行中",
                isStreaming: !planCompleted
            )
        case "item/commandExecution/outputDelta":
            guard let delta = params["delta"] as? String else { return }
            appendActivity(
                id: params["itemId"] as? String ?? "command",
                kind: .command,
                title: "执行命令",
                delta: delta
            )
        case "item/fileChange/outputDelta":
            guard let delta = params["delta"] as? String else { return }
            appendActivity(
                id: params["itemId"] as? String ?? "file-change",
                kind: .file,
                title: "修改文件",
                delta: delta
            )
        case "item/fileChange/patchUpdated":
            let changes = params["changes"] as? [[String: Any]] ?? []
            let paths = changes.compactMap { $0["path"] as? String }
            upsertActivity(
                id: params["itemId"] as? String ?? "file-change",
                kind: .file,
                title: "修改文件",
                text: paths.isEmpty ? "正在生成并应用文件补丁…" : paths.joined(separator: "\n"),
                status: "进行中",
                isStreaming: true
            )
        case "item/mcpToolCall/progress":
            guard let message = params["message"] as? String else { return }
            appendActivity(
                id: params["itemId"] as? String ?? "tool",
                kind: .tool,
                title: "工具调用",
                delta: message + "\n"
            )
        case "item/agentMessage/delta":
            guard let delta = params["delta"] as? String else { return }
            let itemID = params["itemId"] as? String ?? "streaming-agent"
            if let index = messages.firstIndex(where: { $0.id == itemID }) {
                messages[index].text += delta
            } else {
                messages.append(.init(id: itemID, role: .assistant, text: delta, isStreaming: true))
            }
        case "item/completed":
            guard let item = params["item"] as? [String: Any] else { return }
            if item["type"] as? String == "agentMessage",
               let id = item["id"] as? String,
               let text = item["text"] as? String {
                if let index = messages.firstIndex(where: { $0.id == id }) {
                    messages[index].text = text
                    messages[index].isStreaming = false
                } else {
                    messages.append(.init(id: id, role: .assistant, text: text))
                }
            } else {
                updateActivityItem(item, completed: true)
            }
        case "turn/completed":
            isSending = false
            activeTurnID = nil
            completeStreamingActivities()
            let turn = params["turn"] as? [String: Any]
            let status = turn?["status"] as? String ?? "completed"
            finishTurnProgress(status: localizedTurnStatus(status))
            Task {
                await refreshThreads()
            }
        case "error":
            isSending = false
            activeTurnID = nil
            setThreadRunning(eventThreadID, running: false)
            finishTurnProgress(status: "失败")
            if let error = params["error"] as? [String: Any] {
                errorMessage = error["message"] as? String ?? "Codex 发生错误"
            }
        default:
            break
        }
    }

    private func updateActivityItem(_ item: [String: Any], completed: Bool) {
        guard let type = item["type"] as? String else { return }
        let id = item["id"] as? String ?? "activity-\(UUID().uuidString)"
        let runningStatus = completed ? "已完成" : "进行中"

        switch type {
        case "reasoning":
            let summary = item["summary"] as? [String] ?? []
            upsertActivity(id: id, kind: .reasoning, title: "思考摘要",
                           text: summary.joined(separator: "\n"), status: runningStatus,
                           isStreaming: !completed)
        case "plan":
            upsertActivity(id: id, kind: .plan, title: "制定计划",
                           text: item["text"] as? String ?? "", status: runningStatus,
                           isStreaming: !completed)
        case "commandExecution":
            let command = item["command"] as? String ?? ""
            let cwd = item["cwd"] as? String
            let output = item["aggregatedOutput"] as? String ?? ""
            let exitCode = (item["exitCode"] as? NSNumber)?.intValue
            var pieces = [command.isEmpty ? "" : "$ \(command)"]
            if let cwd, !cwd.isEmpty { pieces.append("目录：\(cwd)") }
            if !output.isEmpty { pieces.append(output) }
            let status = completed
                ? (exitCode.map { $0 == 0 ? "已完成" : "失败（退出码 \($0)）" } ?? "已完成")
                : "运行中"
            upsertActivity(id: id, kind: .command, title: "执行命令",
                           text: pieces.filter { !$0.isEmpty }.joined(separator: "\n"),
                           status: status, isStreaming: !completed)
        case "fileChange":
            let changes = item["changes"] as? [[String: Any]] ?? []
            let paths = changes.compactMap { change -> String? in
                guard let path = change["path"] as? String else { return nil }
                let kindObject = change["kind"] as? [String: Any]
                let kind = kindObject?["type"] as? String ?? "update"
                let verb = kind == "add" ? "新增" : (kind == "delete" ? "删除" : "修改")
                return "\(verb)  \(path)"
            }
            upsertActivity(id: id, kind: .file, title: "文件变更",
                           text: paths.isEmpty ? "正在处理工作区文件…" : paths.joined(separator: "\n"),
                           status: runningStatus, isStreaming: !completed)
        case "mcpToolCall":
            let server = item["server"] as? String ?? "MCP"
            let tool = item["tool"] as? String ?? "工具"
            let status = item["status"] as? String ?? (completed ? "completed" : "inProgress")
            upsertActivity(id: id, kind: .tool, title: "调用 \(server) · \(tool)",
                           text: jsonPreview(item["arguments"]), status: localizedStatus(status),
                           isStreaming: !completed)
        case "dynamicToolCall":
            let tool = item["tool"] as? String ?? "工具"
            let namespace = item["namespace"] as? String
            let title = [namespace, tool].compactMap { $0 }.joined(separator: " · ")
            let status = item["status"] as? String ?? (completed ? "completed" : "inProgress")
            upsertActivity(id: id, kind: .tool, title: "调用 \(title)",
                           text: jsonPreview(item["arguments"]), status: localizedStatus(status),
                           isStreaming: !completed)
        case "webSearch":
            upsertActivity(id: id, kind: .web, title: "搜索网页",
                           text: item["query"] as? String ?? "", status: runningStatus,
                           isStreaming: !completed)
        case "imageView":
            upsertActivity(id: id, kind: .tool, title: "查看图片",
                           text: item["path"] as? String ?? "", status: runningStatus,
                           isStreaming: !completed)
        case "imageGeneration":
            upsertActivity(id: id, kind: .tool, title: "生成图片",
                           text: "正在生成图像资源…", status: runningStatus,
                           isStreaming: !completed)
        case "collabAgentToolCall":
            let tool = item["tool"] as? String ?? "协作任务"
            let prompt = item["prompt"] as? String ?? ""
            let status = item["status"] as? String ?? (completed ? "completed" : "inProgress")
            upsertActivity(id: id, kind: .collaboration, title: "协作 · \(tool)",
                           text: prompt, status: localizedStatus(status), isStreaming: !completed)
        case "subAgentActivity":
            let path = item["agentPath"] as? String ?? "子任务"
            let kind = item["kind"] as? String ?? "活动"
            upsertActivity(id: id, kind: .collaboration, title: path,
                           text: kind, status: runningStatus, isStreaming: !completed)
        case "contextCompaction":
            upsertActivity(id: id, kind: .status, title: "整理会话上下文",
                           text: "Codex 正在压缩较早的上下文以继续工作。", status: "已完成",
                           isStreaming: false)
        default:
            break
        }
    }

    private func upsertActivity(
        id: String,
        kind: ChatMessage.ActivityKind,
        title: String,
        text: String,
        status: String,
        isStreaming: Bool
    ) {
        let clipped = clippedActivityText(text)
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].activityKind = kind
            messages[index].activityTitle = title
            if !clipped.isEmpty { messages[index].text = clipped }
            messages[index].activityStatus = status
            messages[index].isStreaming = isStreaming
        } else {
            messages.append(.init(id: id, role: .activity, text: clipped, isStreaming: isStreaming,
                                  activityKind: kind, activityTitle: title, activityStatus: status))
        }
    }

    private func appendActivity(id: String, kind: ChatMessage.ActivityKind, title: String, delta: String) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].text = clippedActivityText(messages[index].text + delta)
            messages[index].activityStatus = "进行中"
            messages[index].isStreaming = true
        } else {
            messages.append(.init(id: id, role: .activity, text: clippedActivityText(delta),
                                  isStreaming: true, activityKind: kind,
                                  activityTitle: title, activityStatus: "进行中"))
        }
    }

    private func completeStreamingActivities() {
        for index in messages.indices
        where messages[index].role == .activity
            && messages[index].id != "turn-progress"
            && messages[index].isStreaming {
            messages[index].isStreaming = false
            messages[index].activityStatus = "已完成"
        }
    }

    private func beginTurnProgress() {
        turnProgressHintTask?.cancel()
        messages.removeAll { $0.id == "turn-progress" }
        messages.append(.init(
            id: "turn-progress",
            role: .activity,
            text: "请求已发送，正在等待 Codex 返回第一条实时进度…",
            isStreaming: true,
            activityKind: .status,
            activityTitle: "Codex 正在处理",
            activityStatus: "进行中",
            startedAt: Date()
        ))
        turnProgressHintTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.updateQuietTurnHint("Codex 正在推理，第一条可展示内容生成后会立即显示…")

            try? await Task.sleep(nanoseconds: 24_000_000_000)
            guard !Task.isCancelled else { return }
            self?.updateQuietTurnHint("任务仍在运行，Codex 正在继续深入分析，可随时点击停止按钮。")
        }
    }

    private func finishTurnProgress(status: String) {
        turnProgressHintTask?.cancel()
        turnProgressHintTask = nil
        guard let index = messages.firstIndex(where: { $0.id == "turn-progress" }) else { return }
        messages[index].isStreaming = false
        messages[index].activityStatus = status
        messages[index].completedAt = Date()
    }

    private func updateQuietTurnHint(_ text: String) {
        guard isSending,
              !messages.contains(where: { $0.id != "turn-progress" && $0.isStreaming }),
              let index = messages.firstIndex(where: { $0.id == "turn-progress" }) else { return }
        messages[index].text = text
    }

    private func localizedTurnStatus(_ status: String) -> String {
        switch status {
        case "completed": return "已完成"
        case "interrupted": return "已停止"
        case "failed": return "失败"
        default: return localizedStatus(status)
        }
    }

    private func clippedActivityText(_ text: String) -> String {
        let limit = 12_000
        guard text.count > limit else { return text }
        return "…已省略较早输出…\n" + String(text.suffix(limit))
    }

    private func jsonPreview(_ value: Any?) -> String {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return clippedActivityText(text)
    }

    private func localizedStatus(_ status: String) -> String {
        switch status {
        case "inProgress": return "进行中"
        case "completed": return "已完成"
        case "failed": return "失败"
        case "declined": return "已拒绝"
        case "interrupted": return "已停止"
        default: return status
        }
    }
}
