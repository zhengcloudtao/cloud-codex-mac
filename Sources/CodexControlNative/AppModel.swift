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
    @Published var newThreadAttachments: [ComposerAttachment] = []
    @Published var isCreatingThread = false
    @Published var modelOptions: [CodexModelOption] = []
    @Published var permissionProfiles: [PermissionProfileOption] = []
    @Published var selectedModelID: String?
    @Published var selectedEffort: String?
    @Published private(set) var isFastModeEnabled: Bool
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
    @Published var showingRemoteControl = false
    @Published private(set) var remoteControlEnabled: Bool
    @Published private(set) var remoteControlStatus = "远程控制已关闭"
    @Published private(set) var remotePairingCode = ""
    @Published private(set) var remoteControlPaired = false
    @Published private(set) var remoteLastSyncAt: Date?

    private let client = AppServerClient()
    private let remoteControlAPI: RemoteControlAPI?
    private let speech = SpeechInputController()
    private var hasStarted = false
    private var threadRequestGeneration = 0
    private var selectedThreadMonitorTask: Task<Void, Never>?
    private var selectedThreadMetadataTask: Task<Void, Never>?
    private var threadStatusMonitorTask: Task<Void, Never>?
    private var turnProgressHintTask: Task<Void, Never>?
    private var pendingDeltaFlushTask: Task<Void, Never>?
    private var pendingActivityDeltas: [String: PendingActivityDelta] = [:]
    private var pendingAssistantDeltas: [String: [String]] = [:]
    private var pendingDeltaOrder: [PendingDeltaTarget] = []
    /// Local app-server turns must be tracked by thread. A single global
    /// `isSending` flag leaks into whichever conversation the user selects
    /// next and makes an idle task look as if it were still thinking.
    private var locallyRunningThreadIDs: Set<String> = []
    private var activeTurnIDsByThread: [String: String] = [:]
    private var liveTurnMetadataByThread: [String: TurnModelMetadata] = [:]
    private var remoteControlLoopTask: Task<Void, Never>?
    private var remoteExecution: RemoteExecution?
    private var speechTargetsNewThread = false
    private let workspaceOrganizationKey = "CloudCodex.workspaceOrganization.v1"
    private let fastModeKey = "CloudCodex.fastModeEnabled.v1"
    private let remoteControlEnabledKey = "CloudCodex.remoteControl.enabled.v1"
    private let remotePairingCodeKey = "CloudCodex.remoteControl.pairingCode.v1"

    private struct RemoteExecution {
        let taskID: String
        let threadID: String
        var turnID: String?
        var responseText: String
        var fileDiff: String = ""
    }

    private struct PendingActivityDelta {
        var kind: ChatMessage.ActivityKind
        var title: String
        var chunks: [String]
    }

    private enum PendingDeltaTarget: Hashable {
        case activity(String)
        case assistant(String)
    }

    init() {
        isFastModeEnabled = UserDefaults.standard.bool(forKey: fastModeKey)
        remoteControlEnabled = UserDefaults.standard.bool(forKey: remoteControlEnabledKey)
        remotePairingCode = UserDefaults.standard.string(forKey: remotePairingCodeKey) ?? ""
        remoteControlAPI = try? RemoteControlAPI()
        if let data = UserDefaults.standard.data(forKey: workspaceOrganizationKey),
           let saved = try? JSONDecoder().decode(WorkspaceOrganization.self, from: data) {
            workspaceOrganization = saved
        }
        speech.onTranscript = { [weak self] transcript in
            guard let self else { return }
            if self.speechTargetsNewThread {
                self.newThreadPrompt = transcript
            } else {
                self.composerText = transcript
            }
        }
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

    var supportsFastMode: Bool {
        selectedModel?.fastServiceTierID != nil
    }

    var selectedSpeedLabel: String {
        isFastModeEnabled && supportsFastMode ? "加速" : "标准"
    }

    var serviceTierForTurn: String {
        if isFastModeEnabled, let tier = selectedModel?.fastServiceTierID {
            return tier
        }
        return "default"
    }

    /// A selected task may be running because it was sent from CloudCodex or
    /// because Codex started it elsewhere. Keep the conversation UI driven by
    /// both live paths, with the thread status covering the short interval
    /// before the external activity snapshot arrives.
    var isSelectedThreadProcessing: Bool {
        guard let selectedThreadID else { return false }
        return locallyRunningThreadIDs.contains(selectedThreadID)
            || isExternalThreadProcessing
            || selectedThread?.status == "active"
    }

    var canSend: Bool {
        (!composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
            && !isSelectedThreadProcessing
    }

    var canCreateThread: Bool {
        !newThreadFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!newThreadPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !newThreadAttachments.isEmpty)
            && !isCreatingThread
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
            startRemoteControlIfNeeded()
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
            applyVisibleThreadStatuses(statuses)
        } catch {
            // Status lights are best-effort and must never interrupt the task.
        }
    }

    /// Apply a polling snapshot only when a light actually changed. Mutating an
    /// element of an `@Published` array emits a full model update even when the
    /// new value equals the old one; doing that for every visible row used to
    /// rebuild the entire three-column interface every four seconds.
    func applyVisibleThreadStatuses(_ statuses: [String: String]) {
        var updatedThreads = threads
        var didChange = false
        for index in updatedThreads.indices {
            let threadID = updatedThreads[index].id
            guard let status = statuses[threadID],
                  status != updatedThreads[index].status else { continue }
            // Keep the optimistic light on while this app is submitting or
            // streaming a turn; app-server's list snapshot can lag briefly.
            if locallyRunningThreadIDs.contains(threadID) { continue }
            updatedThreads[index].status = status
            didChange = true
        }
        if didChange {
            threads = updatedThreads
        }
    }

    private func setThreadRunning(_ threadID: String, running: Bool) {
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        threads[index].status = running ? "active" : "idle"
    }

    private func setLocalTurnRunning(_ threadID: String, turnID: String? = nil) {
        locallyRunningThreadIDs.insert(threadID)
        if let turnID { activeTurnIDsByThread[threadID] = turnID }
        syncSelectedLocalTurnState()
    }

    private func clearLocalTurn(_ threadID: String) {
        locallyRunningThreadIDs.remove(threadID)
        activeTurnIDsByThread.removeValue(forKey: threadID)
        syncSelectedLocalTurnState()
    }

    private func syncSelectedLocalTurnState() {
        guard let selectedThreadID else {
            isSending = false
            activeTurnID = nil
            return
        }
        isSending = locallyRunningThreadIDs.contains(selectedThreadID)
        activeTurnID = activeTurnIDsByThread[selectedThreadID]
    }

    func selectFolder(_ path: String?) {
        if showingNewThread { cancelNewThread() }
        selectedThreadMonitorTask?.cancel()
        selectedThreadMonitorTask = nil
        selectedThreadMetadataTask?.cancel()
        selectedThreadMetadataTask = nil
        discardPendingDeltas()
        isExternalThreadProcessing = false
        threadOwnershipNotice = nil
        selectedFolder = path
        selectedThreadID = nil
        syncSelectedLocalTurnState()
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
        if showingNewThread { cancelNewThread() }
        selectedThreadMonitorTask?.cancel()
        selectedThreadMonitorTask = nil
        discardPendingDeltas()
        isExternalThreadProcessing = false
        threadOwnershipNotice = nil
        selectedThreadID = id
        syncSelectedLocalTurnState()
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
            if let index = threads.firstIndex(where: { $0.id == id }), threads[index] != updated {
                threads[index] = updated
            }
            if selectedThreadID == id {
                messages = loadedMessages
                scheduleTurnModelMetadataLoad(
                    for: updated,
                    messages: loadedMessages,
                    threadID: id
                )
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
        liveTurnMetadataByThread[id] = TurnModelMetadata(
            model: selectedModel?.model,
            reasoningEffort: selectedEffort
        )
        setLocalTurnRunning(id)
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
            attachments: localAttachments,
            timestamp: Date()
        ))
        beginTurnProgress()
        do {
            try await client.resumeThread(id)
            let turnID = try await client.startTurn(
                threadID: id,
                text: text,
                attachments: outgoingAttachments,
                model: selectedModel?.model,
                effort: selectedEffort,
                permissions: selectedPermissionID,
                serviceTierForTurn: serviceTierForTurn
            )
            setLocalTurnRunning(id, turnID: turnID)
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
        clearLocalTurn(threadID)
        setThreadRunning(threadID, running: false)
        turnProgressHintTask?.cancel()
        turnProgressHintTask = nil
        messages.removeAll { $0.id == localMessageID || $0.id == "turn-progress" }
        liveTurnMetadataByThread.removeValue(forKey: threadID)
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
            if thread.status == "active" {
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
        let isActive = snapshot.turn?.isActive == true || snapshot.thread.status == "active"
        if let index = threads.firstIndex(where: { $0.id == threadID }) {
            if isActive {
                // `updatedAt` and preview can change on every active snapshot.
                // Replacing the whole row would invalidate the entire root view
                // every two seconds even when its visible running state is the
                // same. The final idle snapshot refreshes all summary fields.
                if threads[index].status != "active" {
                    threads[index].status = "active"
                }
            } else if threads[index] != snapshot.thread {
                threads[index] = snapshot.thread
            }
        }

        let wasStartedAt = messages.first(where: { $0.id == "turn-progress" })?.startedAt
        let latestIDs = Set(snapshot.messages.map(\.id))
        var merged = messages.filter { $0.id != "turn-progress" && !latestIDs.contains($0.id) }

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

        if messages != merged {
            messages = merged
        }
        if isExternalThreadProcessing != isActive {
            isExternalThreadProcessing = isActive
        }
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
            Task { await loadPermissionProfiles(cwd: url.path) }
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

    func chooseNewThreadAttachments() {
        let panel = NSOpenPanel()
        panel.title = "添加到新会话"
        panel.prompt = "添加"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            let newItems = panel.urls
                .filter { url in !newThreadAttachments.contains(where: { $0.url == url }) }
                .map { ComposerAttachment(url: $0) }
            newThreadAttachments.append(contentsOf: newItems)
        }
    }

    /// Imports image files or bitmap data from a pasteboard into the existing
    /// attachment flow. Bitmap-only clipboard content (for example a macOS
    /// screenshot) is converted to PNG so the app-server receives a stable
    /// localImage path rather than transient pasteboard data.
    @discardableResult
    func pasteImages(from pasteboard: NSPasteboard = .general) -> Bool {
        let result = pastedImageAttachments(
            from: pasteboard,
            excluding: Set(attachments.map(\.url))
        )
        attachments.append(contentsOf: result.items)
        return result.handled
    }

    @discardableResult
    func pasteNewThreadImages(from pasteboard: NSPasteboard = .general) -> Bool {
        let result = pastedImageAttachments(
            from: pasteboard,
            excluding: Set(newThreadAttachments.map(\.url))
        )
        newThreadAttachments.append(contentsOf: result.items)
        return result.handled
    }

    private func pastedImageAttachments(
        from pasteboard: NSPasteboard,
        excluding existingURLs: Set<URL>
    ) -> (handled: Bool, items: [ComposerAttachment]) {
        let pastedFileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []).filter { ComposerAttachment(url: $0).isImage }

        if !pastedFileURLs.isEmpty {
            let newItems = pastedFileURLs
                .filter { !existingURLs.contains($0) }
                .map { ComposerAttachment(url: $0) }
            return (true, newItems)
        }

        // Some apps expose copied images only as raw PNG/TIFF pasteboard data.
        // Read those concrete formats before asking AppKit to synthesize an
        // NSImage, because lazy pasteboard providers are not always available
        // by the time NSTextView dispatches its standard paste action.
        if let pngData = pasteboard.data(forType: .png), NSImage(data: pngData) != nil {
            let item = persistPastedImageData(pngData, fileExtension: "png")
            return (true, item.map { [$0] } ?? [])
        }
        if let tiffData = pasteboard.data(forType: .tiff), let image = NSImage(data: tiffData) {
            guard let pngData = Self.pngData(for: image) else {
                errorMessage = "无法读取剪贴板中的图片。"
                return (true, [])
            }
            let item = persistPastedImageData(pngData, fileExtension: "png")
            return (true, item.map { [$0] } ?? [])
        }

        let pastedImages = pasteboard.readObjects(
            forClasses: [NSImage.self],
            options: nil
        ) as? [NSImage] ?? []
        guard !pastedImages.isEmpty else { return (false, []) }

        do {
            let directory = try pastedImageDirectory()
            var newItems: [ComposerAttachment] = []
            for image in pastedImages {
                guard let data = Self.pngData(for: image) else { continue }
                let url = directory
                    .appendingPathComponent("cloudcodex-paste-\(UUID().uuidString)")
                    .appendingPathExtension("png")
                try data.write(to: url, options: .atomic)
                newItems.append(ComposerAttachment(url: url))
            }
            if newItems.isEmpty {
                errorMessage = "无法读取剪贴板中的图片。"
            }
            return (true, newItems)
        } catch {
            errorMessage = "无法粘贴图片：\(error.localizedDescription)"
            return (true, [])
        }
    }

    private func persistPastedImageData(_ data: Data, fileExtension: String) -> ComposerAttachment? {
        do {
            let url = try pastedImageDirectory()
                .appendingPathComponent("cloudcodex-paste-\(UUID().uuidString)")
                .appendingPathExtension(fileExtension)
            try data.write(to: url, options: .atomic)
            return ComposerAttachment(url: url)
        } catch {
            errorMessage = "无法粘贴图片：\(error.localizedDescription)"
            return nil
        }
    }

    private func pastedImageDirectory() throws -> URL {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = base
            .appendingPathComponent("CloudCodex", isDirectory: true)
            .appendingPathComponent("PastedImages", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func pngData(for image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    func removeAttachment(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    func removeNewThreadAttachment(_ id: UUID) {
        newThreadAttachments.removeAll { $0.id == id }
    }

    func toggleDictation() {
        speechTargetsNewThread = false
        speech.toggle(currentText: composerText)
    }

    func toggleNewThreadDictation() {
        speechTargetsNewThread = true
        speech.toggle(currentText: newThreadPrompt)
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

    func setFastModeEnabled(_ enabled: Bool) {
        guard !enabled || supportsFastMode else { return }
        isFastModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: fastModeKey)
    }

    func prepareNewThread() {
        if showingNewThread { return }
        newThreadFolder = selectedFolder
            ?? selectedThread?.cwd
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        newThreadPrompt = ""
        newThreadAttachments = []
        threadOwnershipNotice = nil
        selectedThreadMonitorTask?.cancel()
        selectedThreadMonitorTask = nil
        discardPendingDeltas()
        isExternalThreadProcessing = false
        selectedThreadID = nil
        syncSelectedLocalTurnState()
        messages = []
        showingNewThread = true
        Task { await loadPermissionProfiles(cwd: newThreadFolder) }
    }

    func cancelNewThread() {
        if speechTargetsNewThread { speech.stop() }
        speechTargetsNewThread = false
        showingNewThread = false
        newThreadPrompt = ""
        newThreadAttachments = []
    }

    func createThread() async {
        let folder = newThreadFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = newThreadPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoingAttachments = newThreadAttachments
        guard !folder.isEmpty,
              (!prompt.isEmpty || !outgoingAttachments.isEmpty),
              !isCreatingThread else { return }
        if speechTargetsNewThread { speech.stop() }
        speechTargetsNewThread = false
        isCreatingThread = true
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
            newThreadPrompt = ""
            newThreadAttachments = []
            composerText = prompt
            attachments = outgoingAttachments
            isCreatingThread = false
            await sendMessage()
            await refreshThreads()
        } catch {
            isCreatingThread = false
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

    var remotePermissionLabel: String {
        selectedPermission?.displayName ?? selectedPermissionID ?? "当前权限"
    }

    func setRemoteControlEnabled(_ enabled: Bool) {
        remoteControlEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: remoteControlEnabledKey)
        if enabled {
            startRemoteControlIfNeeded()
        } else {
            remoteControlLoopTask?.cancel()
            remoteControlLoopTask = nil
            remoteControlStatus = remoteExecution == nil ? "远程控制已关闭" : "当前远程任务完成后停止"
            guard let api = remoteControlAPI else { return }
            Task { [weak self] in
                guard let self else { return }
                let body = self.makeRemoteHeartbeat(ready: false)
                _ = try? await api.heartbeat(body)
            }
        }
    }

    func resetRemotePairingCode() {
        guard remoteControlEnabled, !remoteControlPaired, let api = remoteControlAPI else { return }
        remoteControlStatus = "正在生成新配对码…"
        Task { [weak self] in
            do {
                let registration = try await api.register(resetPairing: true)
                self?.applyRemoteRegistration(registration)
            } catch {
                self?.remoteControlStatus = "生成配对码失败：\(error.localizedDescription)"
            }
        }
    }

    private func startRemoteControlIfNeeded() {
        guard remoteControlEnabled, remoteControlLoopTask == nil else { return }
        guard remoteControlAPI != nil else {
            remoteControlStatus = "无法读取 Mac 钥匙串，远程控制不可用"
            return
        }
        guard connectionText.hasPrefix("已连接") else {
            remoteControlStatus = "等待连接本机 Codex…"
            return
        }
        remoteControlStatus = "正在连接远程服务…"
        remoteControlLoopTask = Task { [weak self] in
            await self?.runRemoteControlLoop()
        }
    }

    private func runRemoteControlLoop() async {
        guard let api = remoteControlAPI else { return }
        do {
            let registration = try await api.register()
            guard !Task.isCancelled, remoteControlEnabled else { return }
            applyRemoteRegistration(registration)
        } catch {
            if !Task.isCancelled { remoteControlStatus = "远程服务连接失败：\(error.localizedDescription)" }
        }

        var heartbeatCountdown = 0
        while !Task.isCancelled, remoteControlEnabled {
            if heartbeatCountdown <= 0 {
                do {
                    let response = try await api.heartbeat(makeRemoteHeartbeat(ready: true))
                    remoteControlPaired = response.paired
                    remoteLastSyncAt = Date()
                    if response.paired {
                        remotePairingCode = ""
                        UserDefaults.standard.removeObject(forKey: remotePairingCodeKey)
                        if remoteExecution == nil { remoteControlStatus = "已配对，正在等待远程任务" }
                    } else {
                        remoteControlStatus = remotePairingCode.isEmpty
                            ? "等待生成配对码…"
                            : "等待小程序输入配对码"
                    }
                } catch {
                    if !Task.isCancelled { remoteControlStatus = "状态同步失败：\(error.localizedDescription)" }
                }
                heartbeatCountdown = 3
            }

            if remoteControlPaired, remoteExecution == nil {
                do {
                    if let task = try await api.nextTask() {
                        await executeRemoteTask(task)
                    }
                } catch {
                    if !Task.isCancelled { remoteControlStatus = "任务领取失败：\(error.localizedDescription)" }
                }
            }

            heartbeatCountdown -= 1
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func applyRemoteRegistration(_ registration: RemoteRegistration) {
        remoteControlPaired = registration.paired
        if !registration.pairingCode.isEmpty {
            remotePairingCode = registration.pairingCode
            UserDefaults.standard.set(registration.pairingCode, forKey: remotePairingCodeKey)
        }
        if registration.paired {
            remotePairingCode = ""
            UserDefaults.standard.removeObject(forKey: remotePairingCodeKey)
            remoteControlStatus = "已配对，正在等待远程任务"
        } else {
            remoteControlStatus = remotePairingCode.isEmpty ? "等待生成配对码…" : "等待小程序输入配对码"
        }
    }

    private func makeRemoteHeartbeat(ready: Bool) -> RemoteHeartbeatBody {
        let allowedPaths = Set(folderCatalog.map(\.path))
        let workspaces = folderCatalog.prefix(200).map {
            RemoteWorkspaceSnapshot(path: $0.path, name: $0.name)
        }
        let snapshots = threads.prefix(300).compactMap { thread -> RemoteThreadSnapshot? in
            guard allowedPaths.contains(thread.cwd) else { return nil }
            return RemoteThreadSnapshot(
                id: thread.id,
                title: thread.displayName,
                workspace: thread.cwd,
                model: thread.model ?? "",
                status: thread.status
            )
        }
        return RemoteHeartbeatBody(
            name: remoteControlAPI?.deviceName ?? "CloudCodex Mac",
            permissionLabel: remotePermissionLabel,
            remoteControlReady: ready,
            workspaces: Array(workspaces),
            threads: Array(snapshots)
        )
    }

    private func executeRemoteTask(_ task: RemoteTask) async {
        guard let api = remoteControlAPI else { return }
        guard folderCatalog.contains(where: { $0.path == task.workspace }) else {
            await failRemoteTask(task, message: "工作区不在 CloudCodex 的授权列表中。")
            return
        }

        let requestedModel = task.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if task.action == "readFile" {
            do {
                let content = try await Task.detached(priority: .utility) {
                    try RemoteFilePreview.read(workspace: task.workspace, path: task.filePath ?? "")
                }.value
                await reportRemoteTaskStatus(task.taskId, body: RemoteTaskStatusBody(status: "completed", threadId: "", turnId: "", result: content, error: ""))
            } catch {
                await failRemoteTask(task, message: error.localizedDescription)
            }
            return
        }
        guard task.action == nil || task.action == "" else {
            await failRemoteTask(task, message: "不支持的远程任务类型。")
            return
        }
        let modelOption: CodexModelOption?
        if requestedModel.isEmpty {
            modelOption = selectedModel
        } else {
            guard let available = modelOptions.first(where: { $0.id == requestedModel || $0.model == requestedModel }) else {
                await failRemoteTask(task, message: "这台 Mac 当前不支持模型 \(requestedModel)。")
                return
            }
            modelOption = available
        }

        let requestedEffort = task.effort.trimmingCharacters(in: .whitespacesAndNewlines)
        let effort: String?
        if requestedEffort.isEmpty {
            effort = selectedEffort
        } else if let modelOption, modelOption.supportedEfforts.contains(requestedEffort) {
            effort = requestedEffort
        } else {
            await failRemoteTask(task, message: "所选模型不支持推理强度 \(requestedEffort)。")
            return
        }

        var threadID = task.threadId.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let permission: String?
            let approval: String?
            let reviewer: String?
            switch task.permissionMode ?? "" {
            case "": permission = selectedPermissionID; approval = nil; reviewer = nil
            case "ask": permission = ":workspace"; approval = "untrusted"; reviewer = "user"
            case "auto": permission = ":workspace"; approval = "on-request"; reviewer = "auto_review"
            case "full": permission = ":danger-full-access"; approval = "never"; reviewer = "user"
            default: throw RemoteControlError.server("不支持的远程权限模式。")
            }
            if let permission {
                let profiles = try await client.listPermissionProfiles(cwd: task.workspace)
                guard profiles.contains(where: { $0.id == permission }) else {
                    throw RemoteControlError.server("这台 Mac 不允许所选权限模式。")
                }
            }
            let tier: String
            switch task.speed ?? "" {
            case "": tier = isFastModeEnabled ? (modelOption?.fastServiceTierID ?? "default") : "default"
            case "standard": tier = "default"
            case "fast":
                guard let fast = modelOption?.fastServiceTierID else {
                    throw RemoteControlError.server("所选模型当前不支持加速，请选择标准速度。")
                }
                tier = fast
            default: throw RemoteControlError.server("不支持的远程速度选项。")
            }
            guard (task.imageUrls ?? []).count <= 4 else {
                throw RemoteControlError.server("远程任务最多支持 4 张图片。")
            }
            let attachments = try (task.imageUrls ?? []).map { value -> ComposerAttachment in
                guard let url = URL(string: value), url.scheme == "https", url.host != nil else {
                    throw RemoteControlError.server("图片地址无效，请重新上传。")
                }
                return ComposerAttachment(url: url)
            }
            if threadID.isEmpty {
                let thread = try await client.createThread(
                    cwd: task.workspace,
                    model: modelOption?.model,
                    permissions: permission
                )
                threadID = thread.id
                if !threads.contains(where: { $0.id == thread.id }) { threads.insert(thread, at: 0) }
            } else {
                if locallyRunningThreadIDs.contains(threadID) {
                    throw RemoteControlError.server("这个会话正在执行其他任务，请稍后重试。")
                }
                let state = try await client.readThreadState(threadID)
                guard state.cwd == task.workspace else {
                    throw RemoteControlError.server("会话与工作区不匹配。")
                }
                guard state.status != "active" else {
                    throw RemoteControlError.server("这个会话正在 Codex 中运行，请稍后重试。")
                }
                try await client.resumeThread(threadID)
            }

            remoteExecution = RemoteExecution(taskID: task.taskId, threadID: threadID, turnID: nil, responseText: "")
            remoteControlStatus = "正在执行远程任务"
            setLocalTurnRunning(threadID)
            setThreadRunning(threadID, running: true)
            let turnID = try await client.startTurn(
                threadID: threadID,
                text: task.prompt,
                attachments: attachments,
                model: modelOption?.model,
                effort: effort,
                permissions: permission,
                serviceTierForTurn: tier,
                approvalPolicy: approval,
                approvalsReviewer: reviewer
            )
            remoteExecution?.turnID = turnID
            do {
                try await api.updateTask(task.taskId, body: RemoteTaskStatusBody(
                    status: "running",
                    threadId: threadID,
                    turnId: turnID ?? "",
                    result: "",
                    error: ""
                ))
            } catch {
                // The server already marked the task running when it was claimed.
                // Keep tracking the real Codex turn so its completion can retry
                // the final status instead of abandoning an active task.
                remoteControlStatus = "任务正在执行，运行状态暂未同步"
            }
            await refreshThreads()
        } catch {
            clearLocalTurn(threadID)
            setThreadRunning(threadID, running: false)
            remoteExecution = nil
            await failRemoteTask(task, threadID: threadID, message: error.localizedDescription)
        }
    }

    private func failRemoteTask(_ task: RemoteTask, threadID: String = "", message: String) async {
        remoteControlStatus = "远程任务失败：\(message)"
        await reportRemoteTaskStatus(task.taskId, body: RemoteTaskStatusBody(
            status: "failed", threadId: threadID, turnId: "", result: "", error: message
        ))
    }

    private func reportRemoteTaskStatus(_ taskID: String, body: RemoteTaskStatusBody) async {
        guard let api = remoteControlAPI else { return }
        for delay: UInt64 in [0, 2, 5] {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay * 1_000_000_000) }
            do {
                try await api.updateTask(taskID, body: body)
                return
            } catch {
                if Task.isCancelled { return }
            }
        }
    }

    private func handleRemoteEvent(_ method: String, params: [String: Any], threadID: String) {
        guard var execution = remoteExecution, execution.threadID == threadID else { return }
        switch method {
        case "turn/diff/updated":
            if let turnID = params["turnId"] as? String, let expected = execution.turnID, turnID != expected { return }
            if let diff = params["diff"] as? String {
                execution.fileDiff = String(diff.prefix(200_000)) + (diff.count > 200_000 ? "\n[差异过长，已截断，请在 Mac 查看完整内容]" : "")
                remoteExecution = execution
            }
        case "turn/started":
            let turn = params["turn"] as? [String: Any]
            execution.turnID = turn?["id"] as? String ?? execution.turnID
            remoteExecution = execution
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String {
                execution.responseText = Self.clippedRemoteResult(execution.responseText + delta)
                remoteExecution = execution
            }
        case "item/completed":
            if let item = params["item"] as? [String: Any],
               item["type"] as? String == "agentMessage",
               let text = item["text"] as? String {
                execution.responseText = Self.clippedRemoteResult(text)
                remoteExecution = execution
            }
        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            let status = turn?["status"] as? String ?? "completed"
            let errorObject = turn?["error"] as? [String: Any]
            let errorText = errorObject?["message"] as? String ?? ""
            remoteExecution = nil
            remoteControlStatus = status == "completed" ? "远程任务已完成" : "远程任务执行失败"
            Task { [weak self] in
                await self?.reportRemoteTaskStatus(execution.taskID, body: RemoteTaskStatusBody(
                        status: status == "completed" ? "completed" : "failed",
                        threadId: execution.threadID,
                        turnId: execution.turnID ?? "",
                        result: execution.responseText,
                        error: errorText,
                        fileDiff: execution.fileDiff
                ))
            }
        case "error":
            let errorObject = params["error"] as? [String: Any]
            let message = errorObject?["message"] as? String ?? "Codex 执行远程任务失败。"
            remoteExecution = nil
            clearLocalTurn(execution.threadID)
            setThreadRunning(execution.threadID, running: false)
            remoteControlStatus = "远程任务失败：\(message)"
            Task { [weak self] in
                await self?.reportRemoteTaskStatus(execution.taskID, body: RemoteTaskStatusBody(
                        status: "failed", threadId: execution.threadID,
                        turnId: execution.turnID ?? "", result: execution.responseText, error: message,
                        fileDiff: execution.fileDiff
                ))
            }
        default:
            break
        }
    }

    private static func clippedRemoteResult(_ text: String) -> String {
        let limit = 60_000
        guard text.count > limit else { return text }
        return String(text.suffix(limit))
    }

    func handleEvent(_ method: String, _ params: [String: Any]) {
        guard let eventThreadID = params["threadId"] as? String else {
            if method == "error", let error = params["error"] as? [String: Any] {
                flushPendingDeltas()
                if let selectedThreadID { clearLocalTurn(selectedThreadID) }
                finishTurnProgress(status: "失败")
                errorMessage = error["message"] as? String ?? "Codex 发生错误"
            }
            return
        }
        if method == "turn/started" {
            let turn = params["turn"] as? [String: Any]
            if liveTurnMetadataByThread[eventThreadID] == nil,
               eventThreadID == selectedThreadID {
                liveTurnMetadataByThread[eventThreadID] = TurnModelMetadata(
                    model: selectedModel?.model ?? selectedThread?.model,
                    reasoningEffort: selectedEffort ?? selectedThread?.reasoningEffort
                )
            }
            setLocalTurnRunning(eventThreadID, turnID: turn?["id"] as? String)
            setThreadRunning(eventThreadID, running: true)
        } else if method == "turn/completed" {
            clearLocalTurn(eventThreadID)
            setThreadRunning(eventThreadID, running: false)
        }

        handleRemoteEvent(method, params: params, threadID: eventThreadID)

        guard eventThreadID == selectedThreadID else {
            if method == "turn/completed" { Task { await syncVisibleThreadStatuses() } }
            return
        }

        switch method {
        case "turn/started":
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
            enqueueActivityDelta(
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
            enqueueActivityDelta(
                id: "\(itemID)-live",
                kind: .reasoning,
                title: "实时推理",
                delta: delta
            )
        case "item/plan/delta":
            guard let delta = params["delta"] as? String else { return }
            enqueueActivityDelta(
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
            enqueueActivityDelta(
                id: params["itemId"] as? String ?? "command",
                kind: .command,
                title: "执行命令",
                delta: delta
            )
        case "item/fileChange/outputDelta":
            guard let delta = params["delta"] as? String else { return }
            enqueueActivityDelta(
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
            enqueueActivityDelta(
                id: params["itemId"] as? String ?? "tool",
                kind: .tool,
                title: "工具调用",
                delta: message + "\n"
            )
        case "item/agentMessage/delta":
            guard let delta = params["delta"] as? String else { return }
            let itemID = params["itemId"] as? String ?? "streaming-agent"
            enqueueAssistantDelta(id: itemID, delta: delta)
        case "item/completed":
            flushPendingDeltas()
            guard let item = params["item"] as? [String: Any] else { return }
            if item["type"] as? String == "agentMessage",
               let id = item["id"] as? String,
               let text = item["text"] as? String {
                if let index = messages.firstIndex(where: { $0.id == id }) {
                    messages[index].text = text
                    messages[index].isStreaming = false
                    messages[index].timestamp = Date()
                    applyLiveTurnMetadata(to: &messages[index], threadID: eventThreadID)
                } else {
                    let metadata = liveTurnMetadataByThread[eventThreadID]
                    messages.append(.init(
                        id: id,
                        role: .assistant,
                        text: text,
                        timestamp: Date(),
                        turnID: params["turnId"] as? String,
                        model: metadata?.model,
                        reasoningEffort: metadata?.reasoningEffort
                    ))
                }
            } else {
                updateActivityItem(item, completed: true)
            }
        case "turn/completed":
            flushPendingDeltas()
            isExternalThreadProcessing = false
            completeStreamingActivities()
            let turn = params["turn"] as? [String: Any]
            let status = turn?["status"] as? String ?? "completed"
            applyCompletedTurnTimestamp(turn)
            finishTurnProgress(status: localizedTurnStatus(status))
            Task {
                await refreshThreads()
            }
        case "error":
            flushPendingDeltas()
            clearLocalTurn(eventThreadID)
            isExternalThreadProcessing = false
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

    private func enqueueActivityDelta(
        id: String,
        kind: ChatMessage.ActivityKind,
        title: String,
        delta: String
    ) {
        if var pending = pendingActivityDeltas[id] {
            pending.chunks.append(delta)
            pending.kind = kind
            pending.title = title
            pendingActivityDeltas[id] = pending
        } else {
            pendingActivityDeltas[id] = PendingActivityDelta(
                kind: kind,
                title: title,
                chunks: [delta]
            )
            pendingDeltaOrder.append(.activity(id))
        }
        schedulePendingDeltaFlush()
    }

    private func enqueueAssistantDelta(id: String, delta: String) {
        if pendingAssistantDeltas[id] == nil {
            pendingDeltaOrder.append(.assistant(id))
        }
        pendingAssistantDeltas[id, default: []].append(delta)
        schedulePendingDeltaFlush()
    }

    /// App-server can emit hundreds of token/output events per second. Publishing
    /// every token forces SwiftUI to lay out the whole conversation repeatedly,
    /// which makes a long active task appear frozen. Keep collecting immediately,
    /// but expose a single coherent UI update at most twice per second.
    private func schedulePendingDeltaFlush() {
        guard pendingDeltaFlushTask == nil else { return }
        pendingDeltaFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.flushPendingDeltas()
        }
    }

    func flushPendingDeltas() {
        pendingDeltaFlushTask?.cancel()
        pendingDeltaFlushTask = nil
        guard !pendingDeltaOrder.isEmpty else { return }

        let order = pendingDeltaOrder
        let activityDeltas = pendingActivityDeltas
        let assistantDeltas = pendingAssistantDeltas
        pendingDeltaOrder.removeAll(keepingCapacity: true)
        pendingActivityDeltas.removeAll(keepingCapacity: true)
        pendingAssistantDeltas.removeAll(keepingCapacity: true)

        var updatedMessages = messages
        for target in order {
            switch target {
            case let .activity(id):
                guard let pending = activityDeltas[id] else { continue }
                let delta = pending.chunks.joined()
                if let index = updatedMessages.firstIndex(where: { $0.id == id }) {
                    updatedMessages[index].text = clippedActivityText(
                        updatedMessages[index].text + delta
                    )
                    updatedMessages[index].activityKind = pending.kind
                    updatedMessages[index].activityTitle = pending.title
                    updatedMessages[index].activityStatus = "进行中"
                    updatedMessages[index].isStreaming = true
                } else {
                    updatedMessages.append(.init(
                        id: id,
                        role: .activity,
                        text: clippedActivityText(delta),
                        isStreaming: true,
                        activityKind: pending.kind,
                        activityTitle: pending.title,
                        activityStatus: "进行中"
                    ))
                }
            case let .assistant(id):
                guard let chunks = assistantDeltas[id] else { continue }
                let delta = chunks.joined()
                if let index = updatedMessages.firstIndex(where: { $0.id == id }) {
                    updatedMessages[index].text += delta
                    updatedMessages[index].isStreaming = true
                    if let threadID = selectedThreadID {
                        applyLiveTurnMetadata(to: &updatedMessages[index], threadID: threadID)
                    }
                } else {
                    let metadata = selectedThreadID.flatMap { liveTurnMetadataByThread[$0] }
                    updatedMessages.append(.init(
                        id: id,
                        role: .assistant,
                        text: delta,
                        isStreaming: true,
                        turnID: activeTurnID,
                        model: metadata?.model,
                        reasoningEffort: metadata?.reasoningEffort
                    ))
                }
            }
        }
        if updatedMessages != messages {
            messages = updatedMessages
        }
    }

    private func applyTurnModelMetadata(_ metadataByTurnID: [String: TurnModelMetadata]) {
        guard !metadataByTurnID.isEmpty else { return }
        var updatedMessages = messages
        var didChange = false
        for index in updatedMessages.indices {
            guard let turnID = updatedMessages[index].turnID,
                  let metadata = metadataByTurnID[turnID] else { continue }
            if updatedMessages[index].model != metadata.model {
                updatedMessages[index].model = metadata.model
                didChange = true
            }
            if updatedMessages[index].reasoningEffort != metadata.reasoningEffort {
                updatedMessages[index].reasoningEffort = metadata.reasoningEffort
                didChange = true
            }
        }
        if didChange { messages = updatedMessages }
    }

    private func applyCompletedTurnTimestamp(_ turn: [String: Any]?) {
        guard let turn,
              let turnID = turn["id"] as? String,
              let completedAt = dateFromUnixTimestamp(turn["completedAt"]) else { return }
        var updatedMessages = messages
        var didChange = false
        for index in updatedMessages.indices where
            updatedMessages[index].role == .assistant && updatedMessages[index].turnID == turnID {
            if updatedMessages[index].timestamp != completedAt {
                updatedMessages[index].timestamp = completedAt
                didChange = true
            }
        }
        if didChange { messages = updatedMessages }
    }

    private func dateFromUnixTimestamp(_ value: Any?) -> Date? {
        guard let rawValue = (value as? NSNumber)?.doubleValue, rawValue > 0 else { return nil }
        let seconds = rawValue > 100_000_000_000 ? rawValue / 1_000 : rawValue
        return Date(timeIntervalSince1970: seconds)
    }

    private func scheduleTurnModelMetadataLoad(
        for thread: CodexThread,
        messages loadedMessages: [ChatMessage],
        threadID: String
    ) {
        let turnIDs = Set(loadedMessages.compactMap(\.turnID))
        guard !turnIDs.isEmpty else { return }
        selectedThreadMetadataTask?.cancel()
        selectedThreadMetadataTask = Task { [weak self] in
            guard let self else { return }
            let metadata = await self.client.readTurnModelMetadata(
                for: thread,
                turnIDs: turnIDs
            )
            guard !Task.isCancelled, self.selectedThreadID == threadID else { return }
            self.applyTurnModelMetadata(metadata)
        }
    }

    private func applyLiveTurnMetadata(to message: inout ChatMessage, threadID: String) {
        guard let metadata = liveTurnMetadataByThread[threadID] else { return }
        message.model = metadata.model
        message.reasoningEffort = metadata.reasoningEffort
        if message.turnID == nil { message.turnID = activeTurnIDsByThread[threadID] }
    }

    private func discardPendingDeltas() {
        pendingDeltaFlushTask?.cancel()
        pendingDeltaFlushTask = nil
        pendingDeltaOrder.removeAll(keepingCapacity: true)
        pendingActivityDeltas.removeAll(keepingCapacity: true)
        pendingAssistantDeltas.removeAll(keepingCapacity: true)
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
