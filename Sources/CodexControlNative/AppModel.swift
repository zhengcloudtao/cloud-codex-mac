import AppKit
import Foundation

enum ThreadInputAvailability: Equatable {
    case checking
    case available
    case occupied
}

@MainActor
final class AppModel: ObservableObject {
    let browser = EmbeddedBrowser()
    let connectionHealth = ConnectionHealth()
    let systemMetrics = SystemMetricsMonitor()
    @Published private(set) var accountOverview: AccountOverview?
    @Published private(set) var accountOverviewError: String?
    @Published var threads: [CodexThread] = []
    @Published var folderCatalog: [WorkspaceFolder] = []
    @Published var selectedFolder: String?
    @Published var selectedThreadID: String?
    @Published var messages: [ChatMessage] = []
    @Published var composerText = ""
    @Published private(set) var threadOutcomes: [String: ConversationOutcome] = [:]
    @Published private(set) var unreadCompletions = UnreadCompletions()
    @Published private(set) var favoriteConversations = FavoriteConversations()
    @Published private(set) var userInputRequests: [UserInputRequest] = []
    private var userInputTimeoutTasks: [String: Task<Void, Never>] = [:]
    private let userInputTimeoutSeconds: TimeInterval
    private let unreadCompletionsKey = "cloudcodex.unreadCompletions.v1"
    private let favoriteConversationsKey = "cloudcodex.favoriteConversations.v1"

    func markConversationRead(_ threadID: String) {
        guard unreadCompletions.unread.contains(threadID) else { return }
        unreadCompletions.markRead(threadID)
        saveUnreadCompletions()
    }

    func recordCompletedConversation(_ threadID: String, turnID: String, viewed: Bool) {
        unreadCompletions.complete(threadID: threadID, turnID: turnID, viewed: viewed)
        saveUnreadCompletions()
    }

    private func saveUnreadCompletions() {
        if let data = try? JSONEncoder().encode(unreadCompletions) {
            remoteDefaults.set(data, forKey: unreadCompletionsKey)
        }
    }

    func isFavoriteConversation(_ threadID: String) -> Bool {
        favoriteConversations.contains(threadID)
    }

    func toggleFavoriteConversation(_ thread: CodexThread) {
        favoriteConversations.toggle(thread)
        saveFavoriteConversations()
    }

    private func saveFavoriteConversations() {
        if let data = try? JSONEncoder().encode(favoriteConversations) {
            remoteDefaults.set(data, forKey: favoriteConversationsKey)
        }
    }

    private func updateFavoriteSnapshot(_ thread: CodexThread) {
        let previous = favoriteConversations
        favoriteConversations.updateIfFavorite(thread)
        if favoriteConversations != previous {
            saveFavoriteConversations()
        }
    }

    func conversationOutcome(for thread: CodexThread) -> ConversationOutcome? {
        if thread.status == "active" || locallyRunningThreadIDs.contains(thread.id) { return .running }
        return threadOutcomes[thread.id]
    }

    var selectedUserInputRequests: [UserInputRequest] {
        guard let selectedThreadID else { return [] }
        return userInputRequests.filter { $0.threadID == selectedThreadID }
    }

    func submitUserInput(requestID: String, answers: [String: String]) {
        guard let index = userInputRequests.firstIndex(where: { $0.id == requestID }),
              userInputRequests[index].questions.allSatisfy({ !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return }
        userInputRequests[index].isSubmitting = true
        userInputRequests[index].error = nil
        let request = userInputRequests[index]
        let payload = request.responsePayload(answers: answers)
        do {
            try client.respond(to: request.requestID, result: payload)
            userInputTimeoutTasks.removeValue(forKey: requestID)?.cancel()
            userInputRequests.removeAll { $0.id == requestID }
            upsertConversationActivity(threadID: request.threadID,
                id: "user-input-\(request.itemID)", title: "已提交所需信息", text: "Codex 已收到你的回答，正在继续执行。", status: "已回答")
        } catch {
            guard let retryIndex = userInputRequests.firstIndex(where: { $0.id == requestID }) else { return }
            userInputRequests[retryIndex].isSubmitting = false
            userInputRequests[retryIndex].error = error.localizedDescription
        }
    }

    private func upsertConversationActivity(threadID: String, id: String, title: String, text: String, status: String) {
        var rows = conversationMessages(for: threadID)
        let message = ChatMessage(id: id, role: .activity, text: text, activityKind: .status,
                                  activityTitle: title, activityStatus: status,
                                  turnID: activeTurnIDsByThread[threadID])
        if let index = rows.firstIndex(where: { $0.id == id }) { rows[index] = message } else { rows.append(message) }
        storeMessages(rows, for: threadID)
    }
    struct WaitingMessage: Identifiable {
        let id = UUID()
        let threadID: String
        var text: String
        let attachments: [ComposerAttachment]
        let model: String?
        let effort: String?
        let permissions: String?
        let serviceTier: String?
        var error: String?
    }
    @Published var waitingMessages: [WaitingMessage] = []
    @Published private(set) var deliveringWaitingMessages: Set<UUID> = []
    @Published private(set) var editingWaitingMessageID: UUID?
    @Published var waitingMessageEditText = ""

    var canSaveWaitingMessageEdit: Bool {
        guard let item = waitingMessages.first(where: { $0.id == editingWaitingMessageID }) else { return false }
        return !waitingMessageEditText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !item.attachments.isEmpty
    }

    func beginEditingWaitingMessage(_ id: UUID) {
        guard editingWaitingMessageID == nil, !deliveringWaitingMessages.contains(id),
              let item = waitingMessages.first(where: { $0.id == id }) else { return }
        speech.stop()
        waitingMessageEditText = item.text
        editingWaitingMessageID = id
    }

    func cancelWaitingMessageEdit() {
        editingWaitingMessageID = nil
        waitingMessageEditText = ""
    }

    func saveWaitingMessageEdit() {
        guard canSaveWaitingMessageEdit,
              let index = waitingMessages.firstIndex(where: { $0.id == editingWaitingMessageID }) else { return }
        waitingMessages[index].text = waitingMessageEditText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Preserve any delivery error: editing alone must not silently retry a failed request.
        cancelWaitingMessageEdit()
    }
    private var waitingMonitor: Task<Void, Never>?

    var selectedWaitingMessages: [WaitingMessage] {
        waitingMessages.filter { $0.threadID == selectedThreadID }
    }

    func removeWaitingMessage(_ id: UUID) {
        guard !deliveringWaitingMessages.contains(id) else { return }
        if editingWaitingMessageID == id { cancelWaitingMessageEdit() }
        waitingMessages.removeAll { $0.id == id }
    }

    private func enqueueComposerMessage(threadID: String) {
        waitingMessages.append(WaitingMessage(threadID: threadID,
            text: composerText.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: attachments, model: selectedModel?.model, effort: selectedEffort,
            permissions: selectedPermissionID, serviceTier: serviceTierForTurn))
        composerText = ""
        attachments = []
        speech.stop()
        guard waitingMonitor == nil else { return }
        waitingMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.waitingMessages.isEmpty else { break }
                for threadID in Set(self.waitingMessages.map(\.threadID)) {
                    guard !self.locallyRunningThreadIDs.contains(threadID),
                          let first = self.waitingMessages.first(where: { $0.threadID == threadID }),
                          first.error == nil, first.id != self.editingWaitingMessageID else { continue }
                    do {
                        let state = try await self.client.readThreadState(threadID)
                        if state.status == "idle" { await self.deliverWaitingMessage(first.id, steer: false) }
                    } catch { /* Retry read-only status checks after a temporary disconnect. */ }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            self?.waitingMonitor = nil
        }
    }

    func deliverWaitingMessage(_ messageID: UUID, steer: Bool) async {
        guard messageID != editingWaitingMessageID,
              let item = waitingMessages.first(where: { $0.id == messageID }),
              !waitingMessages.contains(where: { $0.threadID == item.threadID && deliveringWaitingMessages.contains($0.id) }) else { return }
        deliveringWaitingMessages.insert(messageID)
        defer { deliveringWaitingMessages.remove(messageID) }
        do {
            if steer {
                let runtime = try await client.readLatestThreadActivity(item.threadID)
                guard let turn = runtime.turn, turn.isActive else {
                    throw CodexClientError.server("当前任务已经结束，请点击重试作为下一条消息发送。")
                }
                try await client.steerTurn(threadID: item.threadID, turnID: turn.id,
                                           text: item.text, attachments: item.attachments)
                recordSteeredMessage(item, turnID: turn.id)
            } else {
                let state = try await client.readThreadState(item.threadID)
                guard state.status == "idle", !locallyRunningThreadIDs.contains(item.threadID) else { return }
                guard waitingMessages.first(where: { $0.threadID == item.threadID })?.id == messageID else { return }
                liveTurnMetadataByThread[item.threadID] = TurnModelMetadata(model: item.model, reasoningEffort: item.effort)
                setLocalTurnRunning(item.threadID)
                do {
                    try await client.resumeThread(item.threadID)
                    let turnID = try await client.startTurn(threadID: item.threadID,
                        text: item.text, attachments: item.attachments, model: item.model,
                        effort: item.effort, permissions: item.permissions, serviceTierForTurn: item.serviceTier)
                    setLocalTurnRunning(item.threadID, turnID: turnID)
                    setThreadRunning(item.threadID, running: true)
                } catch {
                    clearLocalTurn(item.threadID)
                    throw error
                }
            }
            waitingMessages.removeAll { $0.id == messageID }
            // Reload confirmed server messages, including attachment identities.
            if selectedThreadID == item.threadID { await loadSelectedThread() }
        } catch {
            if let index = waitingMessages.firstIndex(where: { $0.id == messageID }) {
                waitingMessages[index].error = error.localizedDescription
            }
        }
    }
    func recordSteeredMessage(_ item: WaitingMessage, turnID: String) {
        let message = ChatMessage(id: "local-steer-\(item.id)", role: .user, text: item.text,
            attachments: item.attachments.map {
                ChatMessageAttachment(path: $0.url.path, name: $0.url.lastPathComponent, kind: $0.isImage ? .image : .file)
            }, timestamp: Date(), turnID: turnID)
        var history = conversationMessages(for: item.threadID)
        guard !history.contains(where: { $0.id == message.id }) else { return }
        history.append(message)
        storeMessages(history, for: item.threadID)
    }
    @Published var searchText = ""
    @Published var connectionText = "正在连接…"
    @Published var isLoading = false
    @Published private(set) var isConversationLoading = false
    @Published var isSending = false
    @Published var isExternalThreadProcessing = false
    @Published var threadOwnershipNotice: String?
    @Published private(set) var threadInputAvailability: ThreadInputAvailability = .available
    @Published var hasMoreThreads = false
    @Published var errorMessage: String?
    @Published var showingNewThread = false
    @Published private(set) var newThreadFocusRequest = UUID()
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
    @Published var speechStatus = ""
    @Published var activeTurnID: String?
    @Published private(set) var workspaceOrganization = WorkspaceOrganization()
    @Published var showingCategoryManager = false
    @Published var showingCategoryEditor = false
    @Published var editingCategoryID: String?
    @Published var categoryNameDraft = ""
    @Published var categoryEditorError: String?
    @Published var showingAppearanceSettings = false
    @Published var showingRemoteControl = false
    @Published private(set) var remoteControlEnabled: Bool
    @Published private(set) var remoteControlStatus = "远程控制已关闭"
    @Published private(set) var remotePairingCode = ""
    @Published private(set) var remoteControlPaired = false
    @Published private(set) var remoteLastSyncAt: Date?
    @Published private(set) var remoteCredentialIssue: String?
    @Published private(set) var isLoadingRemoteCredential = false

    private let client = AppServerClient()
    private var remoteControlAPI: RemoteControlAPI?
    private let remoteAPILoader: @Sendable (Bool) async throws -> RemoteControlAPI
    private let remoteDefaults: UserDefaults
    private let speech = SpeechInputController()
    private var hasStarted = false
    private var threadRequestGeneration = 0
    private var selectedThreadMonitorTask: Task<Void, Never>?
    private var selectedThreadMetadataTask: Task<Void, Never>?
    private var threadStatusMonitorTask: Task<Void, Never>?
    private var turnProgressHintTask: Task<Void, Never>?
    private var pendingDeltaFlushTask: Task<Void, Never>?
    private var pendingActivityDeltas: [PendingItemKey: PendingActivityDelta] = [:]
    private var pendingAssistantDeltas: [PendingItemKey: [String]] = [:]
    private var pendingDeltaOrder: [PendingDeltaTarget] = []
    private var messagesByThread: [String: [ChatMessage]] = [:]
    private var threadSummaries: [String: CodexThread] = [:]
    private var selectionGeneration = 0
    private var turnEventRevision: [String: Int] = [:]
    // Reduce each event into its own conversation, publishing only once and
    // only if that conversation is visible. Background events never disappear.
    private var eventThreadID: String?
    private var eventBuffer: [ChatMessage]?

    private var eventMessages: [ChatMessage] {
        get { eventBuffer ?? messages }
        set {
            if eventBuffer != nil { eventBuffer = newValue }
            else if messages != newValue { messages = newValue }
        }
    }

    func conversationMessages(for threadID: String) -> [ChatMessage] {
        if eventThreadID == threadID, let eventBuffer { return eventBuffer }
        return selectedThreadID == threadID ? messages : messagesByThread[threadID] ?? []
    }

    private func storeMessages(_ value: [ChatMessage], for threadID: String) {
        if eventThreadID == threadID { eventBuffer = value; return }
        messagesByThread[threadID] = value
        if selectedThreadID == threadID, messages != value { messages = value }
    }

    private func preserveSelectedConversation() {
        flushPendingDeltas()
        if let id = selectedThreadID {
            messagesByThread[id] = messages
            if let thread = selectedThread { threadSummaries[id] = thread }
        }
        turnProgressHintTask?.cancel()
        selectedThreadMetadataTask?.cancel()
        selectionGeneration += 1
    }
    /// Local app-server turns must be tracked by thread. A single global
    /// `isSending` flag leaks into whichever conversation the user selects
    /// next and makes an idle task look as if it were still thinking.
    private var locallyRunningThreadIDs: Set<String> = []
    private var activeTurnIDsByThread: [String: String] = [:]
    private var liveTurnMetadataByThread: [String: TurnModelMetadata] = [:]
    private var remoteControlLoopTask: Task<Void, Never>?
    private var remoteHistoryTask: Task<Void, Never>?
    private var remoteUsageTask: Task<Void, Never>?
    private var remoteRecoveryTask: Task<Void, Never>?
    private var remoteRecoveryLastAttempt: Date?
    private var remoteStatusUploadTask: Task<Void, Never>?
    private var remoteSchedulingTask: Task<Void, Never>?
    private var remoteSchedulingLastAttempt: Date?
    private var remoteSchedulingGeneration = 0
    private var remoteSchedulingState = RemoteSchedulingState()
    private var remoteClaimTask: Task<Void, Never>?
    private var remoteProgressUploadTask: Task<Void, Never>?
    private let remoteStatusOutbox: RemoteStatusOutbox
    private var remoteUsageSnapshot: RemoteUsageSnapshot?
    private var remoteUsageLastAttempt: Date?
    private var remoteExecutions: [String: RemoteExecution] = [:]
    private let maxConcurrentRemoteExecutions = 4
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
        var responseItemID: String? = nil
        var fileDiff: String = ""
        var progress = RemoteTaskProgress()
        var uploadedRevision: Int64 = -1
    }

    private struct PendingActivityDelta {
        var kind: ChatMessage.ActivityKind
        var title: String
        var chunks: [String]
    }

    private struct PendingItemKey: Hashable {
        let threadID: String
        let itemID: String
    }

    private enum PendingDeltaTarget: Hashable {
        case activity(PendingItemKey)
        case assistant(PendingItemKey)

        var key: PendingItemKey {
            switch self {
            case .activity(let key), .assistant(let key): return key
            }
        }
    }

    init(
        remoteDefaults: UserDefaults = .standard,
        userInputTimeoutSeconds: TimeInterval = 60,
        remoteAPILoader: @escaping @Sendable (Bool) async throws -> RemoteControlAPI = {
            try await RemoteControlAPI.connect(allowInteraction: $0)
        }
    ) {
        self.remoteDefaults = remoteDefaults
        self.userInputTimeoutSeconds = userInputTimeoutSeconds
        self.remoteStatusOutbox = RemoteStatusOutbox(defaults: remoteDefaults)
        self.remoteAPILoader = remoteAPILoader
        if let data = remoteDefaults.data(forKey: unreadCompletionsKey),
           let saved = try? JSONDecoder().decode(UnreadCompletions.self, from: data) {
            unreadCompletions = saved
        }
        if let data = remoteDefaults.data(forKey: favoriteConversationsKey),
           let saved = try? JSONDecoder().decode(FavoriteConversations.self, from: data) {
            favoriteConversations = saved
        }
        isFastModeEnabled = UserDefaults.standard.bool(forKey: fastModeKey)
        remoteControlEnabled = remoteDefaults.bool(forKey: remoteControlEnabledKey)
        remotePairingCode = remoteDefaults.string(forKey: remotePairingCodeKey) ?? ""
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
        speech.onStatus = { [weak self] status in self?.speechStatus = status }
        speech.currentDraft = { [weak self] in
            guard let self else { return "" }
            return self.speechTargetsNewThread ? self.newThreadPrompt : self.composerText
        }
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

    var visibleFavoriteThreads: [CodexThread] {
        favoriteConversations.sortedThreads(matching: searchText)
    }

    var selectedThread: CodexThread? {
        threads.first { $0.id == selectedThreadID }
            ?? selectedThreadID.flatMap { threadSummaries[$0] }
            ?? selectedThreadID.flatMap { favoriteConversations.thread($0) }
    }

    var selectedModel: CodexModelOption? {
        modelOptions.first { $0.id == selectedModelID }
    }

    var selectedPermission: PermissionProfileOption? {
        permissionProfiles.first { $0.id == selectedPermissionID }
    }

    var availableEfforts: [String] {
        selectedModel?.composerEfforts ?? []
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
            && selectedThreadID != nil
            && threadInputAvailability == .available
    }

    var isSelectedThreadOwnedElsewhere: Bool {
        selectedThreadID != nil && threadInputAvailability == .occupied
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
        systemMetrics.start()
        connectionHealth.start { [weak self] in
            guard let self else { throw CodexClientError.notRunning }
            do {
                self.accountOverview = try await self.client.readAccountOverview()
                self.accountOverviewError = nil
            } catch {
                self.accountOverviewError = error.localizedDescription
                throw error
            }
        }
        client.onEvent = { [weak self] method, params in self?.handleEvent(method, params) }
        client.onServerRequest = { [weak self] requestID, method, params in
            self?.handleServerRequest(requestID, method: method, params: params)
        }
        client.onDisconnect = { [weak self] message in
            self?.connectionText = "未连接"
            self?.errorMessage = message
        }
        do {
            try await client.start()
            connectionText = "已连接本机 Codex"
            Task { await connectionHealth.check() }
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
            applyThreadListSnapshot(page.threads)
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

    func applyThreadListSnapshot(_ snapshot: [CodexThread]) {
        let incomingIDs = Set(snapshot.map(\.id))
        // A new/selected/running task may not have reached thread/list yet.
        let retained = threads.filter {
            !incomingIDs.contains($0.id)
                && ($0.id == selectedThreadID || locallyRunningThreadIDs.contains($0.id))
        }
        let merged = (retained + snapshot).map { thread -> CodexThread in
            var updated = thread
            if locallyRunningThreadIDs.contains(thread.id) { updated.status = "active" }
            if updated.status == "active", threadOutcomes[thread.id] != nil {
                threadOutcomes.removeValue(forKey: thread.id)
            }
            threadSummaries[thread.id] = updated
            return updated
        }
        let previousFavorites = favoriteConversations
        for thread in merged {
            favoriteConversations.updateIfFavorite(thread)
        }
        if favoriteConversations != previousFavorites {
            saveFavoriteConversations()
        }
        // Retained selected/running rows must follow the same recency rule;
        // retaining a row does not pin it above a newer user request.
        let ordered = merged.enumerated().sorted {
            if $0.element.updatedAt != $1.element.updatedAt {
                return $0.element.updatedAt > $1.element.updatedAt
            }
            return $0.offset < $1.offset
        }.map(\.element)
        if threads != ordered { threads = ordered }
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

    /// Discover new rows as well as status changes, without loading history.
    private func syncVisibleThreadStatuses() async {
        let requestedFolder = selectedFolder
        do {
            let page = try await client.listThreads(limit: 60, cwd: requestedFolder)
            guard requestedFolder == selectedFolder else { return }
            let ended = page.threads.filter { incoming in
                incoming.status != "active" && threads.contains { $0.id == incoming.id && $0.status == "active" }
            }
            applyThreadListSnapshot(page.threads)
            for thread in ended {
                guard let snapshot = try? await client.readLatestThreadActivity(thread.id, knownThread: thread),
                      let turn = snapshot.turn, turn.status == "completed" else { continue }
                threadOutcomes[thread.id] = .completed
                recordCompletedConversation(thread.id, turnID: turn.id,
                    viewed: selectedThreadID == thread.id)
            }
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
            if status == "active", threadOutcomes[threadID] != nil {
                threadOutcomes.removeValue(forKey: threadID)
            }
            updatedThreads[index].status = status
            didChange = true
        }
        if didChange {
            threads = updatedThreads
            for thread in updatedThreads {
                updateFavoriteSnapshot(thread)
            }
        }
    }

    private func setThreadRunning(_ threadID: String, running: Bool) {
        if var cached = threadSummaries[threadID] {
            cached.status = running ? "active" : "idle"
            threadSummaries[threadID] = cached
            updateFavoriteSnapshot(cached)
        }
        guard let index = threads.firstIndex(where: { $0.id == threadID }) else { return }
        let status = running ? "active" : "idle"
        if threads[index].status != status { threads[index].status = status }
    }

    private func setLocalTurnRunning(_ threadID: String, turnID: String? = nil) {
        threadOutcomes.removeValue(forKey: threadID)
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
        if path != selectedFolder { speech.stop() }
        if path != selectedFolder { cancelWaitingMessageEdit() }
        guard path != selectedFolder else { return }
        let previousThreadID = selectedThreadID
        let canReleasePrevious = previousThreadID.map { previousID in
            !locallyRunningThreadIDs.contains(previousID)
                && !waitingMessages.contains(where: { $0.threadID == previousID })
        } ?? false
        preserveSelectedConversation()
        if showingNewThread { cancelNewThread() }
        selectedThreadMonitorTask?.cancel()
        selectedThreadMonitorTask = nil
        selectedThreadMetadataTask?.cancel()
        selectedThreadMetadataTask = nil
        isExternalThreadProcessing = false
        threadOwnershipNotice = nil
        threadInputAvailability = .available
        selectedFolder = path
        selectedThreadID = nil
        syncSelectedLocalTurnState()
        threads = []
        messages = []
        isConversationLoading = false
        hasMoreThreads = false
        searchText = ""
        Task {
            if canReleasePrevious, let previousThreadID {
                try? await client.unsubscribeThread(previousThreadID)
            }
            await loadPermissionProfiles(cwd: path)
            await refreshThreads()
        }
    }

    func selectThread(_ id: String?) {
        if let id { markConversationRead(id) }
        if id != selectedThreadID { speech.stop() }
        if id != selectedThreadID { cancelWaitingMessageEdit() }
        guard id != selectedThreadID else { return }
        let previousThreadID = selectedThreadID
        let canReleasePrevious = previousThreadID.map { previousID in
            !locallyRunningThreadIDs.contains(previousID)
                && !waitingMessages.contains(where: { $0.threadID == previousID })
        } ?? false
        preserveSelectedConversation()
        if showingNewThread { cancelNewThread() }
        selectedThreadMonitorTask?.cancel()
        selectedThreadMonitorTask = nil
        isExternalThreadProcessing = false
        threadOwnershipNotice = nil
        threadInputAvailability = id == nil ? .available : .checking
        selectedThreadID = id
        messages = id.flatMap { messagesByThread[$0] } ?? []
        // Publish loading together with the new selection so an uncached
        // conversation never renders the empty "开始对话" state for one frame.
        isConversationLoading = id != nil && messages.isEmpty
        syncSelectedLocalTurnState()
        guard let id else {
            messages = []
            if canReleasePrevious, let previousThreadID {
                Task { [weak self] in try? await self?.client.unsubscribeThread(previousThreadID) }
            }
            return
        }
        selectedThreadMonitorTask = Task { [weak self] in
            guard !Task.isCancelled, let self, self.selectedThreadID == id else { return }
            if canReleasePrevious, let previousThreadID {
                try? await self.client.unsubscribeThread(previousThreadID)
            }
            await self.claimSelectedThreadForInput(threadID: id)
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

    func retrySelectedThreadOwnership() async {
        guard let selectedThreadID else { return }
        await claimSelectedThreadForInput(threadID: selectedThreadID)
    }

    private func claimSelectedThreadForInput(threadID: String) async {
        guard selectedThreadID == threadID else { return }
        threadInputAvailability = .checking
        threadOwnershipNotice = nil
        do {
            try await client.resumeThread(threadID)
            guard !Task.isCancelled, selectedThreadID == threadID else { return }
            threadInputAvailability = .available
        } catch {
            guard !Task.isCancelled, selectedThreadID == threadID else { return }
            if Self.isActiveWriterError(error) {
                errorMessage = nil
                threadInputAvailability = .occupied
                threadOwnershipNotice = Self.occupiedThreadMessage
            } else {
                threadInputAvailability = .available
                errorMessage = error.localizedDescription
            }
        }
    }

    func loadSelectedThread() async {
        guard let id = selectedThreadID else {
            messages = []
            isConversationLoading = false
            return
        }
        let generation = selectionGeneration
        isConversationLoading = true
        defer {
            if generation == selectionGeneration, selectedThreadID == id {
                isConversationLoading = false
            }
        }
        do {
            var (updated, loadedMessages) = try await client.readThread(id)
            guard !Task.isCancelled, generation == selectionGeneration, selectedThreadID == id else { return }
            if locallyRunningThreadIDs.contains(id) { updated.status = "active" }
            threadSummaries[id] = updated
            updateFavoriteSnapshot(updated)
            if let index = threads.firstIndex(where: { $0.id == id }), threads[index] != updated {
                threads[index] = updated
            }
            if selectedThreadID == id {
                flushPendingDeltas()
                storeMessages(ConversationHistory.merge(snapshot: loadedMessages, cached: messages), for: id)
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
                guard !Task.isCancelled, generation == selectionGeneration else { return }
                do {
                    let activity = try await client.readLatestThreadActivity(id, knownThread: updated)
                    guard !Task.isCancelled, generation == selectionGeneration, selectedThreadID == id else { return }
                    flushPendingDeltas()
                    if locallyRunningThreadIDs.contains(id) {
                        storeMessages(ConversationHistory.merge(snapshot: activity.messages, cached: messages), for: id)
                    } else {
                        applyExternalActivitySnapshot(activity, threadID: id)
                    }
                } catch {
                    // Some installed Codex app-server versions do not provide
                    // thread/items/list. The complete thread read above still
                    // gives a usable conversation, so keep it visible rather
                    // than showing an error dialog during every selection.
                }
            }
        } catch {
            if !Task.isCancelled, generation == selectionGeneration {
                errorMessage = error.localizedDescription
            }
        }
    }

    func sendMessage() async {
        if let id = selectedThreadID, canSend,
           isSelectedThreadProcessing || !selectedWaitingMessages.isEmpty {
            enqueueComposerMessage(threadID: id)
            return
        }
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoingAttachments = attachments
        let outgoingModel = selectedModel?.model
        let outgoingEffort = selectedEffort
        let outgoingPermissions = selectedPermissionID
        let outgoingServiceTier = serviceTierForTurn
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
                model: outgoingModel,
                effort: outgoingEffort,
                permissions: outgoingPermissions,
                serviceTierForTurn: outgoingServiceTier
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
            threadInputAvailability = .occupied
            threadOwnershipNotice = Self.occupiedThreadMessage
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
        if selectedThreadID == threadID {
            turnProgressHintTask?.cancel()
            turnProgressHintTask = nil
        }
        storeMessages(conversationMessages(for: threadID).filter {
            $0.id != localMessageID && $0.id != "turn-progress"
        }, for: threadID)
        liveTurnMetadataByThread.removeValue(forKey: threadID)
        guard selectedThreadID == threadID else { return }
        composerText = text
        attachments = outgoingAttachments
    }

    static func isActiveWriterError(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("active writer")
    }

    static let occupiedThreadMessage = "请先在另一个应用中关闭此会话，才能在这里继续。"

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
        let generation = selectionGeneration
        let revision = turnEventRevision[threadID, default: 0]
        do {
            let thread = try await client.readThreadState(threadID)
            guard selectedThreadID == threadID, !isSending else { return }
            let snapshot: ThreadActivitySnapshot
            if thread.status == "active" || isExternalThreadProcessing || client.shouldRefreshActivity(thread) {
                snapshot = try await client.readLatestThreadActivity(
                    threadID,
                    knownThread: thread
                )
            } else {
                snapshot = ThreadActivitySnapshot(thread: thread, turn: nil, messages: [])
            }
            guard !Task.isCancelled, selectedThreadID == threadID, !isSending,
                  generation == selectionGeneration,
                  revision == turnEventRevision[threadID, default: 0] else { return }
            applyExternalActivitySnapshot(snapshot, threadID: threadID)
        } catch {
            // Monitoring is best-effort. The primary app-server connection and
            // manual refresh remain available if another Codex process is busy.
        }
    }

    func applyExternalActivitySnapshot(_ snapshot: ThreadActivitySnapshot, threadID: String) {
        guard selectedThreadID == threadID, !isSending else { return }
        let isActive = snapshot.turn?.isActive == true || snapshot.thread.status == "active"
        if isActive {
            threadOutcomes.removeValue(forKey: threadID)
        } else if let status = snapshot.turn?.status, let outcome = ConversationOutcome(rawValue: status) {
            threadOutcomes[threadID] = outcome
        }
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
        var merged = ConversationHistory.merge(
            snapshot: snapshot.messages,
            cached: messages.filter { $0.id != "turn-progress" }
        )

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
            if let lastUserIndex = merged.lastIndex(where: { $0.role == .user }) {
                merged.insert(progress, at: lastUserIndex + 1)
            } else {
                merged.insert(progress, at: 0)
            }
        } else {
            for index in merged.indices where merged[index].isStreaming {
                merged[index].isStreaming = false
                if merged[index].role == .activity { merged[index].activityStatus = "已完成" }
            }
        }

        storeMessages(merged, for: threadID)
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
        if let preferredEffort, option.composerEfforts.contains(preferredEffort) {
            selectedEffort = preferredEffort
        } else if let selectedEffort, option.composerEfforts.contains(selectedEffort) {
            self.selectedEffort = selectedEffort
        } else {
            selectedEffort = option.defaultComposerEffort
        }
    }

    func setFastModeEnabled(_ enabled: Bool) {
        guard !enabled || supportsFastMode else { return }
        isFastModeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: fastModeKey)
    }

    func prepareNewThread() {
        speech.stop()
        cancelWaitingMessageEdit()
        newThreadFocusRequest = UUID()
        if showingNewThread { return }
        newThreadFolder = selectedFolder
            ?? selectedThread?.cwd
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        newThreadPrompt = ""
        newThreadAttachments = []
        threadOwnershipNotice = nil
        selectedThreadMonitorTask?.cancel()
        selectedThreadMonitorTask = nil
        preserveSelectedConversation()
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
            preserveSelectedConversation()
            threadRequestGeneration += 1
            if selectedFolder != folder { threads = [] }
            threads.insert(thread, at: 0)
            threadSummaries[thread.id] = thread
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
        remoteDefaults.set(enabled, forKey: remoteControlEnabledKey)
        if enabled {
            startRemoteControlIfNeeded()
        } else {
            remoteControlLoopTask?.cancel()
            remoteControlLoopTask = nil
            remoteUsageTask?.cancel()
            remoteUsageTask = nil
            remoteUsageSnapshot = nil
            remoteUsageLastAttempt = nil
            remoteSchedulingTask?.cancel()
            // Keep its handle until the canceled worker exits. Its defer must
            // not clear a replacement worker after a quick off/on toggle.
            remoteSchedulingLastAttempt = nil
            remoteControlStatus = remoteExecutions.isEmpty ? "远程控制已关闭" : "当前远程任务完成后停止"
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
            if let remoteCredentialIssue {
                remoteControlStatus = remoteCredentialIssue
            } else {
                loadRemoteCredential(allowInteraction: false)
            }
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

    /// Only this explicit button action may present a macOS permission prompt.
    /// Starting the app, reconnecting, toggling remote control, and polling never do.
    func authorizeRemoteControl() {
        guard remoteControlEnabled, remoteControlAPI == nil else { return }
        loadRemoteCredential(allowInteraction: true)
    }

    private func loadRemoteCredential(allowInteraction: Bool) {
        guard remoteControlEnabled, !isLoadingRemoteCredential else { return }
        isLoadingRemoteCredential = true
        remoteCredentialIssue = nil
        remoteControlStatus = allowInteraction ? "等待钥匙串授权…" : "正在检查远程设备凭据…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let api = try await self.remoteAPILoader(allowInteraction)
                self.remoteControlAPI = api
                self.isLoadingRemoteCredential = false
                // If the switch was turned off while macOS was authorizing,
                // cache the result but do not reconnect or claim another task.
                self.startRemoteControlIfNeeded()
            } catch {
                self.isLoadingRemoteCredential = false
                // Latch all failures. Do not spin or retry on list refreshes.
                let message = (error as? RemoteCredentialError)?.localizedDescription
                    ?? "设备凭据暂时不可用；自动连接已暂停。"
                self.remoteCredentialIssue = message
                if self.remoteControlEnabled { self.remoteControlStatus = message }
            }
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
        // Initial global read also avoids briefly clearing the relay's history
        // with whichever workspace happens to be selected at launch.
        await refreshRemoteSchedulingSnapshot()
        while !Task.isCancelled, remoteControlEnabled {
            refreshRemoteUsageIfNeeded()
            refreshRemoteSchedulingIfNeeded()
            if heartbeatCountdown <= 0 {
                do {
                    let response = try await api.heartbeat(makeRemoteHeartbeat(ready: true))
                    remoteControlPaired = response.paired
                    remoteLastSyncAt = Date()
                    if response.paired, let running = response.runningTasks {
                        reconcileRemoteTasks(running, api: api)
                    }
                    if response.paired {
                        remotePairingCode = ""
                        remoteDefaults.removeObject(forKey: remotePairingCodeKey)
                        if remoteExecutions.isEmpty {
                            remoteControlStatus = remoteStatusOutbox.pending(deviceID: api.deviceID).isEmpty
                                ? (response.queueSummary?.waitingDescription
                                   ?? ((response.runningTasks?.isEmpty ?? true) ? "已配对，正在等待远程任务" : "已连接，正在核对未结束任务"))
                                : "任务状态待补传，正在自动重试"
                        }
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

            // Disabling remote control can happen while heartbeat is in flight.
            // Do not dispatch a new unstructured claim worker after that await.
            guard !Task.isCancelled, remoteControlEnabled else { break }
            if remoteControlPaired, remoteHistoryTask == nil {
                remoteHistoryTask = Task { [weak self] in
                guard let self else { return }
                defer { self.remoteHistoryTask = nil }
                // Account resets are explicit confirmed commands, separate from development turns.
                do {
                    if let attempt = try await api.nextReset(), self.remoteControlEnabled, !Task.isCancelled {
                        let outcome = try await self.client.consumeRemoteReset(attempt)
                        try await api.finishReset(attempt.id, status: outcome)
                        self.remoteUsageSnapshot = (try? await self.client.readRemoteUsage()) ?? .unavailable()
                        self.remoteUsageLastAttempt = Date()
                    }
                } catch { /* Keep the durable attempt for retry with the same idempotency key. */ }
                // History remains read-only, never a turn/start or thread/resume task.
                do {
                    if let read = try await api.nextHistory() {
                        var response: RemoteHistoryResponse
                        do {
                            guard self.remoteControlEnabled, self.makeRemoteHeartbeat(ready: true).workspaces.contains(where: { $0.path == read.workspace }) else {
                                throw RemoteControlError.server("工作区不在远程授权范围内")
                            }
                            let page = try await self.client.readRemoteHistory(read)
                            guard try JSONEncoder().encode(page).count <= 8 * 1024 * 1024 else {
                                throw RemoteControlError.server("此轮会话过大，请在 Mac 查看完整内容")
                            }
                            response = RemoteHistoryResponse(page: page, error: "")
                        } catch {
                            response = RemoteHistoryResponse(page: nil, error: "读取会话失败，请确认工作区授权及 Codex 版本；过大的会话请在 Mac 查看。")
                        }
                        guard self.remoteControlEnabled, !Task.isCancelled else { return }
                        try await api.finishHistory(read.id, body: response)
                    }
                } catch { /* Old relay versions do not support history; do not disrupt execution. */ }
                }
            }
            if remoteControlPaired, remoteClaimTask == nil,
               remoteExecutions.count < maxConcurrentRemoteExecutions {
                // A slow image download / writer check must not pause heartbeat,
                // history reads or status recovery. Keep claiming single-flight.
                remoteClaimTask = Task { [weak self] in
                    guard let self else { return }
                    defer { self.remoteClaimTask = nil }
                    guard self.remoteControlEnabled, !Task.isCancelled else { return }
                    do {
                        if let task = try await api.nextTask() {
                            // Finish a claim even if the switch changed while the
                            // HTTP response was in flight; never orphan that row.
                            await self.executeRemoteTask(task)
                        }
                    } catch {
                        if !Task.isCancelled { self.remoteControlStatus = "任务领取失败：\(error.localizedDescription)" }
                    }
                }
            }

            // Independent worker: status retries must not delay heartbeats or task claiming.
            if remoteControlPaired, remoteStatusUploadTask == nil,
               !remoteStatusOutbox.pending(deviceID: api.deviceID).isEmpty {
                remoteStatusUploadTask = Task { [weak self] in
                    guard let self else { return }
                    defer { self.remoteStatusUploadTask = nil }
                    for (id, body) in self.remoteStatusOutbox.pending(deviceID: api.deviceID) {
                        guard !Task.isCancelled else { return }
                        await self.uploadRemoteStatus(id, body: body, api: api)
                    }
                }
            }

            if remoteProgressUploadTask == nil {
                remoteProgressUploadTask = Task { [weak self] in
                    guard let self else { return }
                    defer { self.remoteProgressUploadTask = nil }
                    await self.uploadRemoteProgress(api: api)
                }
            }
            heartbeatCountdown -= 1
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    private func uploadRemoteProgress(api: RemoteControlAPI) async {
        let pendingProgressUploads = remoteExecutions.filter { $0.value.progress.revision != $0.value.uploadedRevision }
        for (threadID, execution) in pendingProgressUploads {
            do {
                let body = await client.withActualTurnSettings(RemoteTaskStatusBody(
                    status: "running", threadId: execution.threadID, turnId: execution.turnID ?? "",
                    result: execution.responseText, error: "", progress: execution.progress
                ))
                applyVerifiedRemoteSettings(body)
                try await api.updateTask(execution.taskID, body: body)
                if remoteExecutions[threadID]?.taskID == execution.taskID {
                    remoteExecutions[threadID]?.uploadedRevision = execution.progress.revision
                }
            } catch {
                if !Task.isCancelled { remoteControlStatus = "执行过程同步失败，将自动重试" }
            }
        }
    }

    private func applyRemoteRegistration(_ registration: RemoteRegistration) {
        remoteControlPaired = registration.paired
        if !registration.pairingCode.isEmpty {
            remotePairingCode = registration.pairingCode
            remoteDefaults.set(registration.pairingCode, forKey: remotePairingCodeKey)
        }
        if registration.paired {
            remotePairingCode = ""
            remoteDefaults.removeObject(forKey: remotePairingCodeKey)
            remoteControlStatus = "已配对，正在等待远程任务"
        } else {
            remoteControlStatus = remotePairingCode.isEmpty ? "等待生成配对码…" : "等待小程序输入配对码"
        }
    }

    private func refreshRemoteUsageIfNeeded() {
        guard remoteControlPaired, remoteUsageTask == nil,
              remoteUsageLastAttempt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        remoteUsageLastAttempt = Date()
        // Independent request: slow quota reads must not block device heartbeats
        // or the remote task queue. No reset/consume operation is exposed.
        remoteUsageTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = (try? await self.client.readRemoteUsage()) ?? .unavailable()
            guard !Task.isCancelled, self.remoteControlEnabled else { return }
            self.remoteUsageSnapshot = snapshot
            self.remoteUsageTask = nil
        }
    }

    private func refreshRemoteSchedulingIfNeeded() {
        guard remoteSchedulingTask == nil,
              remoteSchedulingLastAttempt.map({ Date().timeIntervalSince($0) >= 9 }) ?? true else { return }
        remoteSchedulingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.remoteSchedulingTask = nil }
            await self.refreshRemoteSchedulingSnapshot()
        }
    }

    func refreshRemoteSchedulingSnapshot(fetch: (() async throws -> [CodexThread])? = nil) async {
        remoteSchedulingGeneration += 1
        let generation = remoteSchedulingGeneration
        remoteSchedulingLastAttempt = Date()
        // No cwd filter and no mutation of the sidebar or current selection.
        let snapshot: [CodexThread]
        do {
            if let fetch { snapshot = try await fetch() }
            else { snapshot = try await client.listThreads(limit: 300).threads }
        } catch { return }
        guard !Task.isCancelled, generation == remoteSchedulingGeneration else { return }
        applyRemoteSchedulingSnapshot(snapshot)
    }

    func applyRemoteSchedulingSnapshot(_ snapshot: [CodexThread]) {
        remoteSchedulingState.replace(with: snapshot)
    }

    func makeRemoteHeartbeat(ready: Bool) -> RemoteHeartbeatBody {
        let workspaces = folderCatalog.prefix(200).map {
            RemoteWorkspaceSnapshot(path: $0.path, name: $0.name)
        }
        let snapshots = remoteSchedulingState.snapshots(
            allowedPaths: Set(workspaces.map(\.path)),
            locallyRunning: locallyRunningThreadIDs.compactMap { threadSummaries[$0] }
        )
        return RemoteHeartbeatBody(
            name: remoteControlAPI?.deviceName ?? "CloudCodex Mac",
            permissionLabel: remotePermissionLabel,
            remoteControlReady: ready,
            workspaces: Array(workspaces),
            threads: Array(snapshots),
            usage: remoteControlPaired ? remoteUsageSnapshot : nil,
            defaultModel: selectedModel?.model,
            defaultEffort: selectedEffort,
            systemMetrics: remoteControlPaired && systemMetrics.snapshot.hasValues ? systemMetrics.snapshot : nil
        )
    }

    private func executeRemoteTask(_ task: RemoteTask) async {
        guard let api = remoteControlAPI else { return }
        guard folderCatalog.contains(where: { $0.path == task.workspace }) else {
            await failRemoteTask(task, message: "工作区不在 CloudCodex 的授权列表中。")
            return
        }

        let requestedModel = task.model.trimmingCharacters(in: .whitespacesAndNewlines)
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
            if !(task.imageUrls ?? []).isEmpty { remoteControlStatus = "正在下载并准备任务图片…" }
            let attachments = try await RemoteImageLoader.attachments(task.imageUrls ?? [])
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

            remoteExecutions[threadID] = RemoteExecution(taskID: task.taskId, threadID: threadID, turnID: nil, responseText: "")
            remoteControlStatus = "正在执行 \(remoteExecutions.count) 个远程任务"
            setLocalTurnRunning(threadID)
            setThreadRunning(threadID, running: true)
            // Capture this remote request, never the visible composer's model.
            liveTurnMetadataByThread[threadID] = TurnModelMetadata(
                model: modelOption?.model, reasoningEffort: effort
            )
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
            if remoteExecutions[threadID]?.taskID == task.taskId {
                remoteExecutions[threadID]?.turnID = turnID
            }
            do {
                let body = await client.withActualTurnSettings(RemoteTaskStatusBody(
                    status: "running",
                    threadId: threadID,
                    turnId: turnID ?? "",
                    result: "",
                    error: ""
                ))
                applyVerifiedRemoteSettings(body)
                try await api.updateTask(task.taskId, body: body)
            } catch {
                // The server already marked the task running when it was claimed.
                // Keep tracking the real Codex turn so its completion can retry
                // the final status instead of abandoning an active task.
                remoteControlStatus = "任务正在执行，运行状态暂未同步"
            }
            await refreshThreads()
        } catch {
            // A busy check can fail before this task owns any turn. Never erase
            // another task's local execution or mark an external writer idle.
            if remoteExecutions[threadID]?.taskID == task.taskId {
                clearLocalTurn(threadID)
                liveTurnMetadataByThread.removeValue(forKey: threadID)
                setThreadRunning(threadID, running: false)
                remoteExecutions.removeValue(forKey: threadID)
            }
            if Self.shouldDeferRemoteTask(error) {
                await deferRemoteTask(task, threadID: threadID, reason: Self.remoteWaitReason(error))
                return
            }
            await failRemoteTask(task, threadID: threadID, message: error.localizedDescription)
        }
    }

    static func shouldDeferRemoteTask(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("active writer")
            || message.contains("这个会话正在 codex 中运行")
            || message.contains("这个会话正在执行其他任务")
    }

    static func remoteWaitReason(_ error: Error) -> String {
        error.localizedDescription.lowercased().contains("active writer") ? "writer_busy" : "thread_busy"
    }

    private func deferRemoteTask(_ task: RemoteTask, threadID: String, reason: String) async {
        remoteSchedulingState.deferBusyThread(task)
        remoteControlStatus = reason == "writer_busy"
            ? "该会话被另一 Codex 进程占用，等待释放；其他会话继续领取"
            : "该会话正在执行，任务已排队；其他会话继续领取"
        await reportRemoteTaskStatus(task.taskId, body: RemoteTaskStatusBody(
            status: "queued", threadId: threadID, turnId: "", result: "", error: "", waitReason: reason
        ))
    }

    private func failRemoteTask(_ task: RemoteTask, threadID: String = "", message: String) async {
        remoteControlStatus = remoteExecutions.isEmpty ? "远程任务失败：\(message)" : "正在执行 \(remoteExecutions.count) 个远程任务"
        await reportRemoteTaskStatus(task.taskId, body: RemoteTaskStatusBody(
            status: "failed", threadId: threadID, turnId: "", result: "", error: message
        ))
    }

    private func reconcileRemoteTasks(_ tasks: [RemoteRecoveryTask], api: RemoteControlAPI) {
        guard remoteRecoveryTask == nil, !tasks.isEmpty,
              remoteRecoveryLastAttempt.map({ Date().timeIntervalSince($0) >= 30 }) ?? true else { return }
        remoteRecoveryLastAttempt = Date()
        let authorized = Set(makeRemoteHeartbeat(ready: true).workspaces.map(\.path))
        let candidates = tasks.filter { authorized.contains($0.workspace) && remoteStatusOutbox.pending(deviceID: api.deviceID)[$0.taskId] == nil }
        remoteRecoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.remoteRecoveryTask = nil }
            for group in Dictionary(grouping: candidates, by: \.threadId).values {
                guard self.remoteControlEnabled, !Task.isCancelled else { return }
                do {
                    let updates = try await self.client.readRemoteRecovery(group)
                    for (id, body) in updates {
                        guard self.remoteControlEnabled, !Task.isCancelled else { return }
                        // The live completion callback may have queued a richer final report while we read history.
                        if self.remoteStatusOutbox.pending(deviceID: api.deviceID)[id] != nil { continue }
                        if let local = self.remoteExecutions[body.threadId], local.taskID == id, local.turnID == body.turnId {
                            self.remoteExecutions.removeValue(forKey: body.threadId)
                            if self.activeTurnIDsByThread[body.threadId] == body.turnId {
                                self.clearLocalTurn(body.threadId)
                                self.setThreadRunning(body.threadId, running: false)
                            }
                        }
                        await self.reportRemoteTaskStatus(id, body: body)
                    }
                } catch {
                    // A read failure is not evidence that a turn ended. Try again next heartbeat.
                    if !Task.isCancelled { self.remoteControlStatus = "未结束任务核对失败，将自动重试；正常任务不受影响" }
                }
            }
        }
    }

    private func reportRemoteTaskStatus(_ taskID: String, body: RemoteTaskStatusBody) async {
        guard let api = remoteControlAPI else { return }
        let body = await client.withActualTurnSettings(body)
        applyVerifiedRemoteSettings(body)
        remoteStatusOutbox.enqueue(deviceID: api.deviceID, taskID: taskID, body: body)
        await uploadRemoteStatus(taskID, body: body, api: api)
    }

    func applyVerifiedRemoteSettings(_ body: RemoteTaskStatusBody) {
        guard !body.turnId.isEmpty, let model = body.actualModel, !model.isEmpty else { return }
        let metadata = TurnModelMetadata(model: model, reasoningEffort: body.actualEffort)
        if activeTurnIDsByThread[body.threadId] == body.turnId {
            liveTurnMetadataByThread[body.threadId] = metadata
        }
        var updated = conversationMessages(for: body.threadId)
        var changed = false
        for index in updated.indices where updated[index].turnID == body.turnId {
            if updated[index].model != metadata.model || updated[index].reasoningEffort != metadata.reasoningEffort {
                updated[index].model = metadata.model
                updated[index].reasoningEffort = metadata.reasoningEffort
                changed = true
            }
        }
        if changed { storeMessages(updated, for: body.threadId) }
    }

    private func uploadRemoteStatus(_ taskID: String, body: RemoteTaskStatusBody, api: RemoteControlAPI) async {
        guard remoteStatusOutbox.pending(deviceID: api.deviceID)[taskID] == body else { return }
        do {
            try await api.updateTask(taskID, body: body)
            remoteStatusOutbox.acknowledge(deviceID: api.deviceID, taskID: taskID, body: body)
        } catch {
            if !Task.isCancelled { remoteControlStatus = "任务状态待补传，网络恢复后自动重试" }
        }
    }

    private func handleRemoteEvent(_ method: String, params: [String: Any], threadID: String) {
        guard var execution = remoteExecutions[threadID] else { return }
        if method == "error", params["willRetry"] as? Bool == true { return }
        let eventTurnID = params["turnId"] as? String ?? (params["turn"] as? [String: Any])?["id"] as? String
        if let expected = execution.turnID, let eventTurnID, expected != eventTurnID { return }
        execution.progress.consume(method, params)
        remoteExecutions[threadID] = execution
        switch method {
        case "turn/diff/updated":
            if let turnID = params["turnId"] as? String, let expected = execution.turnID, turnID != expected { return }
            if let diff = params["diff"] as? String {
                execution.fileDiff = String(diff.prefix(200_000)) + (diff.count > 200_000 ? "\n[差异过长，已截断，请在 Mac 查看完整内容]" : "")
                remoteExecutions[threadID] = execution
            }
        case "turn/started":
            let turn = params["turn"] as? [String: Any]
            execution.turnID = turn?["id"] as? String ?? execution.turnID
            remoteExecutions[threadID] = execution
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String {
                if let id = params["itemId"] as? String, id != execution.responseItemID {
                    execution.responseItemID = id
                    execution.responseText = ""
                }
                execution.responseText = Self.clippedRemoteResult(execution.responseText + delta)
                remoteExecutions[threadID] = execution
            }
        case "item/completed":
            if let item = params["item"] as? [String: Any],
               item["type"] as? String == "agentMessage",
               let text = item["text"] as? String {
                execution.responseItemID = item["id"] as? String
                execution.responseText = Self.clippedRemoteResult(text)
                remoteExecutions[threadID] = execution
            }
        case "turn/completed":
            let turn = params["turn"] as? [String: Any]
            let status = turn?["status"] as? String ?? "completed"
            let errorObject = turn?["error"] as? [String: Any]
            let errorText = errorObject?["message"] as? String ?? ""
            remoteExecutions.removeValue(forKey: threadID)
            remoteControlStatus = remoteExecutions.isEmpty
                ? (status == "completed" ? "远程任务已完成" : "远程任务执行失败")
                : "正在执行 \(remoteExecutions.count) 个远程任务"
            Task { [weak self] in
                await self?.reportRemoteTaskStatus(execution.taskID, body: RemoteTaskStatusBody(
                        status: status == "completed" ? "completed" : "failed",
                        threadId: execution.threadID,
                        turnId: execution.turnID ?? "",
                        result: execution.responseText,
                        error: errorText,
                        fileDiff: execution.fileDiff, progress: execution.progress
                ))
            }
        case "error":
            let errorObject = params["error"] as? [String: Any]
            let message = errorObject?["message"] as? String ?? "Codex 执行远程任务失败。"
            remoteExecutions.removeValue(forKey: threadID)
            clearLocalTurn(execution.threadID)
            setThreadRunning(execution.threadID, running: false)
            remoteControlStatus = remoteExecutions.isEmpty ? "远程任务失败：\(message)" : "正在执行 \(remoteExecutions.count) 个远程任务"
            Task { [weak self] in
                await self?.reportRemoteTaskStatus(execution.taskID, body: RemoteTaskStatusBody(
                        status: "failed", threadId: execution.threadID,
                        turnId: execution.turnID ?? "", result: execution.responseText, error: message,
                        fileDiff: execution.fileDiff, progress: execution.progress
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

    func handleServerRequest(_ requestID: AppServerRequestID, method: String, params: [String: Any]) {
        if method == "item/tool/call" {
            Task { [weak self] in
                guard let self else { return }
                let result: [String: Any]
                if params["tool"] as? String == BrowserTool.name,
                   let threadID = params["threadId"] as? String,
                   let arguments = params["arguments"] as? [String: Any] {
                    result = await browser.execute(threadID: threadID, arguments: arguments)
                } else {
                    result = BrowserTool.result("CloudCodex 不支持此动态工具。", success: false)
                }
                do { try client.respond(to: requestID, result: result) }
                catch { errorMessage = "浏览器结果发送失败：\(error.localizedDescription)" }
            }
            return
        }
        guard method == "item/tool/requestUserInput",
              let request = UserInputRequest(requestID: requestID, params: params, timeout: userInputTimeoutSeconds) else { return }
        userInputTimeoutTasks.removeValue(forKey: request.id)?.cancel()
        if let index = userInputRequests.firstIndex(where: { $0.id == request.id }) {
            userInputRequests[index] = request
        } else {
            userInputRequests.append(request)
        }
        upsertConversationActivity(threadID: request.threadID,
            id: "user-input-\(request.itemID)", title: "Codex 需要你的输入",
            text: request.questions.map(\.question).joined(separator: "\n"), status: "待回答")
        let delay = max(0, request.expiresAt.timeIntervalSinceNow)
        userInputTimeoutTasks[request.id] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.expireUserInputRequest(request.id)
        }
    }

    private func expireUserInputRequest(_ requestID: String) {
        guard let request = userInputRequests.first(where: { $0.id == requestID }), !request.isSubmitting else { return }
        do {
            try client.respond(to: request.requestID, result: request.skippedResponsePayload)
            userInputTimeoutTasks.removeValue(forKey: requestID)
            userInputRequests.removeAll { $0.id == requestID }
            upsertConversationActivity(threadID: request.threadID,
                id: "user-input-\(request.itemID)", title: "已自动跳过输入",
                text: "1 分钟内未收到回答，CloudCodex 已跳过本次输入并让任务继续执行。", status: "已跳过")
        } catch {
            userInputTimeoutTasks.removeValue(forKey: requestID)
            guard let index = userInputRequests.firstIndex(where: { $0.id == requestID }) else { return }
            userInputRequests[index].error = "自动跳过失败：\(error.localizedDescription)"
        }
    }

    func handleEvent(_ method: String, _ params: [String: Any]) {
        guard let eventThreadID = params["threadId"] as? String else {
            if method == "error", let error = params["error"] as? [String: Any] {
                if params["willRetry"] as? Bool == true {
                    connectionText = error["message"] as? String ?? "正在重新连接 Codex"
                    return
                }
                flushPendingDeltas()
                if let selectedThreadID { clearLocalTurn(selectedThreadID) }
                finishTurnProgress(status: "失败")
                let message = error["message"] as? String ?? "Codex 发生错误"
                if !Self.isOptionalActivityCapabilityError(message) {
                    errorMessage = message
                }
            }
            return
        }
        if method == "serverRequest/resolved",
           let rawID = params["requestId"], let requestID = AppServerRequestID(rawID),
           let resolved = userInputRequests.first(where: { $0.id == requestID.stableID }) {
            userInputTimeoutTasks.removeValue(forKey: requestID.stableID)?.cancel()
            userInputRequests.removeAll { $0.id == requestID.stableID }
            upsertConversationActivity(threadID: eventThreadID,
                id: "user-input-\(resolved.itemID)", title: "输入请求已结束",
                text: "该请求已由 Codex 处理或随任务状态变化而取消。", status: "已处理")
        }
        if method == "turn/started" || method == "turn/completed" || method == "error" {
            turnEventRevision[eventThreadID, default: 0] += 1
        }
        if method == "turn/completed" { flushPendingDeltas() }
        if method == "turn/started" {
            let turn = params["turn"] as? [String: Any]
            // External turns have no trustworthy composer settings. Leave the
            // badge unknown until this exact turn's persisted context is read.
            setLocalTurnRunning(eventThreadID, turnID: turn?["id"] as? String)
            setThreadRunning(eventThreadID, running: true)
        } else if method == "turn/completed" {
            let turn = params["turn"] as? [String: Any]
            if let incomingID = turn?["id"] as? String,
               let activeID = activeTurnIDsByThread[eventThreadID], incomingID != activeID { return }
            clearLocalTurn(eventThreadID)
            setThreadRunning(eventThreadID, running: false)
            if let status = turn?["status"] as? String {
                threadOutcomes[eventThreadID] = ConversationOutcome(rawValue: status)
                if status == "completed", let turnID = turn?["id"] as? String {
                    recordCompletedConversation(eventThreadID, turnID: turnID,
                        viewed: selectedThreadID == eventThreadID)
                }
            }
            if let turnID = turn?["id"] as? String {
                let expiredIDs = userInputRequests.filter { $0.threadID == eventThreadID && $0.turnID == turnID }.map(\.id)
                expiredIDs.forEach { userInputTimeoutTasks.removeValue(forKey: $0)?.cancel() }
                userInputRequests.removeAll { $0.threadID == eventThreadID && $0.turnID == turnID }
            }
        }

        handleRemoteEvent(method, params: params, threadID: eventThreadID)

        self.eventBuffer = conversationMessages(for: eventThreadID)
        self.eventThreadID = eventThreadID
        defer {
            let updated = self.eventBuffer ?? []
            self.eventThreadID = nil
            self.eventBuffer = nil
            storeMessages(updated, for: eventThreadID)
            if method == "turn/completed" || (method == "error" && params["willRetry"] as? Bool != true) {
                liveTurnMetadataByThread.removeValue(forKey: eventThreadID)
            }
        }

        if method.hasPrefix("item/") || method == "turn/completed" {
            for index in eventMessages.indices where eventMessages[index].id.hasPrefix("connection-notice-")
                && eventMessages[index].activityStatus == "重连中" {
                eventMessages[index].activityStatus = "已恢复"
                eventMessages[index].activityTitle = "连接已恢复"
                eventMessages[index].text = "已继续收到 Codex 的任务进度。"
                eventMessages[index].isStreaming = false
            }
        }

        switch method {
        case "turn/started":
            // Associate the optimistic question before a history snapshot can
            // introduce its confirmed server-side identity.
            if let index = eventMessages.lastIndex(where: { $0.id.hasPrefix("local-") && $0.turnID == nil }) {
                applyLiveTurnMetadata(to: &eventMessages[index], threadID: eventThreadID)
            }
            upsertActivity(
                id: "turn-progress",
                kind: .status,
                title: "Codex 正在处理",
                text: "请求已发送，正在等待 Codex 返回第一条实时进度…",
                status: "进行中",
                isStreaming: true
            )
            if let index = eventMessages.firstIndex(where: { $0.id == "turn-progress" }),
               eventMessages[index].startedAt == nil {
                eventMessages[index].startedAt = Date()
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
            flushPendingDeltas()
            let id = params["itemId"] as? String ?? "reasoning"
            if let index = eventMessages.firstIndex(where: { $0.id == id }) {
                if !eventMessages[index].text.isEmpty { eventMessages[index].text += "\n" }
            } else {
                upsertActivity(id: id, kind: .reasoning, title: "思考摘要", text: "",
                               status: "进行中", isStreaming: true)
            }
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
                if let index = eventMessages.firstIndex(where: { $0.id == id }) {
                    eventMessages[index].text = text
                    eventMessages[index].isStreaming = false
                    eventMessages[index].timestamp = Date()
                    applyLiveTurnMetadata(to: &eventMessages[index], threadID: eventThreadID)
                } else {
                    let metadata = liveTurnMetadataByThread[eventThreadID]
                    eventMessages.append(.init(
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
            if selectedThreadID == eventThreadID { isExternalThreadProcessing = false }
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
            let error = params["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "Codex 发生错误"
            guard !Self.isOptionalActivityCapabilityError(message) else { break }
            let retrying = params["willRetry"] as? Bool == true
            let turnID = params["turnId"] as? String ?? activeTurnIDsByThread[eventThreadID] ?? "current"
            upsertActivity(id: "connection-notice-\(turnID)", kind: .warning,
                           title: retrying ? "连接中断，正在重试" : "任务发生错误",
                           text: message, status: retrying ? "重连中" : "失败",
                           isStreaming: retrying)
            if retrying { break }
            clearLocalTurn(eventThreadID)
            if selectedThreadID == eventThreadID { isExternalThreadProcessing = false }
            setThreadRunning(eventThreadID, running: false)
            finishTurnProgress(status: "失败")
            threadOutcomes[eventThreadID] = .failed
        default:
            break
        }
    }

    private static func isOptionalActivityCapabilityError(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("thread/items/list")
            && message.localizedCaseInsensitiveContains("not supported")
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
                           text: completed ? "图像生成已结束" : "正在生成图像资源…", status: runningStatus,
                           isStreaming: !completed)
            if completed, let image = GeneratedImageMessage.fromItem(item),
               !eventMessages.contains(where: { $0.id == image.id }) {
                eventMessages.append(image)
            }
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
        if let index = eventMessages.firstIndex(where: { $0.id == id }) {
            eventMessages[index].activityKind = kind
            eventMessages[index].activityTitle = title
            if !clipped.isEmpty { eventMessages[index].text = clipped }
            eventMessages[index].activityStatus = status
            eventMessages[index].isStreaming = isStreaming
        } else {
            eventMessages.append(.init(id: id, role: .activity, text: clipped, isStreaming: isStreaming,
                                  activityKind: kind, activityTitle: title, activityStatus: status,
                                  turnID: (eventThreadID ?? selectedThreadID).flatMap { activeTurnIDsByThread[$0] }))
        }
    }

    private func enqueueActivityDelta(
        id: String,
        kind: ChatMessage.ActivityKind,
        title: String,
        delta: String
    ) {
        guard let threadID = eventThreadID ?? selectedThreadID else { return }
        let key = PendingItemKey(threadID: threadID, itemID: id)
        if var pending = pendingActivityDeltas[key] {
            pending.chunks.append(delta)
            pending.kind = kind
            pending.title = title
            pendingActivityDeltas[key] = pending
        } else {
            pendingActivityDeltas[key] = PendingActivityDelta(
                kind: kind,
                title: title,
                chunks: [delta]
            )
            pendingDeltaOrder.append(.activity(key))
        }
        schedulePendingDeltaFlush()
    }

    private func enqueueAssistantDelta(id: String, delta: String) {
        guard let threadID = eventThreadID ?? selectedThreadID else { return }
        let key = PendingItemKey(threadID: threadID, itemID: id)
        if pendingAssistantDeltas[key] == nil {
            pendingDeltaOrder.append(.assistant(key))
        }
        pendingAssistantDeltas[key, default: []].append(delta)
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

        var updates: [String: [ChatMessage]] = [:]
        for target in order {
            let key = target.key
            let id = key.itemID
            let threadID = key.threadID
            var updatedMessages = updates[threadID] ?? conversationMessages(for: threadID)
            switch target {
            case .activity:
                guard let pending = activityDeltas[key] else { continue }
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
                        activityStatus: "进行中",
                        turnID: activeTurnIDsByThread[threadID]
                    ))
                }
            case .assistant:
                guard let chunks = assistantDeltas[key] else { continue }
                let delta = chunks.joined()
                if let index = updatedMessages.firstIndex(where: { $0.id == id }) {
                    updatedMessages[index].text += delta
                    updatedMessages[index].isStreaming = true
                    applyLiveTurnMetadata(to: &updatedMessages[index], threadID: threadID)
                } else {
                    let metadata = liveTurnMetadataByThread[threadID]
                    updatedMessages.append(.init(
                        id: id,
                        role: .assistant,
                        text: delta,
                        isStreaming: true,
                        turnID: activeTurnIDsByThread[threadID],
                        model: metadata?.model,
                        reasoningEffort: metadata?.reasoningEffort
                    ))
                }
            }
            updates[threadID] = updatedMessages
        }
        for (threadID, updatedMessages) in updates {
            storeMessages(updatedMessages, for: threadID)
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
        var updatedMessages = eventMessages
        var didChange = false
        for index in updatedMessages.indices where
            updatedMessages[index].role == .assistant && updatedMessages[index].turnID == turnID {
            if updatedMessages[index].timestamp != completedAt {
                updatedMessages[index].timestamp = completedAt
                didChange = true
            }
        }
        if didChange { eventMessages = updatedMessages }
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

    private func completeStreamingActivities() {
        for index in eventMessages.indices
        where eventMessages[index].id != "turn-progress"
            && eventMessages[index].isStreaming {
            eventMessages[index].isStreaming = false
            eventMessages[index].activityStatus = "已完成"
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
        if eventThreadID == nil || eventThreadID == selectedThreadID {
            turnProgressHintTask?.cancel()
            turnProgressHintTask = nil
        }
        guard let index = eventMessages.firstIndex(where: { $0.id == "turn-progress" }) else { return }
        eventMessages[index].isStreaming = false
        eventMessages[index].activityStatus = status
        eventMessages[index].completedAt = Date()
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
