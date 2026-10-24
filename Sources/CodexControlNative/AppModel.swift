import AppKit
import Foundation

enum ThreadInputAvailability: Equatable {
    case checking
    case available
    case occupied
    case unavailable
}

@MainActor
final class AppModel: ObservableObject {
    static let recommendedModelSelectionID = "__cloudcodex_recommended__"

    @Published private(set) var customModelProvider: ModelProviderConfiguration
    @Published private(set) var providerLibrary: ModelProviderLibrary
    @Published private(set) var isSwitchingModelProvider = false
    private var openAIModelOptions: [CodexModelOption] = []

    let accounts: CodexAccountStore
    @Published var showingAccounts = false
    @Published private(set) var accountSwitchError: String?
    private var accountGeneration = 0
    private let localCodexHome: URL?

    let browser = EmbeddedBrowser()
    let connectionHealth: ConnectionHealth
    let systemMetrics = SystemMetricsMonitor()
    @Published private(set) var accountRefreshInterval: AccountRefreshInterval
    @Published private(set) var accountOverview: AccountOverview?
    @Published private(set) var accountOverviewError: String?
    @Published private(set) var resetCreditInProgressRef: String?
    @Published private(set) var resetCreditStatusMessage: String?
    @Published private(set) var resetCreditStatusIsError = false
    @Published private(set) var recentThirtyMinuteConsumptionRate: Double?
    @Published private(set) var usageInsights: CodexUsageInsights?
    @Published private(set) var usageInsightsError: String?
    @Published private(set) var isLoadingUsageInsights = false
    @Published var showingUsageInsights = false
    @Published var showingWeeklyQuotaComparison = false
    @Published private(set) var weeklyQuotaComparison = WeeklyQuotaComparison()
    @Published private(set) var weeklyQuotaBaseline: WeeklyQuotaComparison.Snapshot?
    @Published private(set) var automaticWeeklyQuotaSampler = AutomaticWeeklyQuotaSampler()
    @Published private(set) var automaticWeeklyQuotaEnabled = true
    @Published private(set) var isSamplingWeeklyQuota = false
    private var weeklyQuotaSamplingTask: Task<Void, Never>?
    private var weeklyQuotaSamplingGeneration = 0
    private let weeklyQuotaProbe: WeeklyQuotaProbe
    private var localQuotaTokenReader: CodexLocalTokenUsageReader
    @Published private(set) var providerUsage = ProviderUsageLedger()
    @Published private(set) var personalSkills: [CodexPersonalSkill] = []
    @Published private(set) var personalSkillsError: String?
    @Published private(set) var isLoadingPersonalSkills = false
    @Published var showingPersonalSkills = false
    @Published var threads: [CodexThread] = []
    @Published var folderCatalog: [WorkspaceFolder] = []
    @Published var selectedFolder: String?
    @Published var selectedThreadID: String?
    @Published var messages: [ChatMessage] = []
    @Published var composerText = ""
    @Published private(set) var composerPredictions: [ComposerPredictionSource: ComposerPredictionState] = [:]
    @Published private(set) var threadOutcomes: [String: ConversationOutcome] = [:]
    @Published private(set) var unreadCompletions = UnreadCompletions()
    @Published private(set) var isLoadingUnreadThreads = false
    @Published private(set) var unreadThreadsError: String?
    @Published private(set) var favoriteConversations = FavoriteConversations()
    @Published private(set) var userInputRequests: [UserInputRequest] = []
    private var userInputTimeoutTasks: [String: Task<Void, Never>] = [:]
    @Published private(set) var computerUseApprovalRequests: [ComputerUseApprovalRequest] = []
    private var computerUseApprovalTimeoutTasks: [String: Task<Void, Never>] = [:]
    private let userInputTimeoutSeconds: TimeInterval
    private var computerControlTimeoutTasks: [PendingItemKey: Task<Void, Never>] = [:]
    private let computerControlTimeoutSeconds: TimeInterval
    private var commandInactivityTimeoutTasks: [PendingItemKey: Task<Void, Never>] = [:]
    @Published private(set) var commandInactivityTimeoutMinutes: Int
    private let commandInactivityTimeoutOverride: TimeInterval?
    private var commandTimeoutRecoveryAttemptsByThread: [String: Int] = [:]
    static let maximumAutomaticCommandTimeoutRecoveries = 3
    private let unreadCompletionsKey = "cloudcodex.unreadCompletions.v1"
    private let favoriteConversationsKey = "cloudcodex.favoriteConversations.v1"
    private let quotaConsumptionHistoryKey = "cloudcodex.quotaConsumptionHistory.v1"
    private let revertedFileChangesKey = "cloudcodex.revertedFileChanges.v1"
    private var quotaConsumptionTracker = QuotaConsumptionTracker()
    private var quotaRestorationTracker = QuotaRestorationTracker()
    @Published private(set) var allowsExtraCreditUsage = false
    @Published private(set) var creditUsagePauseReason: CreditUsageProtection.Reason?
    @Published private(set) var creditUsagePauseFailures: [String: String] = [:]
    @Published private(set) var isRecheckingIncludedQuota = false
    @Published private(set) var includedQuotaCheckMessage: String?
    private var creditUsageProtection = CreditUsageProtection()
    private var creditUsageMonitorTask: Task<Void, Never>?
    private var creditUsageRefreshTask: Task<Void, Never>?
    private var creditInterruptingThreadIDs: Set<String> = []
    private let creditUsageReader: (() async throws -> AccountOverview)?
    private let creditTurnInterrupter: ((String, String) async throws -> Void)?
    private static let allowsExtraCreditUsageKey = "cloudcodex.allowsExtraCreditUsage.v1"
    private static let creditUsagePauseKey = "cloudcodex.creditUsagePause.v1"
    @Published private(set) var revertedFileChanges: Set<String> = []
    @Published private(set) var revertingFileChanges: String?

    func isFileChangeTurnReverted(_ turnID: String) -> Bool {
        guard let selectedThreadID else { return false }
        return revertedFileChanges.contains(fileChangeKey(threadID: selectedThreadID, turnID: turnID))
    }

    func isRevertingFileChangeTurn(_ turnID: String) -> Bool {
        guard let selectedThreadID else { return false }
        return revertingFileChanges == fileChangeKey(threadID: selectedThreadID, turnID: turnID)
    }

    func revertFileChanges(_ group: ConversationFileChangeGroup) async {
        guard let thread = selectedThread, thread.id == selectedThreadID else { return }
        let key = fileChangeKey(threadID: thread.id, turnID: group.turnID)
        guard revertingFileChanges == nil, !revertedFileChanges.contains(key) else { return }
        revertingFileChanges = key
        defer { revertingFileChanges = nil }
        do {
            try await FileChangePatchReverter.revert(group.changes, in: thread.cwd)
            revertedFileChanges.insert(key)
            remoteDefaults.set(Array(revertedFileChanges).sorted(), forKey: revertedFileChangesKey)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fileChangeKey(threadID: String, turnID: String) -> String {
        "\(threadID):\(turnID)"
    }

    func markConversationRead(_ threadID: String) {
        guard unreadCompletions.unread.contains(threadID) else { return }
        unreadCompletions.markRead(threadID)
        saveUnreadCompletions()
    }

    func recordCompletedConversation(_ threadID: String, turnID: String, viewed: Bool) {
        let isNewCompletion = unreadCompletions.complete(
            threadID: threadID,
            turnID: turnID,
            viewed: viewed
        )
        saveUnreadCompletions()
        guard isNewCompletion else { return }
        enqueueRemoteNotification(.init(
            type: RemoteNotificationEventBody.conversationCompleted,
            eventId: "conversation:\(threadID):\(turnID)",
            threadId: threadID,
            turnId: turnID,
            threadTitle: (threads.first { $0.id == threadID }
                ?? threadSummaries[threadID]
                ?? favoriteConversations.thread(threadID))?.displayName ?? "未命名会话"
        ))
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

    @Published private(set) var dismissedAssistantReplyQuestions: [String: Set<String>] = [:]
    @Published private(set) var submittingAssistantReplyThreads: Set<String> = []
    @Published private(set) var assistantReplyErrors: [String: String] = [:]

    var assistantReplyQuestion: AssistantReplyChoices.Question? {
        guard let selectedThreadID, !showingNewThread,
              threadInputAvailability == .available,
              editingWaitingMessageID == nil,
              selectedUserInputRequests.isEmpty,
              selectedComputerUseApprovalRequests.isEmpty else { return nil }
        return AssistantReplyChoices.question(in: messages,
            currentTurnID: activeTurnIDsByThread[selectedThreadID],
            dismissed: dismissedAssistantReplyQuestions[selectedThreadID] ?? [])
    }

    var assistantReplyChoices: [String] { assistantReplyQuestion?.options ?? [] }

    func dismissAssistantReplyQuestion(_ questionID: String) {
        guard let selectedThreadID, assistantReplyQuestion?.id == questionID else { return }
        dismissedAssistantReplyQuestions[selectedThreadID, default: []].insert(questionID)
    }

    func submitAssistantReplyAnswer(questionID: String, answer: String) async {
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let threadID = selectedThreadID, let question = assistantReplyQuestion,
              question.id == questionID, !answer.isEmpty, creditUsagePauseReason == nil,
              !isSwitchingModelProvider, !submittingAssistantReplyThreads.contains(threadID) else { return }
        submittingAssistantReplyThreads.insert(threadID)
        let errorKey = threadID + ":" + questionID
        assistantReplyErrors[errorKey] = nil
        defer { submittingAssistantReplyThreads.remove(threadID) }
        let text = "关于「\(question.prompt)」\n我的选择：\(answer)"
        do {
            if isSelectedThreadProcessing {
                let turnID: String
                if let known = activeTurnIDsByThread[threadID] ?? activeTurnID ?? question.turnID {
                    turnID = known
                } else {
                    let runtime = try await client.readLatestThreadActivity(threadID)
                    guard let turn = runtime.turn, turn.isActive else {
                        throw CodexClientError.server("当前任务已结束，请重新发送回答。")
                    }
                    turnID = turn.id
                }
                try await client.steerTurn(threadID: threadID, turnID: turnID, text: text, attachments: [])
                recordSteeredMessage(WaitingMessage(threadID: threadID, text: text, attachments: [],
                    model: selectedModel?.model, effort: selectedEffort, permissions: selectedPermissionID,
                    serviceTier: selectedServiceTier), turnID: turnID)
            } else {
                let localID = "local-choice-\(UUID())"
                do {
                    try await startTurnOptimistically(threadID: threadID, localMessageID: localID,
                        text: text, outgoingAttachments: [], model: selectedModel?.model, effort: selectedEffort,
                        permissions: selectedPermissionID, serviceTier: selectedServiceTier)
                } catch {
                    rollbackOptimisticSend(threadID: threadID, localMessageID: localID, text: text,
                        outgoingAttachments: [], restoreComposer: false)
                    throw error
                }
            }
            dismissedAssistantReplyQuestions[threadID, default: []].insert(questionID)
        } catch {
            assistantReplyErrors[errorKey] = error.localizedDescription
        }
    }

    @Published private(set) var replyChoiceFocusRequest = UUID()

    var composerPredictionSource: ComposerPredictionSource? {
        guard let selectedThreadID, !showingNewThread, !isConversationLoading,
              threadInputAvailability == .available, !isSelectedThreadProcessing,
              !isSwitchingModelProvider, creditUsagePauseReason == nil,
              composerText.isEmpty, attachments.isEmpty, !isRecording,
              editingWaitingMessageID == nil, selectedWaitingMessages.isEmpty,
              selectedUserInputRequests.isEmpty, selectedComputerUseApprovalRequests.isEmpty,
              assistantReplyChoices.isEmpty,
              let last = messages.last(where: { $0.role != .activity }),
              last.role == .assistant, !last.isStreaming,
              let turnID = last.turnID, !turnID.isEmpty else { return nil }
        return ComposerPredictionSource(threadID: selectedThreadID, turnID: turnID)
    }

    var composerSuggestion: String? {
        guard let source = composerPredictionSource,
              case .ready(let text) = composerPredictions[source] else { return nil }
        return text
    }

    func requestComposerPrediction(_ source: ComposerPredictionSource) async {
        guard !Task.isCancelled, client.connected, composerPredictionSource == source,
              composerPredictions[source] == nil else { return }
        composerPredictions = composerPredictions.filter { $0.key.threadID != source.threadID }
        composerPredictions[source] = .pending
        do {
            let text = (try await client.requestComposerPrediction(threadID: source.threadID, sourceTurnID: source.turnID))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard composerPredictions[source] == .pending else { return }
            composerPredictions[source] = !text.isEmpty && text.count <= 500 ? .ready(text) : .unavailable
        } catch {
            // Predictions are optional; a failed/unsupported service must not
            // disturb normal input or surface as a conversation failure.
            if composerPredictions[source] == .pending { composerPredictions[source] = .unavailable }
        }
    }

    func acceptComposerSuggestion() {
        guard let source = composerPredictionSource, let suggestion = composerSuggestion else { return }
        composerText = suggestion
        composerPredictions[source] = .consumed
        replyChoiceFocusRequest = UUID()
    }

    func selectAssistantReplyChoice(_ option: String) {
        let options = assistantReplyChoices
        guard options.contains(option) else { return }
        composerText = AssistantReplyChoices.draft(selecting: option, options: options, current: composerText)
        replyChoiceFocusRequest = UUID()
    }

    var selectedComputerUseApprovalRequests: [ComputerUseApprovalRequest] {
        guard let selectedThreadID else { return [] }
        return computerUseApprovalRequests.filter { $0.threadID == selectedThreadID }
    }

    func submitComputerUseApproval(
        requestID: String,
        decision: ComputerUseApprovalRequest.Decision
    ) {
        guard let index = computerUseApprovalRequests.firstIndex(where: { $0.id == requestID }) else { return }
        if creditUsagePauseReason != nil, decision == .allowSession || decision == .allowAlways { return }
        if decision == .allowAlways, !computerUseApprovalRequests[index].allowsAlways { return }
        computerUseApprovalRequests[index].isSubmitting = true
        computerUseApprovalRequests[index].error = nil
        let request = computerUseApprovalRequests[index]
        do {
            try client.respond(to: request.requestID, result: request.responsePayload(for: decision))
            computerUseApprovalTimeoutTasks.removeValue(forKey: requestID)?.cancel()
            computerUseApprovalRequests.removeAll { $0.id == requestID }
            let allowed = decision == .allowSession || decision == .allowAlways
            upsertConversationActivity(
                threadID: request.threadID,
                id: "computer-use-approval-\(request.id)",
                title: allowed ? "已授权电脑控制" : "已拒绝电脑控制",
                text: allowed
                    ? "CloudCodex 可以在所选范围内控制 \(request.applicationName)，正在继续执行。"
                    : "CloudCodex 已拒绝本次对 \(request.applicationName) 的控制请求。",
                status: allowed ? "已允许" : "已拒绝"
            )
        } catch {
            guard let retryIndex = computerUseApprovalRequests.firstIndex(where: { $0.id == requestID }) else { return }
            computerUseApprovalRequests[retryIndex].isSubmitting = false
            computerUseApprovalRequests[retryIndex].error = error.localizedDescription
        }
    }

    func submitUserInput(requestID: String, answers: [String: String]) {
        guard creditUsagePauseReason == nil else { return }
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
        let id: UUID
        let threadID: String
        var text: String
        let attachments: [ComposerAttachment]
        let model: String?
        let effort: String?
        let permissions: String?
        let serviceTier: String?
        let isAutomaticRecovery: Bool
        var error: String?

        init(id: UUID = UUID(), threadID: String, text: String, attachments: [ComposerAttachment],
             model: String?, effort: String?, permissions: String?, serviceTier: String?,
             isAutomaticRecovery: Bool = false, error: String? = nil) {
            self.id = id
            self.threadID = threadID
            self.text = text
            self.attachments = attachments
            self.model = model
            self.effort = effort
            self.permissions = permissions
            self.serviceTier = serviceTier
            self.isAutomaticRecovery = isAutomaticRecovery
            self.error = error
        }
    }
    @Published var waitingMessages: [WaitingMessage] = [] {
        didSet { persistWaitingMessagesIfReady() }
    }
    @Published private(set) var deliveringWaitingMessages: Set<UUID> = []
    @Published private(set) var editingWaitingMessageID: UUID?
    @Published var waitingMessageEditText = ""
    private var waitingPersistenceReady = false

    private struct PersistedWaitingMessage: Codable {
        let id: UUID
        let threadID: String
        let text: String
        let attachmentURLs: [String]
        let model: String?
        let effort: String?
        let permissions: String?
        let serviceTier: String?
        let isAutomaticRecovery: Bool?

        init(_ message: WaitingMessage) {
            id = message.id
            threadID = message.threadID
            text = message.text
            attachmentURLs = message.attachments.map { $0.url.absoluteString }
            model = message.model
            effort = message.effort
            permissions = message.permissions
            serviceTier = message.serviceTier
            isAutomaticRecovery = message.isAutomaticRecovery
        }

        var message: WaitingMessage {
            WaitingMessage(id: id, threadID: threadID, text: text,
                attachments: attachmentURLs.compactMap(URL.init(string:)).map(ComposerAttachment.init(url:)),
                model: model, effort: effort, permissions: permissions, serviceTier: serviceTier,
                isAutomaticRecovery: isAutomaticRecovery ?? false)
        }
    }

    struct InterruptedMessageEdit {
        let threadID: String
        let messageID: String
        let turnID: String
        let originalMessage: ChatMessage
        let attachments: [ComposerAttachment]
        let model: String?
        let effort: String?
        var historyWasReverted = false
        var isSubmitting = false
        var error: String?
    }
    @Published private(set) var interruptedMessageEdit: InterruptedMessageEdit?
    @Published var interruptedMessageEditText = ""
    @Published private(set) var interruptedMessageEditFocusRequest = UUID()

    var canSubmitInterruptedMessageEdit: Bool {
        guard let edit = interruptedMessageEdit, !edit.isSubmitting else { return false }
        return !interruptedMessageEditText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !edit.attachments.isEmpty
    }

    func canEditInterruptedMessage(_ message: ChatMessage) -> Bool {
        guard message.role == .user,
              let selectedThreadID,
              message.turnID != nil,
              threadOutcomes[selectedThreadID] == .interrupted,
              !isSelectedThreadProcessing,
              !isSending,
              threadInputAvailability == .available else { return false }
        return messages.last(where: { $0.role == .user })?.id == message.id
    }

    func isEditingInterruptedMessage(_ messageID: String) -> Bool {
        interruptedMessageEdit?.threadID == selectedThreadID
            && interruptedMessageEdit?.messageID == messageID
    }

    func beginEditingInterruptedMessage(_ message: ChatMessage) {
        guard interruptedMessageEdit == nil,
              canEditInterruptedMessage(message),
              let threadID = selectedThreadID,
              let turnID = message.turnID else { return }
        let attachments = message.attachments.compactMap { attachment -> ComposerAttachment? in
            guard !attachment.path.isEmpty else { return nil }
            return ComposerAttachment(url: URL(fileURLWithPath: attachment.path))
        }
        guard attachments.count == message.attachments.count else {
            errorMessage = "这条消息包含无法重新发送的附件，不能直接重新执行。"
            return
        }
        speech.stop()
        cancelWaitingMessageEdit()
        interruptedMessageEditText = message.text
        interruptedMessageEdit = InterruptedMessageEdit(
            threadID: threadID,
            messageID: message.id,
            turnID: turnID,
            originalMessage: message,
            attachments: attachments,
            model: message.model,
            effort: message.reasoningEffort
        )
        interruptedMessageEditFocusRequest = UUID()
    }

    func cancelInterruptedMessageEdit() {
        guard interruptedMessageEdit?.isSubmitting != true else { return }
        interruptedMessageEdit = nil
        interruptedMessageEditText = ""
    }

    func submitInterruptedMessageEdit() async {
        guard creditUsagePauseReason == nil, canSubmitInterruptedMessageEdit,
              var edit = interruptedMessageEdit,
              selectedThreadID == edit.threadID,
              !isSelectedThreadProcessing else { return }
        let text = interruptedMessageEditText.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackModel = selectedModel?.model
        let fallbackEffort = selectedEffort
        let outgoingPermissions = selectedPermissionID
        let outgoingServiceTier = selectedServiceTier
        edit.isSubmitting = true
        edit.error = nil
        interruptedMessageEdit = edit

        do {
            try await checkCreditUsageBeforeSubmission()
            if !edit.historyWasReverted {
                try await client.revertThread(edit.threadID, beforeTurnID: edit.turnID)
                edit.historyWasReverted = true
                interruptedMessageEdit = edit
                storeMessages(
                    conversationMessages(for: edit.threadID).filter { $0.turnID != edit.turnID },
                    for: edit.threadID
                )
            }
            let localMessageID = "local-\(UUID().uuidString)"
            // A failed retry keeps a client-side copy of the removed question
            // so the inline editor remains usable. Remove that placeholder
            // before every new start attempt.
            storeMessages(
                conversationMessages(for: edit.threadID).filter { $0.id != edit.originalMessage.id },
                for: edit.threadID
            )
            interruptedMessageEdit = nil
            interruptedMessageEditText = ""
            do {
                try await startTurnOptimistically(
                    threadID: edit.threadID,
                    localMessageID: localMessageID,
                    text: text,
                    outgoingAttachments: edit.attachments,
                    model: edit.model ?? fallbackModel,
                    effort: edit.effort ?? fallbackEffort,
                    permissions: outgoingPermissions,
                    serviceTier: outgoingServiceTier
                )
            } catch {
                rollbackOptimisticSend(
                    threadID: edit.threadID,
                    localMessageID: localMessageID,
                    text: text,
                    outgoingAttachments: edit.attachments,
                    restoreComposer: false
                )
                edit.isSubmitting = false
                edit.error = error.localizedDescription
                interruptedMessageEditText = text
                interruptedMessageEdit = edit
                var history = conversationMessages(for: edit.threadID)
                if !history.contains(where: { $0.id == edit.originalMessage.id }) {
                    history.append(edit.originalMessage)
                    storeMessages(history, for: edit.threadID)
                }
                if Self.isActiveWriterError(error) {
                    threadInputAvailability = .occupied
                    threadOwnershipNotice = Self.occupiedThreadMessage
                }
            }
        } catch {
            edit.isSubmitting = false
            edit.error = error.localizedDescription
            interruptedMessageEdit = edit
        }
    }

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

    private func persistWaitingMessagesIfReady() {
        guard waitingPersistenceReady else { return }
        if waitingMessages.isEmpty {
            remoteDefaults.removeObject(forKey: waitingMessagesKey)
        } else if let data = try? JSONEncoder().encode(waitingMessages.map(PersistedWaitingMessage.init)) {
            remoteDefaults.set(data, forKey: waitingMessagesKey)
        }
    }

    private func startWaitingMonitorIfNeeded() {
        guard waitingMonitor == nil, !waitingMessages.isEmpty else { return }
        waitingMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.waitingMessages.isEmpty else { break }
                for threadID in Set(self.waitingMessages.map(\.threadID)) {
                    guard self.creditUsagePauseReason == nil,
                          !self.locallyRunningThreadIDs.contains(threadID),
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

    var selectedWaitingMessages: [WaitingMessage] {
        waitingMessages.filter { $0.threadID == selectedThreadID }
    }

    func removeWaitingMessage(_ id: UUID) {
        guard !deliveringWaitingMessages.contains(id) else { return }
        if editingWaitingMessageID == id { cancelWaitingMessageEdit() }
        waitingMessages.removeAll { $0.id == id }
    }

    @discardableResult
    func moveWaitingMessage(_ sourceID: UUID, relativeTo targetID: UUID, placeAfter: Bool) -> Bool {
        guard sourceID != targetID,
              !deliveringWaitingMessages.contains(sourceID),
              !deliveringWaitingMessages.contains(targetID),
              let sourceIndex = waitingMessages.firstIndex(where: { $0.id == sourceID }),
              let originalTargetIndex = waitingMessages.firstIndex(where: { $0.id == targetID }),
              waitingMessages[sourceIndex].threadID == waitingMessages[originalTargetIndex].threadID else { return false }

        let message = waitingMessages.remove(at: sourceIndex)
        guard let targetIndex = waitingMessages.firstIndex(where: { $0.id == targetID }) else {
            waitingMessages.insert(message, at: min(sourceIndex, waitingMessages.endIndex))
            return false
        }
        let destination = min(waitingMessages.endIndex, targetIndex + (placeAfter ? 1 : 0))
        waitingMessages.insert(message, at: destination)
        return true
    }

    private func enqueueComposerMessage(threadID: String) {
        waitingMessages.append(WaitingMessage(threadID: threadID,
            text: composerText.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: attachments, model: selectedModel?.model, effort: selectedEffort,
            permissions: selectedPermissionID, serviceTier: selectedServiceTier))
        composerText = ""
        attachments = []
        speech.stop()
        startWaitingMonitorIfNeeded()
    }

    func deliverWaitingMessage(_ messageID: UUID, steer: Bool) async {
        guard creditUsagePauseReason == nil,
              messageID != editingWaitingMessageID,
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
                // Re-read the queue head after the asynchronous status check. The
                // exact snapshot shown in the queue must be the snapshot staged in
                // history and submitted to app-server.
                guard let current = waitingMessages.first(where: { $0.threadID == item.threadID }),
                      current.id == messageID else { return }
                let localMessageID = "local-waiting-\(current.id.uuidString)"
                do {
                    try await startTurnOptimistically(
                        threadID: current.threadID,
                        localMessageID: localMessageID,
                        text: current.text,
                        outgoingAttachments: current.attachments,
                        model: current.model,
                        effort: current.effort,
                        permissions: current.permissions,
                        serviceTier: current.serviceTier
                    )
                } catch {
                    rollbackOptimisticSend(
                        threadID: current.threadID,
                        localMessageID: localMessageID,
                        text: current.text,
                        outgoingAttachments: current.attachments,
                        restoreComposer: false
                    )
                    throw error
                }
            }
            waitingMessages.removeAll { $0.id == messageID }
            // Reload confirmed server messages, including attachment identities.
            if selectedThreadID == item.threadID { await loadSelectedThread() }
        } catch {
            if let index = waitingMessages.firstIndex(where: { $0.id == messageID }) {
                if waitingMessages[index].isAutomaticRecovery {
                    // Automatic recovery must survive a reconnect or a short
                    // active-writer race. The monitor will recheck idle state
                    // and retry instead of turning recovery into a dead queue.
                    waitingMessages[index].error = nil
                } else {
                    waitingMessages[index].error = error.localizedDescription
                }
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
    @Published var showingThreadNameEditor = false
    @Published private(set) var editingThreadNameID: String?
    @Published var threadNameDraft = ""
    @Published private(set) var isSavingThreadName = false
    @Published var threadNameEditorError: String?
    @Published var showingAppearanceSettings = false
    @Published var showingRemoteControl = false
    @Published private(set) var remoteControlEnabled: Bool
    @Published private(set) var remoteControlStatus = "远程控制已关闭"
    @Published private(set) var remotePairingCode = ""
    @Published private(set) var remotePairingExpiresAt: Date?
    @Published private(set) var remoteControlPaired = false
    @Published private(set) var isRemoteUnpairing = false
    @Published private(set) var remoteLastSyncAt: Date?
    @Published private(set) var remoteCredentialIssue: String?
    @Published private(set) var isLoadingRemoteCredential = false
    @Published private(set) var remoteServerConfiguration: RemoteServerConfiguration
    @Published private(set) var remoteServerConfigurationError: String?
    @Published private(set) var isSendingRemoteOfflineHeartbeat = false

    private let client: AppServerClient
    private var remoteControlAPI: RemoteControlAPI?
    private let remoteAPILoader: (@Sendable (Bool) async throws -> RemoteControlAPI)?
    private let remoteDefaults: UserDefaults
    private let speech = SpeechInputController()
    private var hasStarted = false
    private var threadRequestGeneration = 0
    private var serviceTierUpdateGenerationByThread: [String: Int] = [:]
    private var fastModePreferenceGeneration = 0
    private var selectedThreadMonitorTask: Task<Void, Never>?
    private var selectedThreadMetadataTask: Task<Void, Never>?
    private var threadStatusMonitorTask: Task<Void, Never>?
    private var clientReconnectTask: Task<Void, Never>?
    private var turnProgressHintTask: Task<Void, Never>?
    private var pendingDeltaFlushTask: Task<Void, Never>?
    private var pendingActivityDeltas: [PendingItemKey: PendingActivityDelta] = [:]
    private var pendingAssistantDeltas: [PendingItemKey: [String]] = [:]
    private var pendingDeltaOrder: [PendingDeltaTarget] = []
    private var forceStoppingThreadID: String?
    private var activePermissionByThreadID: [String: String] = [:]
    private var turnLaunchSettingsByThreadID: [String: TurnLaunchSettings] = [:]
    private var capacityRetryStates: [String: CapacityRetryState] = [:]
    private var capacityRetryTasks: [String: Task<Void, Never>] = [:]
    private var messagesByThread: [String: [ChatMessage]] = [:]
    var selectedCollaborationTasks: [CollaborationChildTask] {
        ConversationTimeline.latestChildTasks(from: messages)
    }
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
        if selectedThreadID == threadID {
            if messages != value { messages = value }
        }
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
    private var localTurnStartedAtByThread: [String: Date] = [:]
    static let localTurnReconciliationGrace: TimeInterval = 30
    private var liveTurnMetadataByThread: [String: TurnModelMetadata] = [:]

    private struct TurnLaunchSettings: Codable {
        var model: String?
        var effort: String?
        var permissions: String?
        var serviceTier: String?
        var approvalPolicy: String?
        var approvalsReviewer: String?
    }

    private struct CapacityRetryState: Codable {
        var attempt: Int
        var failedTurnID: String
        var settings: TurnLaunchSettings
    }
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
    private let remoteNotificationOutbox: RemoteNotificationOutbox
    private var remoteNotificationUploadTask: Task<Void, Never>?
    private var remoteUsageSnapshot: RemoteUsageSnapshot?
    private var remoteUsageLastAttempt: Date?
    private var remoteExecutions: [String: RemoteExecution] = [:]
    /// Different Codex conversations may execute independently. Same-thread
    /// serialization remains enforced by the relay and by executeRemoteTask's
    /// active-writer check.
    private let maxConcurrentRemoteExecutions = 4
    /// A crashed Sky bridge can restart quickly, but immediately binding the
    /// same AX application again produces a crash loop. Remember the concrete
    /// tool failure per thread and briefly stop claiming mini-program work.
    private var computerControlNativeFailures: [String: String] = [:]
    private var computerControlCircuitOpenUntil: Date?
    /// Track release ownership per thread. A release must not be duplicated,
    /// but it must not block unrelated conversations from being claimed.
    private var remoteReleasingThreadIDs: Set<String> = []
    private var speechTargetsNewThread = false
    private let workspaceOrganizationKey = "CloudCodex.workspaceOrganization.v1"
    private let fastModeKey = "CloudCodex.fastModeEnabled.v1"
    private let remoteControlEnabledKey = "CloudCodex.remoteControl.enabled.v1"
    private let remotePairingCodeKey = "CloudCodex.remoteControl.pairingCode.v1"
    private let waitingMessagesKey = "CloudCodex.waitingMessages.v1"
    private let capacityRetriesKey = "CloudCodex.capacityRetries.v1"
    static let commandInactivityTimeoutMinutesKey = "CloudCodex.commandInactivityTimeoutMinutes.v1"

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
        computerControlTimeoutSeconds: TimeInterval = 120,
        commandInactivityTimeoutSeconds: TimeInterval? = nil,
        creditUsageReader: (() async throws -> AccountOverview)? = nil,
        creditTurnInterrupter: ((String, String) async throws -> Void)? = nil,
        remoteAPILoader: (@Sendable (Bool) async throws -> RemoteControlAPI)? = nil,
        client injectedClient: AppServerClient? = nil,
        accounts injectedAccounts: CodexAccountStore? = nil
    ) {
        let accounts = injectedAccounts ?? CodexAccountStore(defaults: remoteDefaults)
        self.accounts = accounts
        self.localCodexHome = injectedClient?.codexHomeOverride
        let home = accounts.home(for: accounts.active)
        self.client = injectedClient ?? AppServerClient(codexHomeOverride: home, usesManagedAccount: !accounts.active.isLocal)
        self.client.sharedConversationHome = CodexUsageTierStore.home(self.localCodexHome)
        let quotaClient = self.client
        self.weeklyQuotaProbe = WeeklyQuotaProbe {
            AppServerClient(codexHomeOverride: quotaClient.codexHomeOverride, usesManagedAccount: quotaClient.usesManagedAccount)
        }
        self.localQuotaTokenReader = CodexLocalTokenUsageReader(home: self.client.sharedConversationHome)
        let library = ModelProviderLibrary.load(from: remoteDefaults)
        self.providerLibrary = library
        self.customModelProvider = library.activeConfiguration
        self.client.customModelProvider = library.activeConfiguration
        self.client.customModelOptions = library.profiles.first {
            $0.id == library.defaultProviderID
        }?.options ?? []
        self.remoteDefaults = remoteDefaults
        let accountRefreshInterval = AccountRefreshInterval.load(from: remoteDefaults)
        self.accountRefreshInterval = accountRefreshInterval
        self.connectionHealth = ConnectionHealth(refreshInterval: accountRefreshInterval)
        self.remoteServerConfiguration = RemoteServerConfiguration.load(remoteDefaults)
        self.providerUsage = ProviderUsageLedger.load(remoteDefaults)
        self.weeklyQuotaComparison = WeeklyQuotaComparison.load(remoteDefaults)
        self.automaticWeeklyQuotaSampler = AutomaticWeeklyQuotaSampler.load(remoteDefaults)
        self.automaticWeeklyQuotaEnabled = remoteDefaults.object(forKey: AutomaticWeeklyQuotaSampler.enabledKey) == nil
            || remoteDefaults.bool(forKey: AutomaticWeeklyQuotaSampler.enabledKey)
        self.creditUsageReader = creditUsageReader
        self.creditTurnInterrupter = creditTurnInterrupter
        self.userInputTimeoutSeconds = userInputTimeoutSeconds
        self.computerControlTimeoutSeconds = computerControlTimeoutSeconds
        self.commandInactivityTimeoutOverride = commandInactivityTimeoutSeconds
        let savedCommandTimeout = remoteDefaults.integer(forKey: Self.commandInactivityTimeoutMinutesKey)
        self.commandInactivityTimeoutMinutes = Self.clampedCommandInactivityTimeoutMinutes(
            savedCommandTimeout == 0 ? 5 : savedCommandTimeout
        )
        self.remoteStatusOutbox = RemoteStatusOutbox(defaults: remoteDefaults)
        self.remoteNotificationOutbox = RemoteNotificationOutbox(defaults: remoteDefaults)
        self.remoteAPILoader = remoteAPILoader
        if let data = remoteDefaults.data(forKey: unreadCompletionsKey),
           let saved = try? JSONDecoder().decode(UnreadCompletions.self, from: data) {
            unreadCompletions = saved
        }
        if let data = remoteDefaults.data(forKey: favoriteConversationsKey),
           let saved = try? JSONDecoder().decode(FavoriteConversations.self, from: data) {
            favoriteConversations = saved
        }
        if let data = remoteDefaults.data(forKey: quotaConsumptionHistoryKey),
           let saved = try? JSONDecoder().decode(QuotaConsumptionTracker.self, from: data) {
            quotaConsumptionTracker = saved
            recentThirtyMinuteConsumptionRate = saved.consumptionRate(at: Date().timeIntervalSince1970)
        }
        revertedFileChanges = Set(remoteDefaults.stringArray(forKey: revertedFileChangesKey) ?? [])
        isFastModeEnabled = remoteDefaults.bool(forKey: fastModeKey)
        remoteControlEnabled = remoteDefaults.bool(forKey: remoteControlEnabledKey)
        allowsExtraCreditUsage = remoteDefaults.bool(forKey: Self.allowsExtraCreditUsageKey)
        if !customModelProvider.enabled, !allowsExtraCreditUsage,
           let saved = remoteDefaults.string(forKey: Self.creditUsagePauseKey),
           let reason = CreditUsageProtection.Reason(rawValue: saved), reason != .usageUnavailable {
            creditUsageProtection.reason = reason
            creditUsagePauseReason = reason
        } else if !customModelProvider.enabled, remoteDefaults.string(forKey: Self.creditUsagePauseKey) == CreditUsageProtection.Reason.usageUnavailable.rawValue {
            remoteDefaults.removeObject(forKey: Self.creditUsagePauseKey)
        }
        remotePairingCode = remoteDefaults.string(forKey: remotePairingCodeKey) ?? ""
        if let data = UserDefaults.standard.data(forKey: workspaceOrganizationKey),
           let saved = try? JSONDecoder().decode(WorkspaceOrganization.self, from: data) {
            workspaceOrganization = saved
        }
        if let data = remoteDefaults.data(forKey: waitingMessagesKey),
           let saved = try? JSONDecoder().decode([PersistedWaitingMessage].self, from: data) {
            waitingMessages = saved.map(\.message)
            for index in waitingMessages.indices where waitingMessages[index].error == CreditUsageProtection.Reason.usageUnavailable.message {
                waitingMessages[index].error = nil
            }
        }
        if let data = remoteDefaults.data(forKey: capacityRetriesKey),
           let saved = try? JSONDecoder().decode([String: CapacityRetryState].self, from: data) {
            capacityRetryStates = saved
            for (threadID, state) in saved {
                turnLaunchSettingsByThreadID[threadID] = state.settings
            }
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
        client.beforeTurnSubmission = { [weak self] in
            guard let self else { throw CodexClientError.notRunning }
            guard !self.isSwitchingModelProvider else {
                throw ModelProviderError.message("正在切换模型厂商，请稍后发送。")
            }
            if self.customModelProvider.enabled { return }
            try await self.checkCreditUsageBeforeSubmission()
        }
        waitingPersistenceReady = true
        startWaitingMonitorIfNeeded()
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

    func chooseWorkspaceFolder() {
        let panel = NSOpenPanel()
        panel.title = "新增 CloudCodex 工作区"
        panel.prompt = "新增工作区"
        panel.message = "选择一个文件夹。CloudCodex 会将它保留在工作区列表中，不会移动或修改其中的文件。"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addWorkspace(at: url)
    }

    @discardableResult
    func addWorkspace(at url: URL) -> Bool {
        let standardizedURL = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard standardizedURL.isFileURL,
              FileManager.default.fileExists(atPath: standardizedURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            errorMessage = "所选工作区不存在或不是文件夹。"
            return false
        }

        let path = standardizedURL.path
        let wasAdded = workspaceOrganization.addFolder(path: path)
        saveWorkspaceOrganization()
        if let index = folderCatalog.firstIndex(where: { $0.path == path }) {
            let folder = folderCatalog.remove(at: index)
            folderCatalog.insert(folder, at: 0)
        } else {
            folderCatalog.insert(
                WorkspaceFolder(path: path, threadCount: 0, latestUpdate: Date()),
                at: 0
            )
        }
        selectFolder(path)
        return wasAdded
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

    func beginRenamingThread(_ thread: CodexThread) {
        editingThreadNameID = thread.id
        threadNameDraft = thread.displayName
        threadNameEditorError = nil
        isSavingThreadName = false
        showingThreadNameEditor = true
    }

    func cancelThreadNameEditor() {
        guard !isSavingThreadName else { return }
        showingThreadNameEditor = false
        editingThreadNameID = nil
        threadNameDraft = ""
        threadNameEditorError = nil
    }

    func saveThreadName() async {
        guard !isSavingThreadName, let threadID = editingThreadNameID else { return }
        let name = threadNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            threadNameEditorError = "会话名称不能为空。"
            return
        }
        isSavingThreadName = true
        threadNameEditorError = nil
        do {
            try await client.setThreadName(threadID: threadID, name: name)
            applyThreadName(name, threadID: threadID)
            isSavingThreadName = false
            showingThreadNameEditor = false
            editingThreadNameID = nil
            threadNameDraft = ""
        } catch {
            isSavingThreadName = false
            threadNameEditorError = error.localizedDescription
        }
    }

    private var commandInactivityTimeoutSeconds: TimeInterval {
        commandInactivityTimeoutOverride ?? TimeInterval(commandInactivityTimeoutMinutes * 60)
    }

    static func clampedCommandInactivityTimeoutMinutes(_ minutes: Int) -> Int {
        min(max(minutes, 1), 60)
    }

    func setCommandInactivityTimeoutMinutes(_ minutes: Int) {
        let clamped = Self.clampedCommandInactivityTimeoutMinutes(minutes)
        guard clamped != commandInactivityTimeoutMinutes else { return }
        commandInactivityTimeoutMinutes = clamped
        remoteDefaults.set(clamped, forKey: Self.commandInactivityTimeoutMinutesKey)

        // Apply the new preference to commands that are already running. The
        // timer restarts from this explicit user change, just like fresh output.
        let activeKeys = Array(commandInactivityTimeoutTasks.keys)
        for key in activeKeys {
            refreshCommandInactivityTimeout(
                itemID: key.itemID,
                threadID: key.threadID,
                turnID: activeTurnIDsByThread[key.threadID]
            )
        }
    }

    private func applyThreadName(_ name: String?, threadID: String) {
        if var thread = threadSummaries[threadID] {
            thread.name = name
            threadSummaries[threadID] = thread
            updateFavoriteSnapshot(thread)
        }
        if let index = threads.firstIndex(where: { $0.id == threadID }) {
            threads[index].name = name
            updateFavoriteSnapshot(threads[index])
        }
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

    /// Resolve badges by ID across workspaces, including conversations outside
    /// the recent 60-row page. Reading metadata never acknowledges a completion.
    func refreshUnreadThreads(
        readThread: ((String) async throws -> CodexThread)? = nil,
        findThreads: ((Set<String>) async throws -> [CodexThread])? = nil
    ) async {
        guard !isLoadingUnreadThreads else { return }
        isLoadingUnreadThreads = true
        unreadThreadsError = nil
        defer { isLoadingUnreadThreads = false }
        var attempted: Set<String> = []
        var unloaded: Set<String> = []
        var attemptedTurns: [String: String] = [:]
        while let id = unreadCompletions.unread.sorted().first(where: {
            !attempted.contains($0) && unreadThreadSummary($0) == nil
        }) {
            guard !Task.isCancelled else { return }
            attempted.insert(id)
            attemptedTurns[id] = unreadCompletions.latestTurns[id]
            do {
                if let readThread {
                    threadSummaries[id] = try await readThread(id)
                } else {
                    threadSummaries[id] = try await client.readThreadState(id)
                }
            } catch {
                if case CodexClientError.server(let message) = error,
                   message == "thread not loaded: \(id)" {
                    unloaded.insert(id)
                } else if unreadCompletions.unread.contains(id) {
                    unreadThreadsError = "部分红点会话暂时无法加载，请重试"
                }
            }
        }
        guard !unloaded.isEmpty, !Task.isCancelled else { return }
        do {
            let resolved: [CodexThread]
            if let findThreads {
                resolved = try await findThreads(unloaded)
            } else {
                resolved = try await client.findUnreadThreads(unloaded)
            }
            try Task.checkCancellation()
            for thread in resolved { threadSummaries[thread.id] = thread }
            for id in unloaded.subtracting(Set(resolved.map(\.id))) {
                // Another refresh may have obtained metadata while listing.
                if unreadThreadSummary(id) == nil,
                   unreadCompletions.latestTurns[id] == attemptedTurns[id] {
                    markConversationRead(id)
                }
            }
        } catch {
            unreadThreadsError = "部分红点会话暂时无法加载，请重试"
        }
    }

    private func unreadThreadSummary(_ id: String) -> CodexThread? {
        threads.first { $0.id == id } ?? threadSummaries[id] ?? favoriteConversations.thread(id)
    }

    var visibleUnreadThreads: [CodexThread] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return unreadCompletions.unread.compactMap { unreadThreadSummary($0) }
            .filter {
                query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query)
                    || $0.visiblePreview.localizedCaseInsensitiveContains(query)
            }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id < $1.id
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
        if selectedModelID == Self.recommendedModelSelectionID {
            guard !customModelProvider.enabled, let configured = providerLibrary.openAIDefaultModelID else { return nil }
            return modelOptions.first { $0.model == configured && providerID(for: $0.id) == ModelProviderLibrary.openAI }
        }
        return modelOptions.first { $0.id == selectedModelID }
    }

    var recommendedModel: CodexModelOption? {
        let options = modelOptions.filter { providerID(for: $0.id) == currentModelProviderID }
        if currentModelProviderID == ModelProviderLibrary.openAI,
           let preferred = options.first(where: { $0.model == providerLibrary.openAIDefaultModelID }) { return preferred }
        return options.first(where: \.isDefault) ?? options.first
    }

    var selectedModelCapabilities: CodexModelOption? {
        selectedModelID == Self.recommendedModelSelectionID ? recommendedModel : selectedModel
    }

    var selectedModelDisplayName: String {
        selectedModelID == Self.recommendedModelSelectionID ? "默认" : (selectedModel?.compactName ?? "选择模型")
    }

    var selectedPermission: PermissionProfileOption? {
        permissionProfiles.first { $0.id == selectedPermissionID }
    }

    var availableEfforts: [String] {
        selectedModelCapabilities?.composerEfforts ?? []
    }

    var supportsFastMode: Bool {
        selectedModelCapabilities?.fastServiceTierID != nil
    }

    var selectedSpeedLabel: String {
        isFastModeEnabled && supportsFastMode ? "加速" : "标准"
    }

    var selectedServiceTier: String {
        if isFastModeEnabled, let tier = selectedModelCapabilities?.fastServiceTierID {
            return tier
        }
        return "default"
    }

    private func applyThreadServiceTier(_ serviceTier: String?, threadID: String) {
        // This is the thread's persisted setting, not the global preference
        // for subsequent requests. Reads, resumes, and settings notifications
        // must not turn off the user's acceleration selection.
        if var thread = threadSummaries[threadID] {
            thread.serviceTier = serviceTier
            threadSummaries[threadID] = thread
            updateFavoriteSnapshot(thread)
        }
        if let index = threads.firstIndex(where: { $0.id == threadID }) {
            threads[index].serviceTier = serviceTier
        }
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
            && !isSwitchingModelProvider
            && threadInputAvailability == .available
            && (customModelProvider.enabled || creditUsagePauseReason == nil)
    }

    var isSelectedThreadOwnedElsewhere: Bool {
        selectedThreadID != nil && threadInputAvailability == .occupied
    }

    var canCreateThread: Bool {
        !newThreadFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!newThreadPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !newThreadAttachments.isEmpty)
            && !isCreatingThread
            && !isSwitchingModelProvider
            && (customModelProvider.enabled || creditUsagePauseReason == nil)
    }

    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        MainThreadWatchdog.shared.start()
        systemMetrics.start()
        connectionHealth.start { [weak self] in
            guard let self else { throw CodexClientError.notRunning }
            guard !self.isSwitchingModelProvider else { throw CodexClientError.notRunning }
            let generation = self.accountGeneration
            do {
                let overview = try await self.client.readAccountOverview()
                guard generation == self.accountGeneration, !self.isSwitchingModelProvider else { throw CodexClientError.notRunning }
                self.applyAccountOverview(overview)
                self.accountOverviewError = nil
            } catch {
                if generation == self.accountGeneration, !self.isSwitchingModelProvider {
                    self.accountOverviewError = error.localizedDescription
                }
                throw error
            }
        }
        client.onEvent = { [weak self] method, params in self?.handleEvent(method, params) }
        client.onServerRequest = { [weak self] requestID, method, params in
            self?.handleServerRequest(requestID, method: method, params: params)
        }
        client.onDisconnect = { [weak self] message in
            guard let self else { return }
            guard !self.isSwitchingModelProvider else { return }
            if let threadID = self.forceStoppingThreadID {
                self.forceStoppingThreadID = nil
                self.handleForcedStopDisconnect(threadID: threadID)
            } else {
                self.handleClientDisconnect(message)
            }
            self.scheduleClientReconnect()
        }
        do {
            try accounts.prepareHome(for: accounts.active)
            try prepareSharedConversations()
            mergeLegacyConversationPreferences()
            try await client.start()
            connectionText = customModelProvider.enabled ? "已连接：\(customModelProvider.name)" : "已连接本机 Codex"
            startWeeklyQuotaSampling()
            Task { await connectionHealth.check() }
            await loadComposerOptions(cwd: nil)
            await loadFolderCatalog()
            await refreshThreads()
            resumePersistedCapacityRetries()
            startThreadStatusMonitor()
            startCreditUsageMonitor()
            startRemoteControlIfNeeded()
        } catch {
            connectionText = "连接失败"
            errorMessage = error.localizedDescription
        }
    }

    func setAccountRefreshInterval(_ interval: AccountRefreshInterval) {
        guard accountRefreshInterval != interval else { return }
        accountRefreshInterval = interval
        remoteDefaults.set(interval.rawValue, forKey: AccountRefreshInterval.storageKey)
        connectionHealth.setRefreshInterval(interval)
    }

    private func applyAccountOverview(_ overview: AccountOverview) {
        guard !customModelProvider.enabled else { return }
        let restored = quotaRestorationTracker.record(overview)
        accountOverview = overview
        accounts.setOverview(overview, for: accounts.library.activeID)
        if restored {
            enqueueRemoteNotification(.init(
                type: RemoteNotificationEventBody.quotaRestored,
                eventId: "quota:\(Int(overview.usage.capturedAt))"
            ))
        }
        observeCreditUsage(overview)
        recentThirtyMinuteConsumptionRate = quotaConsumptionTracker.record(account: overview)
        if let data = try? JSONEncoder().encode(quotaConsumptionTracker) {
            remoteDefaults.set(data, forKey: quotaConsumptionHistoryKey)
        }
    }

    private func enqueueRemoteNotification(_ body: RemoteNotificationEventBody) {
        // Notification delivery belongs to the relay that owns the current
        // pairing. The production AI mini program is commonly configured as a
        // custom relay, so filtering by the local server-mode label would drop
        // the event before it ever reached the paired backend.
        guard remoteControlEnabled, remoteControlPaired, let api = remoteControlAPI else { return }
        remoteNotificationOutbox.enqueue(deviceID: api.deviceID, body: body)
    }

    func setAllowsExtraCreditUsage(_ allowed: Bool) {
        guard !customModelProvider.enabled else { return }
        guard allowed != allowsExtraCreditUsage else { return }
        allowsExtraCreditUsage = allowed
        remoteDefaults.set(allowed, forKey: Self.allowsExtraCreditUsageKey)
        creditUsageProtection.reset()
        if let accountOverview { observeCreditUsage(accountOverview) }
        publishCreditUsageProtection()
        if !allowed { requestCreditUsageRefresh() }
    }

    func observeCreditUsage(_ overview: AccountOverview) {
        guard !customModelProvider.enabled else { return }
        creditUsageProtection.observe(overview, allowsCredits: allowsExtraCreditUsage)
        publishCreditUsageProtection()
    }

    private func publishCreditUsageProtection() {
        creditUsagePauseReason = creditUsageProtection.reason
        if let reason = creditUsagePauseReason {
            remoteDefaults.set(reason.rawValue, forKey: Self.creditUsagePauseKey)
            pauseConversationsForCreditProtection()
        } else {
            remoteDefaults.removeObject(forKey: Self.creditUsagePauseKey)
            creditUsagePauseFailures = [:]
        }
    }

    private func readCreditUsage() async throws -> AccountOverview {
        if let creditUsageReader { return try await creditUsageReader() }
        return try await client.readAccountOverview()
    }

    func checkCreditUsageBeforeSubmission() async throws {
        guard !customModelProvider.enabled else { return }
        guard !allowsExtraCreditUsage else { return }
        if let reason = creditUsagePauseReason { throw CreditUsageBlocked(reason: reason) }
        do {
            let overview = try await readCreditUsage()
            applyAccountOverview(overview)
        } catch {
            accountOverviewError = error.localizedDescription
        }
        if let reason = creditUsagePauseReason { throw CreditUsageBlocked(reason: reason) }
    }

    func recheckIncludedQuota() async {
        guard !isRecheckingIncludedQuota else { return }
        includedQuotaCheckMessage = nil
        guard creditInterruptingThreadIDs.isEmpty, creditUsagePauseFailures.isEmpty else {
            includedQuotaCheckMessage = "还有会话正在暂停或暂停失败，请等待暂停成功后再解除额度保护。"
            return
        }
        isRecheckingIncludedQuota = true
        defer { isRecheckingIncludedQuota = false }
        do {
            let overview = try await readCreditUsage()
            guard !allowsExtraCreditUsage else { return }
            accountOverviewError = nil
            if CreditUsageProtection.hasKnownIncludedQuota(overview) {
                creditUsageProtection.reset()
            }
            applyAccountOverview(overview)
            if creditUsagePauseReason != nil {
                if overview.usage.buckets.contains(where: { bucket in
                    bucket.windows.contains { ($0.usedPercent ?? 0) >= 100 }
                }) {
                    includedQuotaCheckMessage = "检查完成：仍有套餐周期额度已用完，保护尚未解除。请等待额度恢复，或在个性设置中开启额外额度使用。"
                } else {
                    includedQuotaCheckMessage = "检查完成：暂时无法确认套餐额度已恢复，保护尚未解除，请稍后重试。"
                }
            }
        } catch {
            accountOverviewError = error.localizedDescription
            includedQuotaCheckMessage = "额度检查失败：\(error.localizedDescription)。请检查连接后重试。"
        }
    }

    private func requestCreditUsageRefresh() {
        guard !isSwitchingModelProvider, !customModelProvider.enabled, !allowsExtraCreditUsage, creditUsageRefreshTask == nil else { return }
        creditUsageRefreshTask = Task { [weak self] in
            guard let self else { return }
            defer { self.creditUsageRefreshTask = nil }
            do {
                let overview = try await self.readCreditUsage()
                self.applyAccountOverview(overview)
            } catch {
                self.accountOverviewError = error.localizedDescription
            }
        }
    }

    private func startCreditUsageMonitor() {
        guard !customModelProvider.enabled, creditUsageMonitorTask == nil else { return }
        creditUsageMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.allowsExtraCreditUsage,
                   !self.locallyRunningThreadIDs.isEmpty || self.threads.contains(where: { $0.status == "active" })
                        || self.creditUsagePauseReason != nil {
                    self.requestCreditUsageRefresh()
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    private func pauseConversationsForCreditProtection() {
        guard let reason = creditUsagePauseReason, !allowsExtraCreditUsage else { return }
        for threadID in Array(capacityRetryStates.keys) {
            _ = cancelCapacityRetry(threadID: threadID)
        }
        let running = locallyRunningThreadIDs.union(activeTurnIDsByThread.keys)
            .union(threads.filter { $0.status == "active" }.map(\.id))
            .union(threadSummaries.values.filter { $0.status == "active" }.map(\.id))
        for threadID in running where !creditInterruptingThreadIDs.contains(threadID) {
            creditInterruptingThreadIDs.insert(threadID)
            Task { [weak self] in
                guard let self else { return }
                defer { self.creditInterruptingThreadIDs.remove(threadID) }
                do {
                    guard !self.allowsExtraCreditUsage, self.creditUsagePauseReason != nil else { return }
                    var turnID = self.activeTurnIDsByThread[threadID]
                    if turnID == nil {
                        let activity = try await self.client.readLatestThreadActivity(threadID)
                        if let turn = activity.turn, turn.isActive { turnID = turn.id }
                    }
                    if let turnID {
                        guard !self.allowsExtraCreditUsage, self.creditUsagePauseReason != nil else { return }
                        if let interrupt = self.creditTurnInterrupter {
                            try await interrupt(threadID, turnID)
                        } else {
                            try await self.client.interruptTurn(threadID: threadID, turnID: turnID)
                        }
                    }
                    // Do not erase a newer turn that arrived during interruption.
                    guard self.activeTurnIDsByThread[threadID] == nil
                        || self.activeTurnIDsByThread[threadID] == turnID else { return }
                    self.markLocalTurnInterrupted(threadID: threadID, message: reason.message,
                        title: "额外额度保护", status: "已暂停")
                    self.clearLocalTurn(threadID)
                    self.setThreadRunning(threadID, running: false)
                    self.threadOutcomes[threadID] = .interrupted
                    self.creditUsagePauseFailures.removeValue(forKey: threadID)
                } catch {
                    self.creditUsagePauseFailures[threadID] = "暂停未成功：\(error.localizedDescription)"
                }
            }
        }
    }

    func consumeResetCredit(_ credit: RemoteUsageSnapshot.ResetCredit) async {
        guard resetCreditInProgressRef == nil, !isSwitchingModelProvider else { return }
        if let reason = ResetCreditUsePresentation.unavailableReason(for: credit) {
            resetCreditStatusMessage = reason
            resetCreditStatusIsError = true
            return
        }

        resetCreditInProgressRef = credit.ref
        resetCreditStatusMessage = nil
        defer { resetCreditInProgressRef = nil }

        do {
            let outcome = try await client.consumeRemoteReset(.init(
                id: UUID().uuidString,
                creditRef: credit.ref
            ))
            let presentation = ResetCreditUsePresentation.outcome(outcome)
            resetCreditStatusMessage = presentation.message
            resetCreditStatusIsError = presentation.isError

            do {
                applyAccountOverview(try await client.readAccountOverview())
                accountOverviewError = nil
            } catch {
                accountOverviewError = error.localizedDescription
                resetCreditStatusMessage = presentation.message + " 最新额度暂时未能读取，请稍后刷新。"
            }
        } catch {
            let issue = AccountOverviewRefreshIssue.parse(error.localizedDescription)
            resetCreditStatusMessage = "使用失败：\(issue.message)"
            resetCreditStatusIsError = true
        }
    }

    func refreshUsageInsights() async {
        guard !isSwitchingModelProvider else { return }
        guard !customModelProvider.enabled else { return }
        guard !isLoadingUsageInsights else { return }
        isLoadingUsageInsights = true
        defer { isLoadingUsageInsights = false }
        do {
            usageInsights = try await client.readUsageInsights()
            usageInsightsError = nil
        } catch {
            usageInsightsError = AccountOverviewRefreshIssue.parse(error.localizedDescription).message
        }
    }

    func loadWeeklyQuotaComparison() {
        weeklyQuotaComparison = .load(remoteDefaults)
    }

    func setAutomaticWeeklyQuotaEnabled(_ enabled: Bool) {
        guard automaticWeeklyQuotaEnabled != enabled else { return }
        automaticWeeklyQuotaEnabled = enabled
        remoteDefaults.set(enabled, forKey: AutomaticWeeklyQuotaSampler.enabledKey)
        stopWeeklyQuotaSampling()
        if enabled { startWeeklyQuotaSampling() }
    }

    private func startWeeklyQuotaSampling() {
        guard hasStarted, automaticWeeklyQuotaEnabled, !customModelProvider.enabled,
              weeklyQuotaSamplingTask == nil else { return }
        weeklyQuotaSamplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.sampleWeeklyQuotaAutomatically()
                do { try await Task.sleep(for: .seconds(AutomaticWeeklyQuotaSampler.interval)) }
                catch { return }
            }
        }
    }

    private func stopWeeklyQuotaSampling() {
        weeklyQuotaSamplingTask?.cancel()
        weeklyQuotaSamplingTask = nil
        weeklyQuotaSamplingGeneration += 1
        weeklyQuotaProbe.cancel()
        isSamplingWeeklyQuota = false
        automaticWeeklyQuotaSampler.reset()
        persistAutomaticWeeklyQuotaSampler()
    }

    private func persistAutomaticWeeklyQuotaSampler() {
        if let data = try? JSONEncoder().encode(automaticWeeklyQuotaSampler) {
            remoteDefaults.set(data, forKey: AutomaticWeeklyQuotaSampler.defaultsKey)
        }
    }

    func sampleWeeklyQuotaAutomatically() async {
        guard hasStarted, automaticWeeklyQuotaEnabled, !customModelProvider.enabled,
              !isSwitchingModelProvider, !isSamplingWeeklyQuota else { return }
        let generation = weeklyQuotaSamplingGeneration
        isSamplingWeeklyQuota = true
        defer { if generation == weeklyQuotaSamplingGeneration { isSamplingWeeklyQuota = false } }
        do {
            let snapshot = try await weeklyQuotaProbe.read(localTokenMode: true,
                knownLifetimeTokens: automaticWeeklyQuotaSampler.latest?.lifetimeTokens ?? 0)
            guard generation == weeklyQuotaSamplingGeneration, !Task.isCancelled,
                  !customModelProvider.enabled else { return }
            let localUsage = if let baseline = automaticWeeklyQuotaSampler.baseline {
                try? await localQuotaTokenReader.read(since: baseline.date, through: snapshot.date)
            } else { nil as CodexLocalTokenUsageReader.Summary? }
            guard generation == weeklyQuotaSamplingGeneration, !Task.isCancelled else { return }
            if let sample = automaticWeeklyQuotaSampler.record(snapshot, localTokens: localUsage?.tokens, costReport: localUsage?.cost) {
                var updated = weeklyQuotaComparison
                if let index = updated.samples.firstIndex(where: { $0.id == sample.id }) {
                    updated.samples[index] = sample
                } else { updated.samples.append(sample) }
                // Bound unattended history while preserving manual measurements.
                let automaticIDs = Set(updated.samples.filter { $0.automatic == true }.suffix(200).map(\.id))
                updated.samples.removeAll { $0.automatic == true && !automaticIDs.contains($0.id) }
                remoteDefaults.set(try JSONEncoder().encode(updated), forKey: WeeklyQuotaComparison.defaultsKey)
                weeklyQuotaComparison = updated
            }
            persistAutomaticWeeklyQuotaSampler()
        } catch {
            guard generation == weeklyQuotaSamplingGeneration, !Task.isCancelled else { return }
            automaticWeeklyQuotaSampler.readingFailed(WeeklyQuotaComparison.ReadIssue.classify(error))
            persistAutomaticWeeklyQuotaSampler()
        }
    }

    func readWeeklyQuotaMeasurement(start: Bool) async throws -> WeeklyQuotaComparison.Sample? {
        guard !customModelProvider.enabled else {
            weeklyQuotaBaseline = nil
            throw WeeklyQuotaComparison.MeasurementError("自动采样仅适用于 ChatGPT 套餐；其他套餐请手动录入。")
        }
        let generation = accountGeneration
        let snapshot = try await client.readWeeklyQuotaSnapshot()
        guard generation == accountGeneration, !isSwitchingModelProvider else { throw CancellationError() }
        if start {
            weeklyQuotaBaseline = snapshot
            return nil
        }
        guard let baseline = weeklyQuotaBaseline else {
            throw WeeklyQuotaComparison.MeasurementError("请先读取起点。")
        }
        let sample = try baseline.sample(to: snapshot)
        weeklyQuotaBaseline = nil
        return sample
    }

    func cancelWeeklyQuotaMeasurement() { weeklyQuotaBaseline = nil }

    func saveWeeklyQuotaSample(_ sample: WeeklyQuotaComparison.Sample) throws {
        var updated = weeklyQuotaComparison
        updated.samples.append(sample)
        let data = try JSONEncoder().encode(updated)
        remoteDefaults.set(data, forKey: WeeklyQuotaComparison.defaultsKey)
        weeklyQuotaComparison = updated
    }

    func removeWeeklyQuotaSample(_ id: UUID) throws {
        var updated = weeklyQuotaComparison
        updated.samples.removeAll { $0.id == id }
        let data = try JSONEncoder().encode(updated)
        remoteDefaults.set(data, forKey: WeeklyQuotaComparison.defaultsKey)
        weeklyQuotaComparison = updated
        if automaticWeeklyQuotaSampler.sampleID == id {
            automaticWeeklyQuotaSampler.invalidate()
            persistAutomaticWeeklyQuotaSampler()
        }
    }

    func refreshPersonalSkills(forceReload: Bool = true) async {
        guard !isSwitchingModelProvider, !isLoadingPersonalSkills else { return }
        isLoadingPersonalSkills = true
        defer { isLoadingPersonalSkills = false }
        do {
            personalSkills = try await client.listPersonalSkills(forceReload: forceReload)
            personalSkillsError = nil
        } catch {
            personalSkillsError = AccountOverviewRefreshIssue.parse(error.localizedDescription).message
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
            if creditUsagePauseReason != nil { pauseConversationsForCreditProtection() }
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
        let generation = accountGeneration
        let requestedFolder = selectedFolder
        do {
            let page = try await client.listThreads(limit: 60, cwd: requestedFolder)
            guard generation == accountGeneration, !isSwitchingModelProvider, !Task.isCancelled,
                  requestedFolder == selectedFolder else { return }
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

    private func setLocalTurnRunning(
        _ threadID: String,
        turnID: String? = nil,
        permissions: String? = nil
    ) {
        threadOutcomes.removeValue(forKey: threadID)
        locallyRunningThreadIDs.insert(threadID)
        if let permissions { activePermissionByThreadID[threadID] = permissions }
        if localTurnStartedAtByThread[threadID] == nil {
            localTurnStartedAtByThread[threadID] = Date()
        }
        if let turnID { activeTurnIDsByThread[threadID] = turnID }
        syncSelectedLocalTurnState()
    }

    private func rememberTurnLaunch(
        threadID: String,
        model: String?,
        effort: String?,
        permissions: String?,
        serviceTier: String?,
        approvalPolicy: String? = nil,
        approvalsReviewer: String? = nil
    ) {
        turnLaunchSettingsByThreadID[threadID] = TurnLaunchSettings(
            model: model,
            effort: effort,
            permissions: permissions,
            serviceTier: serviceTier,
            approvalPolicy: approvalPolicy,
            approvalsReviewer: approvalsReviewer
        )
    }

    private func clearLocalTurn(_ threadID: String) {
        cancelComputerControlTimeouts(threadID: threadID)
        cancelCommandInactivityTimeouts(threadID: threadID)
        locallyRunningThreadIDs.remove(threadID)
        activeTurnIDsByThread.removeValue(forKey: threadID)
        activePermissionByThreadID.removeValue(forKey: threadID)
        localTurnStartedAtByThread.removeValue(forKey: threadID)
        syncSelectedLocalTurnState()
    }

    /// A terminated app-server cannot deliver the terminal turn event. Clear
    /// every optimistic local run so the UI does not remain "thinking"
    /// forever, while keeping the conversation and a durable inline reason.
    func handleClientDisconnect(_ message: String) {
        composerPredictions.removeAll()
        connectionText = "未连接"
        errorMessage = message
        flushPendingDeltas()
        let retryingThreadIDs = locallyRunningThreadIDs.filter { capacityRetryStates[$0] != nil }
        let interruptedThreadIDs = locallyRunningThreadIDs.subtracting(retryingThreadIDs)
        for threadID in interruptedThreadIDs {
            cancelComputerControlTimeouts(threadID: threadID)
            cancelCommandInactivityTimeouts(threadID: threadID)
            markLocalTurnInterrupted(threadID: threadID, message: message)
            setThreadRunning(threadID, running: false)
            threadOutcomes[threadID] = .interrupted
        }
        locallyRunningThreadIDs.removeAll()
        activeTurnIDsByThread.removeAll()
        localTurnStartedAtByThread.removeAll()
        syncSelectedLocalTurnState()
        if let selectedThreadID, interruptedThreadIDs.contains(selectedThreadID) {
            isExternalThreadProcessing = false
        }
        // A capacity retry may itself have been in flight when app-server
        // disconnected. Keep its recovery loop alive instead of converting it
        // to a terminal interruption.
        for threadID in retryingThreadIDs {
            guard let state = capacityRetryStates[threadID] else { continue }
            scheduleCapacityRetry(
                threadID: threadID,
                failedTurnID: "\(state.failedTurnID)-disconnect-\(state.attempt)",
                message: "连接暂时中断；CloudCodex 重连后会继续尝试。"
            )
        }
    }

    private func scheduleClientReconnect() {
        guard hasStarted, clientReconnectTask == nil else { return }
        clientReconnectTask = Task { [weak self] in
            guard let self else { return }
            defer { self.clientReconnectTask = nil }
            for delay in [2, 5, 10, 20, 30] as [UInt64] {
                do {
                    try await Task.sleep(nanoseconds: delay * 1_000_000_000)
                    try Task.checkCancellation()
                    try await self.client.start()
                    self.connectionText = "已重新连接本机 Codex"
                    self.startWeeklyQuotaSampling()
                    self.errorMessage = nil
                    await self.loadComposerOptions(cwd: self.selectedFolder)
                    await self.loadFolderCatalog()
                    await self.refreshThreads()
                    self.startThreadStatusMonitor()
                    if let threadID = self.selectedThreadID {
                        await self.claimSelectedThreadForInput(threadID: threadID)
                        await self.syncLatestExternalActivity(threadID: threadID)
                    }
                    Task { await self.connectionHealth.check() }
                    return
                } catch is CancellationError {
                    return
                } catch {
                    self.connectionText = "正在重新连接 Codex…"
                    self.errorMessage = "Codex 本地服务暂时不可用，CloudCodex 将继续自动重试。"
                }
            }
            self.connectionText = "未连接"
            self.errorMessage = "Codex 本地服务多次重连失败，请重启 CloudCodex。"
        }
    }

    private func markLocalTurnInterrupted(
        threadID: String,
        message: String,
        title: String = "连接中断",
        status: String = "失败"
    ) {
        var history = conversationMessages(for: threadID)
        for index in history.indices where history[index].isStreaming {
            history[index].isStreaming = false
            if history[index].role == .activity {
                history[index].activityStatus = status
                history[index].completedAt = Date()
            }
        }
        if let index = history.firstIndex(where: { $0.id == "turn-progress" }) {
            history[index].activityTitle = title
            history[index].text = message
            history[index].activityStatus = status
            history[index].isStreaming = false
            history[index].completedAt = Date()
        } else {
            history.append(.init(
                id: "connection-ended-\(UUID().uuidString)",
                role: .activity,
                text: message,
                isStreaming: false,
                activityKind: .warning,
                activityTitle: title,
                activityStatus: status,
                completedAt: Date()
            ))
        }
        storeMessages(history, for: threadID)
    }

    private func handleForcedStopDisconnect(threadID: String) {
        connectionText = "正在重新连接本机 Codex…"
        errorMessage = nil
        flushPendingDeltas()
        markLocalTurnInterrupted(
            threadID: threadID,
            message: "正常停止请求未及时返回，CloudCodex 已重启卡住的本地服务并强制结束当前任务。已经完成的文件修改不会自动回滚。",
            title: "任务已强制停止",
            status: "已停止"
        )
        clearLocalTurn(threadID)
        setThreadRunning(threadID, running: false)
        threadOutcomes[threadID] = .interrupted
        if selectedThreadID == threadID { isExternalThreadProcessing = false }
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
        guard !isSwitchingModelProvider else { return }
        if path != selectedFolder { speech.stop() }
        if path != selectedFolder { cancelWaitingMessageEdit() }
        if path != selectedFolder { cancelInterruptedMessageEdit() }
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
        if let path {
            stageNewThread(in: path)
        }
        Task {
            if canReleasePrevious, let previousThreadID {
                try? await client.unsubscribeThread(previousThreadID)
            }
            await loadPermissionProfiles(cwd: path)
            await refreshThreads()
        }
    }

    func selectThread(_ id: String?) {
        guard !isSwitchingModelProvider else { return }
        if let id { markConversationRead(id) }
        if id != selectedThreadID { speech.stop() }
        if id != selectedThreadID { cancelWaitingMessageEdit() }
        if id != selectedThreadID { cancelInterruptedMessageEdit() }
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
            // Browsing history does not need the writer. Load it while the
            // server restores input ownership, rather than blocking the whole
            // conversation behind thread/resume.
            async let ownership: Void = self.claimSelectedThreadForInput(
                threadID: id,
                releasing: canReleasePrevious ? previousThreadID : nil
            )
            await self.loadSelectedThread()
            await ownership
            guard !Task.isCancelled, self.selectedThreadID == id else { return }
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
        guard let selectedThreadID, threadInputAvailability != .checking else { return }
        await claimSelectedThreadForInput(threadID: selectedThreadID)
    }

    private func claimSelectedThreadForInput(threadID: String, releasing previousThreadID: String? = nil) async {
        let generation = selectionGeneration
        guard !Task.isCancelled, selectedThreadID == threadID else { return }
        threadInputAvailability = .checking
        threadOwnershipNotice = nil
        if let previousThreadID { try? await client.unsubscribeThread(previousThreadID) }
        guard !Task.isCancelled, generation == selectionGeneration, selectedThreadID == threadID else { return }
        do {
            let serviceTier = try await client.resumeThread(threadID)
            guard !Task.isCancelled, generation == selectionGeneration, selectedThreadID == threadID else { return }
            if let serviceTier {
                applyThreadServiceTier(serviceTier, threadID: threadID)
            }
            threadInputAvailability = .available
        } catch {
            guard !Task.isCancelled, generation == selectionGeneration, selectedThreadID == threadID else { return }
            if Self.isActiveWriterError(error) {
                errorMessage = nil
                threadInputAvailability = .occupied
                threadOwnershipNotice = Self.occupiedThreadMessage
            } else {
                // A failed resume has not established input ownership. Keep
                // the history usable and offer an inline retry without enabling
                // sends or opening a modal alert during navigation.
                threadInputAvailability = .unavailable
                threadOwnershipNotice = error.localizedDescription
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
            applyThreadServiceTier(updated.serviceTier, threadID: id)
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
                   let option = modelOptions.first(where: { ($0.id == model || $0.model == model)
                       && providerID(for: $0.id) == currentModelProviderID }) {
                    selectModel(option.id, preferredEffort: updated.reasoningEffort)
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
        guard creditUsagePauseReason == nil else { return }
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
        let outgoingServiceTier = selectedServiceTier
        guard (!text.isEmpty || !outgoingAttachments.isEmpty),
              let id = selectedThreadID, !isSending, !isExternalThreadProcessing else { return }

        speech.stop()
        composerText = ""
        attachments = []
        let localMessageID = "local-\(UUID().uuidString)"
        do {
            try await startTurnOptimistically(
                threadID: id,
                localMessageID: localMessageID,
                text: text,
                outgoingAttachments: outgoingAttachments,
                model: outgoingModel,
                effort: outgoingEffort,
                permissions: outgoingPermissions,
                serviceTier: outgoingServiceTier
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

    private func startTurnOptimistically(
        threadID: String,
        localMessageID: String,
        text: String,
        outgoingAttachments: [ComposerAttachment],
        model: String?,
        effort: String?,
        permissions: String?,
        serviceTier: String?
    ) async throws {
        rememberTurnLaunch(
            threadID: threadID,
            model: model,
            effort: effort,
            permissions: permissions,
            serviceTier: serviceTier
        )
        liveTurnMetadataByThread[threadID] = TurnModelMetadata(model: model, reasoningEffort: effort)
        setLocalTurnRunning(threadID, permissions: permissions)
        if selectedThreadID == threadID {
            isExternalThreadProcessing = false
            threadOwnershipNotice = nil
        }
        setThreadRunning(threadID, running: true)
        appendOptimisticUserMessage(
            threadID: threadID,
            localMessageID: localMessageID,
            text: text,
            outgoingAttachments: outgoingAttachments
        )
        if selectedThreadID == threadID { beginTurnProgress() }
        try await client.resumeThread(threadID)
        let turnID = try await client.startTurn(
            threadID: threadID,
            text: text,
            attachments: outgoingAttachments,
            model: model,
            effort: effort,
            permissions: permissions,
            serviceTier: serviceTier
        )
        setLocalTurnRunning(threadID, turnID: turnID)
    }

    func appendOptimisticUserMessage(
        threadID: String,
        localMessageID: String,
        text: String,
        outgoingAttachments: [ComposerAttachment]
    ) {
        var history = conversationMessages(for: threadID)
        history.removeAll { $0.id == localMessageID }
        history.append(.init(
            id: localMessageID,
            role: .user,
            text: text,
            attachments: outgoingAttachments.map {
                ChatMessageAttachment(
                    path: $0.url.path,
                    name: $0.url.lastPathComponent,
                    kind: $0.isImage ? .image : .file
                )
            },
            timestamp: Date()
        ))
        storeMessages(history, for: threadID)
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
        outgoingAttachments: [ComposerAttachment],
        restoreComposer: Bool = true
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
        guard restoreComposer, selectedThreadID == threadID else { return }
        composerText = text
        attachments = outgoingAttachments
    }

    static func isActiveWriterError(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("active writer")
    }

    static let occupiedThreadMessage = "请先在另一个应用中关闭此会话，才能在这里继续。"

    func cancelTurn() async {
        guard let threadID = selectedThreadID else { return }
        let cancelledCapacityRetry = cancelCapacityRetry(threadID: threadID)
        if let cancelledCapacityRetry {
            updateCapacityRetryActivity(
                threadID: threadID,
                failedTurnID: cancelledCapacityRetry.failedTurnID,
                title: "已停止自动重试",
                text: "已按你的操作停止模型容量不足后的持续重试；此前的执行记录和文件修改均保留。",
                status: "已停止",
                isStreaming: false
            )
        }
        guard let turnID = activeTurnID else {
            guard cancelledCapacityRetry != nil else { return }
            clearLocalTurn(threadID)
            setThreadRunning(threadID, running: false)
            threadOutcomes[threadID] = .interrupted
            finishTurnProgress(status: "已停止")
            return
        }
        do {
            try await client.interruptTurn(threadID: threadID, turnID: turnID)
        } catch {
            guard Self.isInterruptTimeout(error) else {
                errorMessage = error.localizedDescription
                return
            }
            errorMessage = nil
            connectionText = "停止无响应，正在重启本机 Codex…"
            forceStoppingThreadID = threadID
            client.terminateUnresponsiveServer()
        }
    }

    static func isInterruptTimeout(_ error: Error) -> Bool {
        guard case CodexClientError.timeout(let method) = error else { return false }
        return method == "turn/interrupt"
    }

    private func syncLatestExternalActivity(threadID: String) async {
        guard selectedThreadID == threadID else { return }
        let generation = selectionGeneration
        let revision = turnEventRevision[threadID, default: 0]
        do {
            let thread = try await client.readThreadState(threadID)
            guard selectedThreadID == threadID else { return }
            let snapshot: ThreadActivitySnapshot
            if thread.status == "active" || isSending || isExternalThreadProcessing || client.shouldRefreshActivity(thread) {
                snapshot = try await client.readLatestThreadActivity(
                    threadID,
                    knownThread: thread
                )
            } else {
                snapshot = ThreadActivitySnapshot(thread: thread, turn: nil, messages: [])
            }
            guard !Task.isCancelled, selectedThreadID == threadID,
                  generation == selectionGeneration,
                  revision == turnEventRevision[threadID, default: 0] else { return }
            if locallyRunningThreadIDs.contains(threadID) {
                _ = reconcileLocalTurnSnapshot(snapshot, threadID: threadID)
                return
            }
            applyExternalActivitySnapshot(snapshot, threadID: threadID)
        } catch {
            // Monitoring is best-effort. The primary app-server connection and
            // manual refresh remain available if another Codex process is busy.
        }
    }

    /// Repairs a missed `turn/completed` notification from persisted state.
    /// Exact matching terminal turns are accepted immediately. An idle thread
    /// without the expected turn is only released after a grace period so a
    /// freshly submitted turn is never cleared before app-server persists it.
    @discardableResult
    func reconcileLocalTurnSnapshot(
        _ snapshot: ThreadActivitySnapshot,
        threadID: String,
        now: Date = Date()
    ) -> Bool {
        guard locallyRunningThreadIDs.contains(threadID) else { return false }
        let activeTurnID = activeTurnIDsByThread[threadID]
        // Between capacity attempts there is intentionally no active server
        // turn. Do not let the generic stale-idle repair cancel that wait.
        if capacityRetryStates[threadID] != nil, activeTurnID == nil { return false }
        let exactTerminalTurn = activeTurnID != nil
            && snapshot.turn?.id == activeTurnID
            && snapshot.turn?.isActive == false
        let startedAt = localTurnStartedAtByThread[threadID] ?? now
        let staleIdleThread = snapshot.thread.status != "active"
            && now.timeIntervalSince(startedAt) >= Self.localTurnReconciliationGrace
            && (snapshot.turn == nil || snapshot.turn?.id != activeTurnID)
        guard exactTerminalTurn || staleIdleThread else { return false }

        clearLocalTurn(threadID)
        setThreadRunning(threadID, running: false)
        if exactTerminalTurn {
            applyExternalActivitySnapshot(snapshot, threadID: threadID)
        } else {
            threadOutcomes[threadID] = .interrupted
            markLocalTurnInterrupted(
                threadID: threadID,
                message: "没有收到任务结束事件，且 Codex 已报告该会话空闲。CloudCodex 已自动解除卡住状态。"
            )
        }
        return true
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
        guard providerID(for: id) == currentModelProviderID else { return }
        let option: CodexModelOption?
        if id == Self.recommendedModelSelectionID {
            option = recommendedModel
        } else {
            option = modelOptions.first(where: { $0.id == id })
        }
        guard let option else { return }
        selectedModelID = id
        if let preferredEffort, option.composerEfforts.contains(preferredEffort) {
            selectedEffort = preferredEffort
        } else if let selectedEffort, option.composerEfforts.contains(selectedEffort) {
            self.selectedEffort = selectedEffort
        } else {
            selectedEffort = option.defaultComposerEffort
        }
        if customModelProvider.enabled {
            customModelProvider.supportedReasoningEfforts = option.supportedEfforts
            customModelProvider.modelID = option.model
            customModelProvider.reasoningEffort = selectedEffort ?? customModelProvider.reasoningEffort
            client.customModelProvider = customModelProvider
        }
    }

    var currentModelProviderID: String {
        customModelProvider.enabled ? (customModelProvider.service?.rawValue ?? "legacy") : ModelProviderLibrary.openAI
    }

    func providerID(for optionID: String?) -> String {
        if optionID == Self.recommendedModelSelectionID { return currentModelProviderID }
        if let optionID, optionID.hasPrefix("provider:") {
            let parts = optionID.split(separator: ":", maxSplits: 2)
            if parts.count == 3 {
                let id = String(parts[1])
                if id == ModelProviderLibrary.openAI || providerLibrary.profiles.contains(where: { $0.id == id }) { return id }
            }
        }
        return ModelProviderLibrary.openAI
    }

    var isWaitingForRemoteAccountSwitch: Bool {
        isLoadingRemoteCredential || isRemoteUnpairing || isSendingRemoteOfflineHeartbeat
            || remoteClaimTask != nil || remoteHistoryTask != nil
    }

    var accountSwitchUnavailableReason: String? {
        if isSwitchingModelProvider { return "正在切换连接，请稍候。" }
        if accounts.busyID != nil { return "请先完成或取消账号登录、刷新操作。" }
        if isWaitingForRemoteAccountSwitch {
            return "正在处理远程请求，请稍候再切换账号。"
        }
        if !canChangeProviderConfiguration || !capacityRetryStates.isEmpty
            || !userInputRequests.isEmpty || !computerUseApprovalRequests.isEmpty
            || isRecording || revertingFileChanges != nil || resetCreditInProgressRef != nil
            || isRecheckingIncludedQuota || !creditInterruptingThreadIDs.isEmpty {
            return "请等待运行中、重试中及排队的任务结束后再切换账号。"
        }
        if isLoading || isConversationLoading || isLoadingUsageInsights || isLoadingPersonalSkills
            || isLoadingUnreadThreads { return "正在读取会话或账号资料，请稍候。" }
        return nil
    }

    /// Usage follows the login; conversation preferences stay shared.
    private var accountPreferenceKeys: [String] {
        [quotaConsumptionHistoryKey, Self.creditUsagePauseKey, WeeklyQuotaComparison.defaultsKey,
         AutomaticWeeklyQuotaSampler.defaultsKey]
    }

    private func prepareSharedConversations() throws {
        try CodexSharedConversations.prepare(home: CodexUsageTierStore.home(localCodexHome),
            accountHomes: accounts.library.accounts.compactMap { accounts.home(for: $0) })
    }

    private func mergeLegacyConversationPreferences() {
        let marker = "CloudCodex.sharedConversationPreferences.v1"
        guard !remoteDefaults.bool(forKey: marker) else { return }
        for account in accounts.library.accounts {
            let saved = remoteDefaults.dictionary(forKey: "CloudCodex.accountPreferences.v1." + account.id) ?? [:]
            if let data = saved[unreadCompletionsKey] as? Data,
               let old = try? JSONDecoder().decode(UnreadCompletions.self, from: data) {
                for (id, turn) in old.latestTurns where unreadCompletions.latestTurns[id] == nil {
                    unreadCompletions.latestTurns[id] = turn
                    if old.unread.contains(id) { unreadCompletions.unread.insert(id) }
                }
            }
            if let data = saved[favoriteConversationsKey] as? Data,
               let old = try? JSONDecoder().decode(FavoriteConversations.self, from: data) {
                for thread in old.sortedThreads() where !favoriteConversations.contains(thread.id) {
                    favoriteConversations.toggle(thread)
                }
            }
            revertedFileChanges.formUnion(saved[revertedFileChangesKey] as? [String] ?? [])
        }
        saveUnreadCompletions(); saveFavoriteConversations()
        remoteDefaults.set(Array(revertedFileChanges), forKey: revertedFileChangesKey)
        remoteDefaults.set(true, forKey: marker)
    }

    private func exchangeAccountPreferences(from oldID: String, to newID: String) {
        let prefix = "CloudCodex.accountPreferences.v1."
        var saved: [String: Any] = [:]
        for key in accountPreferenceKeys { saved[key] = remoteDefaults.object(forKey: key) }
        remoteDefaults.set(saved, forKey: prefix + oldID)
        let restored = remoteDefaults.dictionary(forKey: prefix + newID) ?? [:]
        for key in accountPreferenceKeys {
            if let value = restored[key] { remoteDefaults.set(value, forKey: key) }
            else { remoteDefaults.removeObject(forKey: key) }
        }
        quotaConsumptionTracker = remoteDefaults.data(forKey: quotaConsumptionHistoryKey)
            .flatMap { try? JSONDecoder().decode(QuotaConsumptionTracker.self, from: $0) } ?? QuotaConsumptionTracker()
        weeklyQuotaComparison = .load(remoteDefaults)
        automaticWeeklyQuotaSampler = .load(remoteDefaults)
    }

    func switchAccount(to id: String) async {
        guard id != accounts.library.activeID,
              let target = accounts.library.accounts.first(where: { $0.id == id }) else { return }
        if let reason = accountSwitchUnavailableReason { accountSwitchError = reason; return }
        let previousHome = client.codexHomeOverride
        let previousManaged = client.usesManagedAccount
        let targetHome = target.isLocal ? localCodexHome : accounts.home(for: target)
        let oldID = accounts.library.activeID
        isSwitchingModelProvider = true
        accountSwitchError = nil
        accounts.lockForSwitch(id)
        accountGeneration += 1
        // Keep the user's enabled/paired state. Stop dispatching remote work and
        // drain reads/uploads against the old account before replacing its client.
        let remoteLoop = remoteControlLoopTask
        remoteLoop?.cancel()
        let accountWorkers = [threadStatusMonitorTask, selectedThreadMonitorTask, selectedThreadMetadataTask,
                              creditUsageMonitorTask, creditUsageRefreshTask, clientReconnectTask].compactMap { $0 }
        stopWeeklyQuotaSampling()
        threadStatusMonitorTask?.cancel(); threadStatusMonitorTask = nil
        selectedThreadMonitorTask?.cancel(); selectedThreadMonitorTask = nil
        selectedThreadMetadataTask?.cancel(); selectedThreadMetadataTask = nil
        creditUsageMonitorTask?.cancel(); creditUsageMonitorTask = nil
        creditUsageRefreshTask?.cancel(); creditUsageRefreshTask = nil
        clientReconnectTask?.cancel(); clientReconnectTask = nil
        defer {
            accounts.unlockAfterSwitch()
            isSwitchingModelProvider = false
            startRemoteControlIfNeeded()
            if hasStarted {
                startThreadStatusMonitor(); startCreditUsageMonitor(); startWeeklyQuotaSampling()
                Task { await self.connectionHealth.check() }
            }
        }
        await remoteLoop?.value
        remoteControlLoopTask = nil
        let remoteWorkers = [remoteUsageTask, remoteSchedulingTask, remoteRecoveryTask,
                             remoteStatusUploadTask, remoteProgressUploadTask,
                             remoteNotificationUploadTask].compactMap { $0 }
        for worker in remoteWorkers { await worker.value }
        for worker in accountWorkers { await worker.value }
        guard locallyRunningThreadIDs.isEmpty, remoteExecutions.isEmpty,
              waitingMessages.isEmpty, capacityRetryStates.isEmpty,
              !isCreatingThread, !isSelectedThreadProcessing else {
            accountSwitchError = "请等待运行中、重试中及排队的任务结束后再切换账号。"
            return
        }
        do {
            try accounts.prepareHome(for: target)
            try prepareSharedConversations()
            mergeLegacyConversationPreferences()
            try await client.changeAccount(home: targetHome, managed: !target.isLocal)
            // Verify the actual identity before changing the selected card or local state.
            if target.isLocal {
                if let identity = try? await client.readAccountIdentity() { accounts.update(target.id, identity: identity) }
            } else {
                let identity = try await client.readAccountIdentity()
                guard target.identity == nil || target.identity?.email == identity.email else {
                    throw ModelProviderError.message("目标目录中的账号已变化，请重新授权。")
                }
                accounts.update(target.id, identity: identity)
            }
        } catch {
            do {
                try await client.changeAccount(home: previousHome, managed: previousManaged)
                connectionText = "已连接：\(accounts.active.title)（已恢复）"
            } catch {
                connectionText = "未连接"
            }
            accountSwitchError = "切换失败，仍保留原账号。请检查目标账号登录状态和本机 Codex 连接。"
            if let selectedThreadID {
                await claimSelectedThreadForInput(threadID: selectedThreadID)
                selectedThreadMonitorTask = Task { [weak self] in
                    while !Task.isCancelled {
                        guard let self, self.selectedThreadID == selectedThreadID else { return }
                        await self.syncLatestExternalActivity(threadID: selectedThreadID)
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    }
                }
            }
            return
        }
        threadRequestGeneration += 1
        selectionGeneration += 1
        exchangeAccountPreferences(from: oldID, to: id)
        accounts.activate(id)
        localQuotaTokenReader = CodexLocalTokenUsageReader(home: client.sharedConversationHome)
        automaticWeeklyQuotaSampler.reset()
        persistAutomaticWeeklyQuotaSampler()
        // Keep the selected conversation, rendered history, drafts and sidebar caches.
        pendingDeltaFlushTask?.cancel(); pendingDeltaFlushTask = nil
        turnProgressHintTask?.cancel(); turnProgressHintTask = nil
        pendingActivityDeltas.removeAll(); pendingAssistantDeltas.removeAll(); pendingDeltaOrder.removeAll()
        eventThreadID = nil; eventBuffer = nil
        isExternalThreadProcessing = false; threadOwnershipNotice = nil
        threadInputAvailability = selectedThreadID == nil ? .available : .checking
        isConversationLoading = false
        accountOverview = nil; accountOverviewError = nil
        usageInsights = nil; usageInsightsError = nil
        weeklyQuotaBaseline = nil; recentThirtyMinuteConsumptionRate = nil
        personalSkills = []; personalSkillsError = nil
        openAIModelOptions = []
        modelOptions = providerLibrary.composerOptions(openAI: [])
        permissionProfiles = []
        resetCreditStatusMessage = nil; resetCreditStatusIsError = false
        quotaRestorationTracker = QuotaRestorationTracker()
        creditUsageProtection.reset(); creditUsagePauseReason = nil
        creditUsagePauseFailures.removeAll(); includedQuotaCheckMessage = nil
        remoteUsageSnapshot = nil; remoteUsageLastAttempt = nil
        remoteSchedulingState = RemoteSchedulingState(); remoteSchedulingLastAttempt = nil
        remoteRecoveryLastAttempt = nil
        connectionText = "已连接：\(accounts.active.title)"
        errorMessage = nil
        await loadComposerOptions(cwd: selectedThread?.cwd)
        await loadFolderCatalog()
        await refreshThreads()
        if let selectedThreadID {
            await claimSelectedThreadForInput(threadID: selectedThreadID)
            if hasStarted {
                selectedThreadMonitorTask = Task { [weak self] in
                    while !Task.isCancelled {
                        guard let self, self.selectedThreadID == selectedThreadID else { return }
                        await self.syncLatestExternalActivity(threadID: selectedThreadID)
                        do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    }
                }
            }
        }
        do { applyAccountOverview(try await client.readAccountOverview()) }
        catch { accountOverviewError = "账号已切换，额度暂时无法读取，请稍后刷新。" }
    }

    var canChangeProviderConfiguration: Bool {
        !isSwitchingModelProvider && locallyRunningThreadIDs.isEmpty && remoteExecutions.isEmpty
            && waitingMessages.isEmpty && !isCreatingThread && !isSelectedThreadProcessing
    }

    func canApplyModelSelection(_ id: String?) -> Bool {
        !isSwitchingModelProvider && (providerID(for: id) == currentModelProviderID || canChangeProviderConfiguration)
    }

    func applyConversationModel(_ id: String, effort: String?) async throws {
        guard id == Self.recommendedModelSelectionID || modelOptions.contains(where: { $0.id == id }) else {
            throw ModelProviderError.message("此模型已不在可用列表中，请重新选择。")
        }
        let target = providerID(for: id)
        if target != currentModelProviderID {
            guard canChangeProviderConfiguration else {
                throw ModelProviderError.message("请等待运行中及排队任务结束后再切换厂商。同一家可为下一轮选择模型。")
            }
            let profile = providerLibrary.profile(for: id)
            guard target == ModelProviderLibrary.openAI || profile != nil else { return }
            try await reconnectModelProvider(profile?.configuration ?? ModelProviderConfiguration(), options: profile?.options ?? [])
        }
        selectModel(id, preferredEffort: effort)
    }

    func applyProviderLibrary(_ library: ModelProviderLibrary) async throws {
        guard canChangeProviderConfiguration else {
            throw ModelProviderError.message("请等待运行中及排队的任务结束，再保存厂商配置。")
        }
        let value = try library.validated()
        let previousID = selectedModelID
        let previousEffort = selectedEffort
        let currentProfile = value.profiles.first { $0.id == currentModelProviderID && $0.configuration.enabled }
        let keepCurrent = value.providerIDAfterSaving(current: currentModelProviderID) == currentModelProviderID
        let configuration = keepCurrent ? (currentProfile?.configuration ?? ModelProviderConfiguration()) : value.activeConfiguration
        let options = keepCurrent ? (currentProfile?.options ?? []) : (value.profiles.first { $0.id == value.defaultProviderID }?.options ?? [])
        try await reconnectModelProvider(configuration, options: options)
        providerLibrary = value
        remoteDefaults.set(try JSONEncoder().encode(value), forKey: ModelProviderLibrary.defaultsKey)
        // Retain the v1 compatibility view and the original Keychain accounts.
        remoteDefaults.set(try JSONEncoder().encode(configuration), forKey: ModelProviderConfiguration.defaultsKey)
        modelOptions = value.composerOptions(openAI: openAIModelOptions)
        let retained = keepCurrent ? previousID.flatMap { id in modelOptions.first { $0.id == id } } : nil
        selectedEffort = nil
        selectModel(retained?.id ?? Self.recommendedModelSelectionID, preferredEffort: retained == nil ? nil : previousEffort)
    }

    private func reconnectModelProvider(_ configuration: ModelProviderConfiguration, options: [CodexModelOption]) async throws {
        let previous = customModelProvider
        let previousOptions = client.customModelOptions
        isSwitchingModelProvider = true
        stopWeeklyQuotaSampling()
        threadStatusMonitorTask?.cancel(); threadStatusMonitorTask = nil
        creditUsageMonitorTask?.cancel(); creditUsageMonitorTask = nil
        creditUsageRefreshTask?.cancel(); creditUsageRefreshTask = nil
        clientReconnectTask?.cancel(); clientReconnectTask = nil
        defer {
            isSwitchingModelProvider = false
            if hasStarted { startThreadStatusMonitor(); startCreditUsageMonitor(); startWeeklyQuotaSampling() }
        }
        do {
            try await client.changeProvider(configuration, options: options)
        } catch {
            // Restore the previous route if the new local service failed to initialize.
            try? await client.changeProvider(previous, options: previousOptions)
            throw error
        }
        customModelProvider = configuration
        quotaRestorationTracker = QuotaRestorationTracker()
        creditUsageProtection.reset(); creditUsagePauseReason = nil
        if configuration.enabled { isFastModeEnabled = false }
        if !configuration.enabled {
            if let fresh = try? await client.listModels() { openAIModelOptions = fresh }
            modelOptions = providerLibrary.composerOptions(openAI: openAIModelOptions)
        }
        connectionText = configuration.enabled ? "已连接：\(configuration.name)" : "已连接 OpenAI（本机 Codex）"
        // All loaded-thread caches were cleared with the subprocess. The next
        // submission resumes persisted history through the newly selected route.
    }

    func setFastModeEnabled(_ enabled: Bool) {
        guard !enabled || supportsFastMode else { return }
        // The model picker confirms model, effort, and speed together. Avoid
        // sending a service-tier update when the user only changed the model
        // or reasoning effort; an active turn may reject that redundant
        // update because step-level model switching is unavailable.
        guard Self.fastModeNeedsSync(current: isFastModeEnabled, requested: enabled) else { return }
        let previousEnabled = isFastModeEnabled
        isFastModeEnabled = enabled
        remoteDefaults.set(enabled, forKey: fastModeKey)
        fastModePreferenceGeneration += 1
        let preferenceGeneration = fastModePreferenceGeneration
        guard let threadID = selectedThreadID else { return }

        let serviceTier = enabled ? (selectedModelCapabilities?.fastServiceTierID ?? "priority") : "default"
        let previousServiceTier = selectedThread?.serviceTier
        let generation = serviceTierUpdateGenerationByThread[threadID, default: 0] + 1
        serviceTierUpdateGenerationByThread[threadID] = generation
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.updateThreadServiceTier(
                    threadID: threadID,
                    serviceTier: serviceTier
                )
                guard self.serviceTierUpdateGenerationByThread[threadID] == generation else { return }
                self.applyThreadServiceTier(serviceTier, threadID: threadID)

                if let turnID = self.activeTurnIDsByThread[threadID] {
                    do {
                        try await self.client.updateTurnServiceTier(
                            threadID: threadID,
                            turnID: turnID,
                            serviceTier: serviceTier
                        )
                    } catch {
                        if !Self.shouldSuppressTurnSettingsError(error.localizedDescription) {
                            self.errorMessage = "会话速度已同步，但当前正在执行的任务未能立即切换：\(error.localizedDescription)"
                        }
                    }
                }
            } catch {
                guard self.serviceTierUpdateGenerationByThread[threadID] == generation else { return }
                self.applyThreadServiceTier(previousServiceTier, threadID: threadID)
                if self.fastModePreferenceGeneration == preferenceGeneration {
                    self.isFastModeEnabled = previousEnabled
                    self.remoteDefaults.set(previousEnabled, forKey: self.fastModeKey)
                }
                self.errorMessage = "同步响应速度失败：\(error.localizedDescription)"
            }
        }
    }

    static func fastModeNeedsSync(current: Bool, requested: Bool) -> Bool {
        current != requested
    }

    static func shouldSuppressTurnSettingsError(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("step_model_switching")
            || normalized.contains("turn settings updates require")
    }

    func prepareNewThread() {
        guard !isSwitchingModelProvider else { return }
        speech.stop()
        cancelWaitingMessageEdit()
        cancelInterruptedMessageEdit()
        let folder = selectedFolder
            ?? selectedThread?.cwd
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        if showingNewThread {
            newThreadFocusRequest = UUID()
            return
        }
        selectedThreadMonitorTask?.cancel()
        selectedThreadMonitorTask = nil
        preserveSelectedConversation()
        isExternalThreadProcessing = false
        stageNewThread(in: folder)
        Task { await loadPermissionProfiles(cwd: newThreadFolder) }
    }

    private func stageNewThread(in folder: String) {
        newThreadFocusRequest = UUID()
        newThreadFolder = folder
        newThreadPrompt = ""
        newThreadAttachments = []
        threadOwnershipNotice = nil
        selectedThreadID = nil
        syncSelectedLocalTurnState()
        messages = []
        showingNewThread = true
    }

    func cancelNewThread() {
        if speechTargetsNewThread { speech.stop() }
        speechTargetsNewThread = false
        showingNewThread = false
        newThreadPrompt = ""
        newThreadAttachments = []
    }

    func createThread() async {
        guard creditUsagePauseReason == nil else { return }
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
                permissions: selectedPermissionID,
                serviceTier: selectedServiceTier
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
        mergeAddedWorkspaces()
    }

    private func mergeAddedWorkspaces() {
        let existingPaths = Set(folderCatalog.map(\.path))
        let addedFolders = workspaceOrganization.addedFolderPaths.compactMap { path -> WorkspaceFolder? in
            guard !existingPaths.contains(path) else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return WorkspaceFolder(path: path, threadCount: 0, latestUpdate: .distantPast)
        }
        folderCatalog.append(contentsOf: addedFolders)
    }

    /// Refresh the catalog without applying settings to the current conversation.
    /// New models can become available while this app-server connection stays open.
    func refreshModelCatalog() async {
        do {
            modelOptions = try await readComposerModels()
        } catch {
            errorMessage = "无法读取 Codex 模型列表：\(error.localizedDescription)"
        }
    }

    private func loadComposerOptions(cwd: String?) async {
        do {
            modelOptions = try await readComposerModels()
            let preferred = modelOptions.first(where: {
                $0.model == selectedThread?.model && providerID(for: $0.id) == currentModelProviderID
            })?.id
                ?? (selectedModelID == Self.recommendedModelSelectionID ? Self.recommendedModelSelectionID : nil)
                ?? modelOptions.first(where: { $0.id == selectedModelID })?.id
                ?? (recommendedModel == nil ? nil : Self.recommendedModelSelectionID)
                ?? modelOptions.first?.id
            if let preferred { selectModel(preferred, preferredEffort: selectedThread?.reasoningEffort) }
        } catch {
            errorMessage = "无法读取 Codex 模型列表：\(error.localizedDescription)"
        }
        await loadPermissionProfiles(cwd: cwd)
    }

    private func readComposerModels() async throws -> [CodexModelOption] {
        if !customModelProvider.enabled {
            openAIModelOptions = try await client.listModels()
        } else if openAIModelOptions.isEmpty {
            openAIModelOptions = (try? await client.bundledOpenAIModels()) ?? []
        }
        return providerLibrary.composerOptions(openAI: openAIModelOptions)
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

    var canChangeRemoteServer: Bool {
        !remoteControlEnabled && !isLoadingRemoteCredential && !isRemoteUnpairing
            && !isSendingRemoteOfflineHeartbeat && remoteExecutions.isEmpty
            && remoteClaimTask == nil && remoteHistoryTask == nil
            && remoteRecoveryTask == nil
            && remoteStatusUploadTask == nil && remoteProgressUploadTask == nil
            && remoteSchedulingTask == nil
    }

    @discardableResult
    func saveRemoteServerConfiguration(_ configuration: RemoteServerConfiguration) -> Bool {
        guard canChangeRemoteServer else {
            remoteServerConfigurationError = "请先关闭远程任务，等待当前任务和连接操作结束后再保存。"
            return false
        }
        do {
            let url = try configuration.validatedURL()
            var saved = configuration
            saved.customAddress = saved.mode == .custom ? url.absoluteString : ""
            let data = try JSONEncoder().encode(saved)
            if saved != remoteServerConfiguration {
                remoteServerConfiguration = saved
                remoteDefaults.set(data, forKey: RemoteServerConfiguration.defaultsKey)
                remoteControlAPI = nil
                remoteCredentialIssue = nil
                remoteControlPaired = false
                remotePairingCode = ""
                remotePairingExpiresAt = nil
                remoteLastSyncAt = nil
                remoteDefaults.removeObject(forKey: remotePairingCodeKey)
                remoteUsageSnapshot = nil
                remoteUsageLastAttempt = nil
                remoteRecoveryLastAttempt = nil
                remoteControlStatus = "服务配置已保存，开启远程任务后连接并配对"
            }
            remoteServerConfigurationError = nil
            return true
        } catch {
            remoteServerConfigurationError = error.localizedDescription
            return false
        }
    }

    func setRemoteControlEnabled(_ enabled: Bool) {
        guard !isSwitchingModelProvider else { return }
        if enabled {
            do { _ = try remoteServerConfiguration.validatedURL() }
            catch {
                remoteServerConfigurationError = error.localizedDescription
                remoteControlStatus = "服务地址无效，请先保存有效配置"
                return
            }
        }
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
            guard !isSendingRemoteOfflineHeartbeat else { return }
            isSendingRemoteOfflineHeartbeat = true
            Task { [weak self] in
                guard let self else { return }
                defer { self.isSendingRemoteOfflineHeartbeat = false }
                let body = self.makeRemoteHeartbeat(ready: false)
                _ = try? await api.heartbeat(body)
            }
        }
    }

    func resetRemotePairingCode() {
        guard remoteControlEnabled, !remoteControlPaired, let api = remoteControlAPI else { return }
        remoteControlStatus = "正在生成新配对二维码…"
        Task { [weak self] in
            do {
                let registration = try await api.register(resetPairing: true)
                guard let self, self.remoteControlAPI === api, self.remoteControlEnabled else { return }
                self.applyRemoteRegistration(registration)
            } catch {
                if let self, self.remoteControlAPI === api, self.remoteControlEnabled {
                    self.remoteControlStatus = "生成配对二维码失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func unpairAndPrepareRemoteRebinding() {
        guard remoteControlEnabled, remoteControlPaired, !isRemoteUnpairing,
              let api = remoteControlAPI else { return }
        isRemoteUnpairing = true
        remoteControlStatus = "正在解除配对…"
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRemoteUnpairing = false }
            do {
                try await api.unpair()
                self.remoteControlPaired = false
                self.remoteUsageSnapshot = nil
                self.remoteUsageLastAttempt = nil
                self.remotePairingCode = ""
                self.remotePairingExpiresAt = nil
                self.remoteDefaults.removeObject(forKey: self.remotePairingCodeKey)
                self.remoteControlStatus = "正在生成重新绑定二维码…"
                do {
                    self.applyRemoteRegistration(try await api.register(resetPairing: true))
                } catch {
                    self.remoteControlStatus = "已解除配对，生成新二维码失败：\(error.localizedDescription)"
                }
            } catch {
                self.remoteControlStatus = "解除配对失败：\(error.localizedDescription)"
            }
        }
    }

    var remotePairingQRCodePayload: String? {
        guard let expiresAt = remotePairingExpiresAt, expiresAt > Date() else { return nil }
        return RemotePairingQRCode.payload(code: remotePairingCode)
    }

    private func startRemoteControlIfNeeded() {
        guard !isSwitchingModelProvider, remoteControlEnabled, remoteControlLoopTask == nil else { return }
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
                let api: RemoteControlAPI
                if let loader = self.remoteAPILoader {
                    api = try await loader(allowInteraction)
                } else {
                    api = try await RemoteControlAPI.connect(allowInteraction: allowInteraction,
                        configuration: self.remoteServerConfiguration, defaults: self.remoteDefaults)
                }
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
            guard !Task.isCancelled, remoteControlEnabled, remoteControlAPI === api else { return }
            applyRemoteRegistration(registration)
        } catch {
            if !Task.isCancelled, remoteControlAPI === api { remoteControlStatus = "远程服务连接失败：\(error.localizedDescription)" }
        }

        var heartbeatCountdown = 0
        // Initial global read also avoids briefly clearing the relay's history
        // with whichever workspace happens to be selected at launch.
        guard !Task.isCancelled else { return }
        await refreshRemoteSchedulingSnapshot()
        while !Task.isCancelled, remoteControlEnabled, remoteControlAPI === api {
            refreshRemoteUsageIfNeeded()
            refreshRemoteSchedulingIfNeeded()
            if heartbeatCountdown <= 0 {
                do {
                    let response = try await api.heartbeat(makeRemoteHeartbeat(ready: true))
                    guard !Task.isCancelled, remoteControlEnabled, remoteControlAPI === api else { return }
                    remoteControlPaired = response.paired
                    remoteLastSyncAt = Date()
                    if response.paired, let running = response.runningTasks {
                        reconcileRemoteTasks(running, api: api)
                    }
                    if response.paired {
                        remotePairingCode = ""
                        remotePairingExpiresAt = nil
                        remoteDefaults.removeObject(forKey: remotePairingCodeKey)
                        if remoteExecutions.isEmpty {
                            remoteControlStatus = remoteStatusOutbox.pending(deviceID: api.deviceID).isEmpty
                                ? (response.queueSummary?.waitingDescription
                                   ?? ((response.runningTasks?.isEmpty ?? true) ? "已配对，正在等待远程任务" : "已连接，正在核对未结束任务"))
                                : "任务状态待补传，正在自动重试"
                        }
                    } else {
                        await refreshRemotePairingQRCodeIfNeeded(api: api)
                        remoteControlStatus = remotePairingQRCodePayload == nil
                            ? "等待生成配对二维码…"
                            : "等待小程序扫码配对"
                    }
                } catch {
                    if !Task.isCancelled, remoteControlAPI === api { remoteControlStatus = "状态同步失败：\(error.localizedDescription)" }
                }
                heartbeatCountdown = 3
            }

            // Disabling remote control can happen while heartbeat is in flight.
            // Do not dispatch a new unstructured claim worker after that await.
            guard !Task.isCancelled, remoteControlEnabled else { break }
            if remoteControlPaired, remoteHistoryTask == nil {
                remoteHistoryTask = Task { [weak self] in
                guard let self else { return }
                defer { self.remoteHistoryTask = nil; self.objectWillChange.send() }
                // Account resets are explicit confirmed commands, separate from development turns.
                do {
                    if let attempt = try await api.nextReset(), self.remoteControlEnabled, !Task.isCancelled {
                        let outcome = try await self.client.consumeRemoteReset(attempt)
                        try await api.finishReset(attempt.id, status: outcome)
                        self.remoteUsageSnapshot = (try? await self.client.readRemoteUsage()) ?? .unavailable()
                        self.remoteUsageLastAttempt = Date()
                    }
                } catch { /* Keep the durable attempt for retry with the same idempotency key. */ }
                // Favorite commands change local sidebar metadata only, never start a turn.
                do {
                    if let change = try await api.nextFavorite() {
                        guard self.remoteControlEnabled, !Task.isCancelled, self.remoteControlAPI === api else { return }
                        var status = "applied"
                        do {
                            guard change.deviceId == api.deviceID, !change.isExpired(),
                                  self.folderCatalog.contains(where: { $0.path == change.workspace }) else {
                                throw RemoteControlError.server("工作区未授权")
                            }
                            if !self.favoriteConversations.hasApplied(change.id) {
                                let thread: CodexThread
                                if let known = self.favoriteConversations.thread(change.threadId) {
                                    thread = known
                                } else {
                                    (thread, _) = try await self.client.readThread(change.threadId)
                                }
                                guard self.remoteControlEnabled, !Task.isCancelled, self.remoteControlAPI === api else { return }
                                guard !change.isExpired(), thread.id == change.threadId, thread.cwd == change.workspace,
                                      self.folderCatalog.contains(where: { $0.path == thread.cwd }) else {
                                    throw RemoteControlError.server("会话工作区不匹配")
                                }
                                self.favoriteConversations.apply(thread, favorited: change.favorited, commandID: change.id)
                                self.saveFavoriteConversations()
                            }
                        } catch { status = "failed" }
                        guard self.remoteControlEnabled, !Task.isCancelled, self.remoteControlAPI === api else { return }
                        try await api.finishFavorite(change.id, status: status)
                    }
                } catch { /* Older relays lack this optional endpoint; acknowledgements retry safely. */ }
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
            if remoteControlPaired, remoteClaimTask == nil, creditUsagePauseReason == nil,
               !Self.computerControlCircuitIsOpen(until: computerControlCircuitOpenUntil, now: Date()),
               Self.canClaimRemoteTask(
                    remoteExecutionCount: remoteExecutions.count,
                    maxConcurrentRemoteExecutions: maxConcurrentRemoteExecutions
               ) {
                // A slow image download / writer check must not pause heartbeat,
                // history reads or status recovery. Keep claiming single-flight.
                remoteClaimTask = Task { [weak self] in
                    guard let self else { return }
                    defer { self.remoteClaimTask = nil; self.objectWillChange.send() }
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
                    defer { self.remoteStatusUploadTask = nil; self.objectWillChange.send() }
                    for (id, body) in self.remoteStatusOutbox.pending(deviceID: api.deviceID) {
                        guard !Task.isCancelled else { return }
                        await self.uploadRemoteStatus(id, body: body, api: api)
                    }
                }
            }

            if remoteControlPaired, remoteNotificationUploadTask == nil,
               !remoteNotificationOutbox.pending(deviceID: api.deviceID).isEmpty {
                remoteNotificationUploadTask = Task { [weak self] in
                    guard let self else { return }
                    defer { self.remoteNotificationUploadTask = nil; self.objectWillChange.send() }
                    for (_, body) in self.remoteNotificationOutbox.pending(deviceID: api.deviceID) {
                        guard !Task.isCancelled else { return }
                        do {
                            try await api.sendNotificationEvent(body)
                            self.remoteNotificationOutbox.acknowledge(deviceID: api.deviceID, body: body)
                        } catch {
                            return
                        }
                    }
                }
            }

            if remoteProgressUploadTask == nil {
                remoteProgressUploadTask = Task { [weak self] in
                    guard let self else { return }
                    defer { self.remoteProgressUploadTask = nil; self.objectWillChange.send() }
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
            remotePairingExpiresAt = RemotePairingQRCode.expirationDate(registration.pairingExpiresAt)
            remoteDefaults.set(registration.pairingCode, forKey: remotePairingCodeKey)
        }
        if registration.paired {
            remotePairingCode = ""
            remotePairingExpiresAt = nil
            remoteDefaults.removeObject(forKey: remotePairingCodeKey)
            remoteControlStatus = "已配对，正在等待远程任务"
        } else {
            remoteControlStatus = remotePairingQRCodePayload == nil ? "等待生成配对二维码…" : "等待小程序扫码配对"
        }
    }

    private func refreshRemotePairingQRCodeIfNeeded(api: RemoteControlAPI, now: Date = Date()) async {
        guard !remoteControlPaired else { return }
        let needsRefresh = remotePairingCode.isEmpty
            || remotePairingExpiresAt == nil
            || remotePairingExpiresAt!.timeIntervalSince(now) <= 4
        guard needsRefresh else { return }
        do {
            let registration = try await api.register(resetPairing: true)
            guard !Task.isCancelled, remoteControlEnabled, remoteControlAPI === api else { return }
            applyRemoteRegistration(registration)
        } catch {
            if !Task.isCancelled, remoteControlEnabled, remoteControlAPI === api {
                remoteControlStatus = "刷新配对二维码失败：\(error.localizedDescription)"
            }
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
            defer { self.remoteSchedulingTask = nil; self.objectWillChange.send() }
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
        let models = modelOptions.filter { providerID(for: $0.id) == currentModelProviderID }.prefix(100).map {
            RemoteModelSnapshot(
                id: $0.id,
                model: $0.model,
                name: $0.pickerName,
                description: $0.description,
                supportedEfforts: $0.composerEfforts,
                defaultEffort: $0.defaultComposerEffort ?? $0.defaultEffort,
                supportsFast: $0.fastServiceTierID != nil
            )
        }
        return RemoteHeartbeatBody(
            name: remoteControlAPI?.deviceName ?? "CloudCodex Mac",
            permissionLabel: remotePermissionLabel,
            remoteControlReady: ready,
            workspaces: Array(workspaces),
            threads: favoriteConversations.remoteSnapshots(recent: snapshots, allowedPaths: Set(workspaces.map(\.path))),
            models: Array(models),
            usage: remoteControlPaired ? remoteUsageSnapshot : nil,
            defaultModel: selectedModelCapabilities?.model,
            defaultEffort: selectedEffort,
            systemMetrics: remoteControlPaired && systemMetrics.snapshot.hasValues ? systemMetrics.snapshot : nil,
            connectionHealth: remoteControlPaired ? connectionHealth.remoteSnapshot : nil
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
        let modelOverride: String?
        if requestedModel.isEmpty {
            modelOption = selectedModelCapabilities
            modelOverride = selectedModel?.model
        } else {
            guard let available = modelOptions.first(where: {
                ($0.id == requestedModel || $0.model == requestedModel) && providerID(for: $0.id) == currentModelProviderID
            }) else {
                await failRemoteTask(task, message: "这台 Mac 当前不支持模型 \(requestedModel)。")
                return
            }
            modelOption = available
            modelOverride = available.model
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
        var acquiredThreadSubscription = false
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
                    model: modelOverride,
                    permissions: permission,
                    serviceTier: tier
                )
                threadID = thread.id
                acquiredThreadSubscription = true
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
                acquiredThreadSubscription = true
            }

            remoteExecutions[threadID] = RemoteExecution(taskID: task.taskId, threadID: threadID, turnID: nil, responseText: "")
            computerControlNativeFailures.removeValue(forKey: threadID)
            remoteControlStatus = "正在执行 \(remoteExecutions.count) 个远程任务"
            rememberTurnLaunch(
                threadID: threadID,
                model: modelOverride,
                effort: effort,
                permissions: permission,
                serviceTier: tier,
                approvalPolicy: approval,
                approvalsReviewer: reviewer
            )
            setLocalTurnRunning(threadID, permissions: permission)
            setThreadRunning(threadID, running: true)
            // Capture this remote request, never the visible composer's model.
            liveTurnMetadataByThread[threadID] = TurnModelMetadata(
                model: modelOverride, reasoningEffort: effort
            )
            let turnID = try await client.startTurn(
                threadID: threadID,
                text: task.prompt,
                attachments: attachments,
                model: modelOverride,
                effort: effort,
                permissions: permission,
                serviceTier: tier,
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
            if acquiredThreadSubscription {
                scheduleRemoteThreadRelease(threadID)
            }
            if Self.shouldDeferRemoteTask(error) {
                await deferRemoteTask(task, threadID: threadID, reason: Self.remoteWaitReason(error))
                return
            }
            await failRemoteTask(task, threadID: threadID, message: error.localizedDescription)
        }
    }

    static func shouldDeferRemoteTask(_ error: Error) -> Bool {
        if error is CreditUsageBlocked { return true }
        let message = error.localizedDescription.lowercased()
        return message.contains("active writer")
            || message.contains("这个会话正在 codex 中运行")
            || message.contains("这个会话正在执行其他任务")
    }

    static func remoteWaitReason(_ error: Error) -> String {
        error.localizedDescription.lowercased().contains("active writer") ? "writer_busy" : "thread_busy"
    }

    static func canClaimRemoteTask(
        remoteExecutionCount: Int,
        maxConcurrentRemoteExecutions: Int
    ) -> Bool {
        maxConcurrentRemoteExecutions > 0
            && remoteExecutionCount < maxConcurrentRemoteExecutions
    }

    static func computerControlCircuitIsOpen(until: Date?, now: Date) -> Bool {
        guard let until else { return false }
        return until > now
    }

    static func shouldReleaseRemoteThread(
        _ threadID: String,
        selectedThreadID: String?,
        locallyRunningThreadIDs: Set<String>,
        waitingThreadIDs: Set<String>,
        remoteExecutionThreadIDs: Set<String>,
        capacityRetryThreadIDs: Set<String>
    ) -> Bool {
        selectedThreadID != threadID
            && !locallyRunningThreadIDs.contains(threadID)
            && !waitingThreadIDs.contains(threadID)
            && !remoteExecutionThreadIDs.contains(threadID)
            && !capacityRetryThreadIDs.contains(threadID)
    }

    /// Releases the writer and all per-thread MCP processes acquired for an
    /// unselected mini-program task. Local selection, waiting messages and a
    /// capacity retry keep their lease and remain resumable.
    private func scheduleRemoteThreadRelease(_ threadID: String) {
        guard Self.shouldReleaseRemoteThread(
            threadID,
            selectedThreadID: selectedThreadID,
            locallyRunningThreadIDs: locallyRunningThreadIDs,
            waitingThreadIDs: Set(waitingMessages.map(\.threadID)),
            remoteExecutionThreadIDs: Set(remoteExecutions.keys),
            capacityRetryThreadIDs: Set(capacityRetryStates.keys)
        ), remoteReleasingThreadIDs.insert(threadID).inserted else { return }

        Task { [weak self] in
            guard let self else { return }
            defer { self.remoteReleasingThreadIDs.remove(threadID) }
            try? await self.client.unsubscribeThread(threadID)
        }
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
            defer { self.remoteRecoveryTask = nil; self.objectWillChange.send() }
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
                            self.scheduleRemoteThreadRelease(body.threadId)
                        }
                        await self.reportRemoteTaskStatus(id, body: body, api: api)
                    }
                } catch {
                    // A read failure is not evidence that a turn ended. Try again next heartbeat.
                    if !Task.isCancelled { self.remoteControlStatus = "未结束任务核对失败，将自动重试；正常任务不受影响" }
                }
            }
        }
    }

    private func reportRemoteTaskStatus(_ taskID: String, body: RemoteTaskStatusBody, api sourceAPI: RemoteControlAPI? = nil) async {
        guard let api = sourceAPI ?? remoteControlAPI else { return }
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
            if !Task.isCancelled, remoteControlAPI === api { remoteControlStatus = "任务状态待补传，网络恢复后自动重试" }
        }
    }

    private func handleRemoteEvent(_ method: String, params: [String: Any], threadID: String) {
        guard var execution = remoteExecutions[threadID], let api = remoteControlAPI else { return }
        if method == "error", params["willRetry"] as? Bool == true { return }
        let eventTurnID = params["turnId"] as? String ?? (params["turn"] as? [String: Any])?["id"] as? String
        if let expected = execution.turnID, let eventTurnID, expected != eventTurnID { return }
        execution.progress.consume(method, params)
        if let message = Self.capacityFailure(method: method, params: params) {
            // Keep the remote claim alive. The replacement turn will receive a
            // new id, while all progress collected before capacity exhaustion
            // remains attached to this same remote task.
            execution.turnID = nil
            remoteExecutions[threadID] = execution
            remoteControlStatus = "远程任务模型繁忙，CloudCodex 将持续重试：\(message)"
            return
        }
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
            let nativeFailure = computerControlNativeFailures.removeValue(forKey: threadID)
            let errorText = nativeFailure ?? errorObject?["message"] as? String ?? ""
            let failureText = errorText.isEmpty ? "Codex 执行远程任务失败。" : errorText
            let completedSuccessfully = status == "completed" && nativeFailure == nil
            remoteExecutions.removeValue(forKey: threadID)
            scheduleRemoteThreadRelease(threadID)
            remoteControlStatus = remoteExecutions.isEmpty
                ? (completedSuccessfully ? "远程任务已完成" : "远程任务执行失败：\(failureText)")
                : "正在执行 \(remoteExecutions.count) 个远程任务"
            Task { [weak self] in
                await self?.reportRemoteTaskStatus(execution.taskID, body: RemoteTaskStatusBody(
                        status: completedSuccessfully ? "completed" : "failed",
                        threadId: execution.threadID,
                        turnId: execution.turnID ?? "",
                        result: execution.responseText,
                        error: completedSuccessfully ? "" : failureText,
                        fileDiff: execution.fileDiff, progress: execution.progress
                ), api: api)
            }
        case "error":
            let errorObject = params["error"] as? [String: Any]
            let message = errorObject?["message"] as? String ?? "Codex 执行远程任务失败。"
            remoteExecutions.removeValue(forKey: threadID)
            clearLocalTurn(execution.threadID)
            setThreadRunning(execution.threadID, running: false)
            scheduleRemoteThreadRelease(threadID)
            remoteControlStatus = remoteExecutions.isEmpty ? "远程任务失败：\(message)" : "正在执行 \(remoteExecutions.count) 个远程任务"
            Task { [weak self] in
                await self?.reportRemoteTaskStatus(execution.taskID, body: RemoteTaskStatusBody(
                        status: "failed", threadId: execution.threadID,
                        turnId: execution.turnID ?? "", result: execution.responseText, error: message,
                        fileDiff: execution.fileDiff, progress: execution.progress
                ), api: api)
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
        if method == "mcpServer/elicitation/request" {
            guard var request = ComputerUseApprovalRequest(
                requestID: requestID,
                params: params,
                timeout: userInputTimeoutSeconds
            ) else {
                do {
                    try client.respond(to: requestID, result: [
                        "action": "cancel", "content": NSNull(), "_meta": NSNull()
                    ])
                } catch {
                    errorMessage = "无法取消不受支持的授权请求：\(error.localizedDescription)"
                }
                return
            }
            if Self.automaticallyApprovesComputerUse(
                permissionID: activePermissionByThreadID[request.threadID]
            ) {
                do {
                    try client.respond(
                        to: request.requestID,
                        result: request.responsePayload(for: .allowSession)
                    )
                    upsertConversationActivity(
                        threadID: request.threadID,
                        id: "computer-use-approval-\(request.id)",
                        title: "完全访问已自动授权电脑控制",
                        text: "当前任务为完全访问，CloudCodex 已自动允许本次会话控制 \(request.applicationName)。",
                        status: "已自动允许"
                    )
                    return
                } catch {
                    request.error = "自动授权失败：\(error.localizedDescription)"
                }
            }
            computerUseApprovalTimeoutTasks.removeValue(forKey: request.id)?.cancel()
            if let index = computerUseApprovalRequests.firstIndex(where: { $0.id == request.id }) {
                computerUseApprovalRequests[index] = request
            } else {
                computerUseApprovalRequests.append(request)
            }
            upsertConversationActivity(
                threadID: request.threadID,
                id: "computer-use-approval-\(request.id)",
                title: "电脑控制需要授权",
                text: "等待确认是否允许 CloudCodex 控制 \(request.applicationName)。",
                status: "待授权"
            )
            let delay = max(0, request.expiresAt.timeIntervalSinceNow)
            computerUseApprovalTimeoutTasks[request.id] = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.expireComputerUseApprovalRequest(request.id)
            }
            return
        }
        guard method == "item/tool/requestUserInput",
              let request = UserInputRequest(requestID: requestID, params: params, timeout: userInputTimeoutSeconds) else { return }
        if let ordinary = AssistantReplyChoices.question(in: conversationMessages(for: request.threadID),
            currentTurnID: request.turnID) {
            dismissedAssistantReplyQuestions[request.threadID, default: []].insert(ordinary.id)
        }
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

    static func automaticallyApprovesComputerUse(permissionID: String?) -> Bool {
        permissionID == ":danger-full-access"
    }

    private func expireComputerUseApprovalRequest(_ requestID: String) {
        guard let request = computerUseApprovalRequests.first(where: { $0.id == requestID }),
              !request.isSubmitting else { return }
        do {
            try client.respond(to: request.requestID, result: request.responsePayload(for: .cancel))
            computerUseApprovalTimeoutTasks.removeValue(forKey: requestID)
            computerUseApprovalRequests.removeAll { $0.id == requestID }
            upsertConversationActivity(
                threadID: request.threadID,
                id: "computer-use-approval-\(request.id)",
                title: "电脑控制授权已取消",
                text: "60 秒内未收到确认，CloudCodex 已取消对 \(request.applicationName) 的控制请求。",
                status: "已取消"
            )
        } catch {
            computerUseApprovalTimeoutTasks.removeValue(forKey: requestID)
            guard let index = computerUseApprovalRequests.firstIndex(where: { $0.id == requestID }) else { return }
            computerUseApprovalRequests[index].error = "自动取消失败：\(error.localizedDescription)"
        }
    }

    private func expireUserInputRequest(_ requestID: String) {
        guard creditUsagePauseReason == nil else { return }
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

    static func isComputerControlItem(_ item: [String: Any]) -> Bool {
        let type = item["type"] as? String ?? ""
        let owner: String
        switch type {
        case "dynamicToolCall": owner = item["namespace"] as? String ?? ""
        case "mcpToolCall": owner = item["server"] as? String ?? ""
        default: return false
        }
        let normalized = owner.lowercased()
        return normalized == "cua_repl" || normalized.contains("computer-use")
    }

    static func isCommandExecutionItem(_ item: [String: Any]) -> Bool {
        item["type"] as? String == "commandExecution"
    }

    static func computerControlNativePipeFailure(_ item: [String: Any]) -> String? {
        guard isComputerControlItem(item),
              (item["status"] as? String)?.lowercased() == "failed" else { return nil }
        let text = toolResultText(item["result"])
        guard text.localizedCaseInsensitiveContains("Sky Computer Use native pipe closed before response")
                || text.localizedCaseInsensitiveContains("native pipe closed before response") else { return nil }
        return "原生界面控制服务在连接目标应用时崩溃。CloudCodex 已停止本轮并暂停领取新任务 60 秒，避免连续闪退；这不是普通的辅助功能授权失败。"
    }

    private static func toolResultText(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? [Any] { return value.map { toolResultText($0) }.joined(separator: "\n") }
        if let value = value as? [String: Any] {
            return ["text", "message", "output", "content"].compactMap { key -> String? in
                let text = toolResultText(value[key])
                return text.isEmpty ? nil : text
            }.joined(separator: "\n")
        }
        return ""
    }

    private func handleComputerControlNativePipeFailure(
        _ message: String,
        threadID: String,
        turnID: String?
    ) {
        guard computerControlNativeFailures[threadID] == nil else { return }
        computerControlNativeFailures[threadID] = message
        computerControlCircuitOpenUntil = Date().addingTimeInterval(60)
        if remoteExecutions[threadID] != nil {
            remoteControlStatus = "界面控制服务崩溃，已停止本轮并暂停领取新任务 60 秒"
        }
        guard let activeTurnID = activeTurnIDsByThread[threadID],
              turnID == nil || turnID == activeTurnID else { return }
        Task { [weak self] in
            try? await self?.client.interruptTurn(threadID: threadID, turnID: activeTurnID)
        }
    }

    private func scheduleComputerControlTimeout(
        item: [String: Any],
        threadID: String,
        turnID: String?
    ) {
        guard Self.isComputerControlItem(item), let itemID = item["id"] as? String else { return }
        let key = PendingItemKey(threadID: threadID, itemID: itemID)
        computerControlTimeoutTasks.removeValue(forKey: key)?.cancel()
        computerControlTimeoutTasks[key] = Task { [weak self] in
            guard let self else { return }
            let nanoseconds = UInt64(max(0, self.computerControlTimeoutSeconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self.expireComputerControl(key: key, turnID: turnID)
        }
    }

    private func cancelComputerControlTimeout(itemID: String, threadID: String) {
        let key = PendingItemKey(threadID: threadID, itemID: itemID)
        computerControlTimeoutTasks.removeValue(forKey: key)?.cancel()
    }

    private func cancelComputerControlTimeouts(threadID: String) {
        let keys = computerControlTimeoutTasks.keys.filter { $0.threadID == threadID }
        keys.forEach { computerControlTimeoutTasks.removeValue(forKey: $0)?.cancel() }
    }

    private func scheduleCommandInactivityTimeout(
        item: [String: Any],
        threadID: String,
        turnID: String?
    ) {
        guard Self.isCommandExecutionItem(item), let itemID = item["id"] as? String else { return }
        refreshCommandInactivityTimeout(itemID: itemID, threadID: threadID, turnID: turnID)
    }

    private func refreshCommandInactivityTimeout(
        itemID: String,
        threadID: String,
        turnID: String?
    ) {
        let key = PendingItemKey(threadID: threadID, itemID: itemID)
        commandInactivityTimeoutTasks.removeValue(forKey: key)?.cancel()
        commandInactivityTimeoutTasks[key] = Task { [weak self] in
            guard let self else { return }
            let nanoseconds = UInt64(max(0, self.commandInactivityTimeoutSeconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            await self.expireCommandExecution(key: key, turnID: turnID)
        }
    }

    private func cancelCommandInactivityTimeout(itemID: String, threadID: String) {
        let key = PendingItemKey(threadID: threadID, itemID: itemID)
        commandInactivityTimeoutTasks.removeValue(forKey: key)?.cancel()
    }

    private func cancelCommandInactivityTimeouts(threadID: String) {
        let keys = commandInactivityTimeoutTasks.keys.filter { $0.threadID == threadID }
        keys.forEach { commandInactivityTimeoutTasks.removeValue(forKey: $0)?.cancel() }
    }

    private func expireCommandExecution(key: PendingItemKey, turnID: String?) async {
        commandInactivityTimeoutTasks.removeValue(forKey: key)
        var history = conversationMessages(for: key.threadID)
        guard let index = history.firstIndex(where: { $0.id == key.itemID && $0.isStreaming }) else { return }

        history[index].isStreaming = false
        history[index].activityStatus = "无输出超时"
        history[index].completedAt = Date()
        let minutes = max(1, Int(commandInactivityTimeoutSeconds / 60))
        let timeoutText = "执行命令连续 \(minutes) 分钟没有任何输出，CloudCodex 已自动停止本轮任务，避免会话长期卡死。已完成的文件修改仍会保留。"
        history[index].text = history[index].text.isEmpty ? timeoutText : history[index].text + "\n\n" + timeoutText
        storeMessages(history, for: key.threadID)

        guard locallyRunningThreadIDs.contains(key.threadID),
              let activeTurnID = activeTurnIDsByThread[key.threadID],
              turnID == nil || turnID == activeTurnID else { return }

        do {
            try await client.interruptTurn(threadID: key.threadID, turnID: activeTurnID)
        } catch {
            // A wedged child process may prevent app-server from answering the
            // interrupt request. Restart it as the bounded fallback so both the
            // shell process and the optimistic running state are released.
            if client.connected {
                forceStoppingThreadID = key.threadID
                client.terminateUnresponsiveServer()
            }
        }

        markLocalTurnInterrupted(
            threadID: key.threadID,
            message: timeoutText,
            title: "命令无输出超时",
            status: "已停止"
        )
        let willContinue = scheduleCommandTimeoutContinuation(
            threadID: key.threadID,
            timeoutDescription: timeoutText
        )
        clearLocalTurn(key.threadID)
        setThreadRunning(key.threadID, running: false)
        threadOutcomes[key.threadID] = willContinue ? .running : .interrupted
        if selectedThreadID == key.threadID { isExternalThreadProcessing = false }
    }

    @discardableResult
    private func scheduleCommandTimeoutContinuation(
        threadID: String,
        timeoutDescription: String
    ) -> Bool {
        guard creditUsagePauseReason == nil else { return false }
        if waitingMessages.contains(where: { $0.threadID == threadID && $0.isAutomaticRecovery }) {
            return true
        }

        let attempt = commandTimeoutRecoveryAttemptsByThread[threadID, default: 0] + 1
        commandTimeoutRecoveryAttemptsByThread[threadID] = attempt
        guard attempt <= Self.maximumAutomaticCommandTimeoutRecoveries else {
            upsertConversationActivity(
                threadID: threadID,
                id: "command-timeout-recovery-limit",
                title: "自动续跑已暂停",
                text: "同一任务已连续 \(Self.maximumAutomaticCommandTimeoutRecoveries) 次因命令无输出而超时。为避免无限循环和持续消耗额度，CloudCodex 已暂停自动续跑；请检查命令或网络环境后手动继续。",
                status: "需要处理"
            )
            return false
        }

        var settings = turnLaunchSettingsByThreadID[threadID] ?? TurnLaunchSettings(
            model: nil,
            effort: nil,
            permissions: activePermissionByThreadID[threadID],
            serviceTier: threadSummaries[threadID]?.serviceTier,
            approvalPolicy: nil,
            approvalsReviewer: nil
        )
        if let metadata = liveTurnMetadataByThread[threadID] {
            settings.model = metadata.model ?? settings.model
            settings.effort = metadata.reasoningEffort ?? settings.effort
        }
        let continuation = """
        上一轮出现命令无输出超时，但原任务尚未完成。请从当前会话和工作区现状自动继续，直到完整交付原任务。

        恢复要求：
        1. 先检查超时命令是否其实已经产生了文件或完成了部分工作，不要重复已经完成的修改或外部操作。
        2. 不要原样重复刚才可能永久等待的命令；对 curl 等网络命令增加连接和总时限，对其他命令使用有界等待、输出进度、拆分步骤或可靠替代方案。
        3. 保持用户原始任务范围，继续完成剩余实现和相应验证。不要只解释超时，也不要把“已停止”当作最终结果。
        4. 若某项确实需要用户提供新信息或授权，明确说明唯一阻塞点；否则自主继续到最终结果。

        本次恢复原因：\(timeoutDescription)
        这是第 \(attempt) 次自动恢复。
        """
        let recovery = WaitingMessage(
            threadID: threadID,
            text: continuation,
            attachments: [],
            model: settings.model,
            effort: settings.effort,
            permissions: settings.permissions,
            serviceTier: settings.serviceTier,
            isAutomaticRecovery: true
        )
        if let firstForThread = waitingMessages.firstIndex(where: { $0.threadID == threadID }) {
            waitingMessages.insert(recovery, at: firstForThread)
        } else {
            waitingMessages.append(recovery)
        }
        upsertConversationActivity(
            threadID: threadID,
            id: "command-timeout-recovery-\(attempt)",
            title: "命令超时，准备自动续跑",
            text: "CloudCodex 将在会话释放后自动发起第 \(attempt) 次恢复，先核对现状并换用有界命令继续完成原任务。",
            status: "等待继续"
        )
        startWaitingMonitorIfNeeded()
        return true
    }

    private func expireComputerControl(key: PendingItemKey, turnID: String?) async {
        computerControlTimeoutTasks.removeValue(forKey: key)
        var history = conversationMessages(for: key.threadID)
        guard let index = history.firstIndex(where: { $0.id == key.itemID && $0.isStreaming }) else { return }

        history[index].isStreaming = false
        history[index].activityStatus = "超时"
        history[index].completedAt = Date()
        let timeoutText = "电脑控制步骤超过 \(Int(computerControlTimeoutSeconds)) 秒没有返回，CloudCodex 已自动停止本轮任务。可直接继续并让 Codex 重新连接微信开发者工具。"
        history[index].text = history[index].text.isEmpty ? timeoutText : history[index].text + "\n\n" + timeoutText
        storeMessages(history, for: key.threadID)

        guard locallyRunningThreadIDs.contains(key.threadID),
              let activeTurnID = activeTurnIDsByThread[key.threadID],
              turnID == nil || turnID == activeTurnID else { return }

        do {
            try await client.interruptTurn(threadID: key.threadID, turnID: activeTurnID)
        } catch {
            // A wedged computer-control request can also prevent turn/interrupt
            // from being answered. Restart the local app-server as the bounded
            // fallback; completed file edits remain on disk.
            if client.connected {
                forceStoppingThreadID = key.threadID
                client.terminateUnresponsiveServer()
            }
        }

        markLocalTurnInterrupted(
            threadID: key.threadID,
            message: timeoutText,
            title: "电脑控制超时",
            status: "已停止"
        )
        clearLocalTurn(key.threadID)
        setThreadRunning(key.threadID, running: false)
        threadOutcomes[key.threadID] = .interrupted
        if selectedThreadID == key.threadID { isExternalThreadProcessing = false }
    }

    func handleEvent(_ method: String, _ params: [String: Any]) {
        if customModelProvider.enabled,
           ["turn/started", "turn/completed", "thread/tokenUsage/updated"].contains(method) {
            var updated = providerUsage
            let threadID = params["threadId"] as? String ?? ""
            let turnID = params["turnId"] as? String ?? (params["turn"] as? [String: Any])?["id"] as? String
            let configuration = client.usageProvider(threadID: threadID, turnID: turnID) ?? customModelProvider
            if updated.consume(method, params: params, configuration: configuration),
               let data = try? JSONEncoder().encode(updated) {
                providerUsage = updated
                remoteDefaults.set(data, forKey: ProviderUsageLedger.defaultsKey)
            }
        }
        if method == "account/rateLimits/updated" {
            guard !isSwitchingModelProvider else { return }
            // Sparse notifications can still carry a balance decrease or an
            // exhausted window. Confirm the remaining fields with a full read.
            observeCreditUsage(AccountOverview.parse(params))
            requestCreditUsageRefresh()
            return
        }
        if method == "skills/changed" {
            guard showingPersonalSkills || !personalSkills.isEmpty else { return }
            Task { await refreshPersonalSkills(forceReload: true) }
            return
        }
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
        let capacityFailure = Self.capacityFailure(method: method, params: params)
        if method == "serverRequest/resolved",
           let rawID = params["requestId"], let requestID = AppServerRequestID(rawID) {
            if let resolved = userInputRequests.first(where: { $0.id == requestID.stableID }) {
                userInputTimeoutTasks.removeValue(forKey: requestID.stableID)?.cancel()
                userInputRequests.removeAll { $0.id == requestID.stableID }
                upsertConversationActivity(threadID: eventThreadID,
                    id: "user-input-\(resolved.itemID)", title: "输入请求已结束",
                    text: "该请求已由 Codex 处理或随任务状态变化而取消。", status: "已处理")
            }
            if let resolved = computerUseApprovalRequests.first(where: { $0.id == requestID.stableID }) {
                computerUseApprovalTimeoutTasks.removeValue(forKey: requestID.stableID)?.cancel()
                computerUseApprovalRequests.removeAll { $0.id == requestID.stableID }
                upsertConversationActivity(threadID: eventThreadID,
                    id: "computer-use-approval-\(resolved.id)", title: "电脑控制授权已结束",
                    text: "该授权请求已由 Codex 处理或随任务状态变化而取消。", status: "已处理")
            }
        }
        if method == "turn/started" || method == "turn/completed" || method == "error" {
            turnEventRevision[eventThreadID, default: 0] += 1
        }
        if method == "thread/settings/updated",
           let settings = params["threadSettings"] as? [String: Any],
           settings.keys.contains("serviceTier") {
            applyThreadServiceTier(settings["serviceTier"] as? String, threadID: eventThreadID)
        }
        if method == "thread/name/updated", params.keys.contains("threadName") {
            applyThreadName(params["threadName"] as? String, threadID: eventThreadID)
        }
        if method == "turn/completed" { flushPendingDeltas() }
        if method == "turn/started" {
            composerPredictions = composerPredictions.filter { $0.key.threadID != eventThreadID }
            let turn = params["turn"] as? [String: Any]
            // External turns have no trustworthy composer settings. Leave the
            // badge unknown until this exact turn's persisted context is read.
            setLocalTurnRunning(eventThreadID, turnID: turn?["id"] as? String)
            setThreadRunning(eventThreadID, running: true)
            if creditUsagePauseReason != nil { pauseConversationsForCreditProtection() }
        } else if method == "turn/completed" {
            cancelComputerControlTimeouts(threadID: eventThreadID)
            let turn = params["turn"] as? [String: Any]
            if let incomingID = turn?["id"] as? String,
               let activeID = activeTurnIDsByThread[eventThreadID], incomingID != activeID { return }
            clearLocalTurn(eventThreadID)
            setThreadRunning(eventThreadID, running: false)
            if let status = turn?["status"] as? String {
                let hasPendingCommandRecovery = waitingMessages.contains {
                    $0.threadID == eventThreadID && $0.isAutomaticRecovery
                }
                threadOutcomes[eventThreadID] = hasPendingCommandRecovery || capacityFailure != nil
                    ? .running
                    : ConversationOutcome(rawValue: status)
                if status == "completed", let turnID = turn?["id"] as? String {
                    commandTimeoutRecoveryAttemptsByThread.removeValue(forKey: eventThreadID)
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
            let terminal = method == "turn/completed"
                || (method == "error" && params["willRetry"] as? Bool != true)
            if terminal, capacityFailure == nil {
                computerControlNativeFailures.removeValue(forKey: eventThreadID)
                liveTurnMetadataByThread.removeValue(forKey: eventThreadID)
                turnLaunchSettingsByThreadID.removeValue(forKey: eventThreadID)
                cancelCapacityRetry(threadID: eventThreadID)
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
            scheduleComputerControlTimeout(
                item: item,
                threadID: eventThreadID,
                turnID: params["turnId"] as? String
            )
            scheduleCommandInactivityTimeout(
                item: item,
                threadID: eventThreadID,
                turnID: params["turnId"] as? String
            )
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
        case "turn/diff/updated":
            guard let turnID = params["turnId"] as? String,
                  let diff = params["diff"] as? String else { return }
            let changes = ConversationFileChange.parseUnifiedDiff(diff)
            guard !changes.isEmpty else { return }
            upsertActivity(
                id: "turn-diff-\(turnID)",
                kind: .file,
                title: "文件修改汇总",
                text: changes.map(\.path).joined(separator: "\n"),
                status: "进行中",
                isStreaming: true,
                fileChanges: changes
            )
        case "item/commandExecution/outputDelta":
            guard let delta = params["delta"] as? String else { return }
            let itemID = params["itemId"] as? String ?? "command"
            if !delta.isEmpty {
                refreshCommandInactivityTimeout(
                    itemID: itemID,
                    threadID: eventThreadID,
                    turnID: params["turnId"] as? String
                )
            }
            enqueueActivityDelta(
                id: itemID,
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
            let parsedChanges = changes.compactMap(ConversationFileChange.init(json:))
            let paths = parsedChanges.map(\.path)
            upsertActivity(
                id: params["itemId"] as? String ?? "file-change",
                kind: .file,
                title: "修改文件",
                text: paths.isEmpty ? "正在生成并应用文件补丁…" : paths.joined(separator: "\n"),
                status: "进行中",
                isStreaming: true,
                fileChanges: parsedChanges
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
            if let itemID = item["id"] as? String {
                cancelComputerControlTimeout(itemID: itemID, threadID: eventThreadID)
                cancelCommandInactivityTimeout(itemID: itemID, threadID: eventThreadID)
            }
            if let message = Self.computerControlNativePipeFailure(item) {
                handleComputerControlNativePipeFailure(
                    message,
                    threadID: eventThreadID,
                    turnID: params["turnId"] as? String
                )
            }
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
            if let capacityFailure {
                scheduleCapacityRetry(
                    threadID: eventThreadID,
                    failedTurnID: turn?["id"] as? String ?? "current",
                    message: capacityFailure
                )
                break
            }
            if waitingMessages.contains(where: { $0.threadID == eventThreadID && $0.isAutomaticRecovery }) {
                finishTurnProgress(status: "等待自动继续")
                break
            }
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
            if let capacityFailure, !retrying {
                scheduleCapacityRetry(
                    threadID: eventThreadID,
                    failedTurnID: turnID,
                    message: capacityFailure
                )
                break
            }
            upsertActivity(id: "connection-notice-\(turnID)", kind: .warning,
                           title: retrying ? "连接中断，正在重试" : "任务发生错误",
                           text: message, status: retrying ? "重连中" : "失败",
                           isStreaming: retrying)
            if retrying { break }
            cancelComputerControlTimeouts(threadID: eventThreadID)
            clearLocalTurn(eventThreadID)
            if selectedThreadID == eventThreadID { isExternalThreadProcessing = false }
            setThreadRunning(eventThreadID, running: false)
            if waitingMessages.contains(where: { $0.threadID == eventThreadID && $0.isAutomaticRecovery }) {
                finishTurnProgress(status: "等待自动继续")
                threadOutcomes[eventThreadID] = .running
                break
            }
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

    private static func capacityFailure(method: String, params: [String: Any]) -> String? {
        let error: [String: Any]?
        switch method {
        case "turn/completed":
            guard let turn = params["turn"] as? [String: Any],
                  turn["status"] as? String == "failed" else { return nil }
            error = turn["error"] as? [String: Any]
        case "error":
            guard params["willRetry"] as? Bool != true else { return nil }
            error = params["error"] as? [String: Any]
        default:
            return nil
        }
        guard CapacityRetryPolicy.isRetryable(error: error) else { return nil }
        return error?["message"] as? String ?? "所选模型当前容量不足。"
    }

    private func scheduleCapacityRetry(threadID: String, failedTurnID: String, message: String) {
        guard creditUsagePauseReason == nil else { return }
        if capacityRetryStates[threadID]?.failedTurnID == failedTurnID,
           capacityRetryTasks[threadID] != nil,
           let state = capacityRetryStates[threadID] {
            setLocalTurnRunning(threadID, permissions: state.settings.permissions)
            setThreadRunning(threadID, running: true)
            threadOutcomes[threadID] = .running
            return
        }
        capacityRetryTasks.removeValue(forKey: threadID)?.cancel()

        var settings = turnLaunchSettingsByThreadID[threadID] ?? TurnLaunchSettings(
            model: nil,
            effort: nil,
            permissions: activePermissionByThreadID[threadID],
            serviceTier: threadSummaries[threadID]?.serviceTier,
            approvalPolicy: nil,
            approvalsReviewer: nil
        )
        if let metadata = liveTurnMetadataByThread[threadID] {
            settings.model = metadata.model ?? settings.model
            settings.effort = metadata.reasoningEffort ?? settings.effort
        }
        let attempt = (capacityRetryStates[threadID]?.attempt ?? 0) + 1
        let delay = CapacityRetryPolicy.delay(attempt: attempt)
        let state = CapacityRetryState(
            attempt: attempt,
            failedTurnID: failedTurnID,
            settings: settings
        )
        capacityRetryStates[threadID] = state
        persistCapacityRetries()
        turnLaunchSettingsByThreadID[threadID] = settings
        setLocalTurnRunning(threadID, permissions: settings.permissions)
        setThreadRunning(threadID, running: true)
        threadOutcomes[threadID] = .running
        if selectedThreadID == threadID { isExternalThreadProcessing = false }
        updateCapacityRetryActivity(
            threadID: threadID,
            failedTurnID: failedTurnID,
            title: "模型繁忙，持续重试",
            text: "第 \(attempt) 次检测到模型容量不足：\(message)\n约 \(max(1, Int(delay.rounded()))) 秒后自动继续。现有回复、执行过程、错误记录和文件修改都会保留。",
            status: "等待重试",
            isStreaming: true
        )
        if selectedThreadID == threadID { finishTurnProgress(status: "等待重试") }

        capacityRetryTasks[threadID] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(delay, 0.01) * 1_000_000_000))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            await self.performCapacityRetry(threadID: threadID, expectedAttempt: attempt)
        }
    }

    private func performCapacityRetry(threadID: String, expectedAttempt: Int) async {
        guard creditUsagePauseReason == nil else { return }
        guard let state = capacityRetryStates[threadID], state.attempt == expectedAttempt else { return }
        capacityRetryTasks.removeValue(forKey: threadID)
        updateCapacityRetryActivity(
            threadID: threadID,
            failedTurnID: state.failedTurnID,
            title: "正在自动重试",
            text: "正在发起第 \(state.attempt) 次继续请求。此前已完成的修改和外部操作不会被撤回，Codex 会先核对现状再继续未完成部分。",
            status: "重试中",
            isStreaming: true
        )
        let continuation = "上一轮因所选模型临时容量不足而中断。请从当前会话和工作区现状继续完成原任务：先核对已经完成的内容，不要重复文件修改、提交、推送、部署、发送或其他已经执行过的外部操作；只补齐未完成部分并给出最终结果。"
        do {
            try await client.resumeThread(threadID)
            rememberTurnLaunch(
                threadID: threadID,
                model: state.settings.model,
                effort: state.settings.effort,
                permissions: state.settings.permissions,
                serviceTier: state.settings.serviceTier,
                approvalPolicy: state.settings.approvalPolicy,
                approvalsReviewer: state.settings.approvalsReviewer
            )
            let turnID = try await client.startTurn(
                threadID: threadID,
                text: continuation,
                attachments: [],
                model: state.settings.model,
                effort: state.settings.effort,
                permissions: state.settings.permissions,
                serviceTier: state.settings.serviceTier,
                approvalPolicy: state.settings.approvalPolicy,
                approvalsReviewer: state.settings.approvalsReviewer
            )
            setLocalTurnRunning(threadID, turnID: turnID, permissions: state.settings.permissions)
            setThreadRunning(threadID, running: true)
        } catch {
            guard capacityRetryStates[threadID]?.attempt == expectedAttempt else { return }
            scheduleCapacityRetry(
                threadID: threadID,
                failedTurnID: "\(state.failedTurnID)-submit-\(expectedAttempt)",
                message: "自动继续请求暂时未能发出：\(error.localizedDescription)"
            )
        }
    }

    @discardableResult
    private func cancelCapacityRetry(threadID: String) -> CapacityRetryState? {
        let state = capacityRetryStates.removeValue(forKey: threadID)
        capacityRetryTasks.removeValue(forKey: threadID)?.cancel()
        if state != nil { persistCapacityRetries() }
        return state
    }

    private func persistCapacityRetries() {
        if capacityRetryStates.isEmpty {
            remoteDefaults.removeObject(forKey: capacityRetriesKey)
        } else if let data = try? JSONEncoder().encode(capacityRetryStates) {
            remoteDefaults.set(data, forKey: capacityRetriesKey)
        }
    }

    private func resumePersistedCapacityRetries() {
        for (threadID, state) in capacityRetryStates where capacityRetryTasks[threadID] == nil {
            scheduleCapacityRetry(
                threadID: threadID,
                failedTurnID: "\(state.failedTurnID)-app-restart-\(state.attempt)",
                message: "CloudCodex 已恢复上次未结束的模型容量重试。"
            )
        }
    }

    private func updateCapacityRetryActivity(
        threadID: String,
        failedTurnID: String,
        title: String,
        text: String,
        status: String,
        isStreaming: Bool
    ) {
        var rows = conversationMessages(for: threadID)
        let id = "capacity-retry-\(failedTurnID)"
        if let index = rows.firstIndex(where: { $0.id == id }) {
            rows[index].activityTitle = title
            rows[index].text = text
            rows[index].activityStatus = status
            rows[index].isStreaming = isStreaming
            rows[index].timestamp = Date()
        } else {
            rows.append(.init(
                id: id,
                role: .activity,
                text: text,
                isStreaming: isStreaming,
                activityKind: .warning,
                activityTitle: title,
                activityStatus: status,
                timestamp: Date(),
                turnID: failedTurnID == "current" ? nil : failedTurnID
            ))
        }
        storeMessages(rows, for: threadID)
    }

    var selectedHasCapacityRetry: Bool {
        selectedThreadID.map { capacityRetryStates[$0] != nil } ?? false
    }

    func capacityRetryAttempt(for threadID: String) -> Int? {
        capacityRetryStates[threadID]?.attempt
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
            let parsedChanges = changes.compactMap(ConversationFileChange.init(json:))
            let paths = parsedChanges.map { "\($0.kind.label)  \($0.path)" }
            upsertActivity(id: id, kind: .file, title: "文件变更",
                           text: paths.isEmpty ? "正在处理工作区文件…" : paths.joined(separator: "\n"),
                           status: runningStatus, isStreaming: !completed,
                           fileChanges: parsedChanges)
        case "mcpToolCall":
            let server = item["server"] as? String ?? "MCP"
            let tool = item["tool"] as? String ?? "工具"
            let status = item["status"] as? String ?? (completed ? "completed" : "inProgress")
            let result = Self.toolResultText(item["result"])
            let detail = [jsonPreview(item["arguments"]), result].filter { !$0.isEmpty }.joined(separator: "\n\n")
            upsertActivity(id: id, kind: .tool, title: "调用 \(server) · \(tool)",
                           text: detail, status: localizedStatus(status),
                           isStreaming: !completed)
        case "dynamicToolCall":
            let tool = item["tool"] as? String ?? "工具"
            let namespace = item["namespace"] as? String
            let title = [namespace, tool].compactMap { $0 }.joined(separator: " · ")
            let status = item["status"] as? String ?? (completed ? "completed" : "inProgress")
            let result = Self.toolResultText(item["result"])
            let detail = [jsonPreview(item["arguments"]), result].filter { !$0.isEmpty }.joined(separator: "\n\n")
            upsertActivity(id: id, kind: .tool, title: "调用 \(title)",
                           text: detail, status: localizedStatus(status),
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
        case "collabAgentToolCall", "subAgentActivity":
            guard let presentation = CollaborationItemPresentation.parse(item, completed: completed) else { return }
            upsertActivity(
                id: id,
                kind: .collaboration,
                title: presentation.title,
                text: presentation.text,
                status: presentation.status,
                isStreaming: presentation.isStreaming,
                collaborationChildTasks: presentation.childTasks
            )
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
        isStreaming: Bool,
        collaborationChildTasks: [CollaborationChildTask] = [],
        fileChanges: [ConversationFileChange] = []
    ) {
        let clipped = clippedActivityText(text)
        if let index = eventMessages.firstIndex(where: { $0.id == id }) {
            eventMessages[index].activityKind = kind
            eventMessages[index].activityTitle = title
            if !clipped.isEmpty { eventMessages[index].text = clipped }
            eventMessages[index].activityStatus = status
            eventMessages[index].isStreaming = isStreaming
            if isStreaming, eventMessages[index].startedAt == nil {
                eventMessages[index].startedAt = Date()
            }
            if !isStreaming, eventMessages[index].completedAt == nil {
                eventMessages[index].completedAt = Date()
            }
            if !collaborationChildTasks.isEmpty {
                eventMessages[index].collaborationChildTasks = collaborationChildTasks
            }
            if !fileChanges.isEmpty { eventMessages[index].fileChanges = fileChanges }
        } else {
            eventMessages.append(.init(id: id, role: .activity, text: clipped, isStreaming: isStreaming,
                                  activityKind: kind, activityTitle: title, activityStatus: status,
                                  startedAt: Date(), completedAt: isStreaming ? nil : Date(),
                                  turnID: (eventThreadID ?? selectedThreadID).flatMap { activeTurnIDsByThread[$0] },
                                  collaborationChildTasks: collaborationChildTasks,
                                  fileChanges: fileChanges))
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
        // Turn identity is independent of whether model metadata is already
        // available. Keeping this assignment behind the metadata lookup can
        // leave a local bubble unresolved and let a later queued turn claim it.
        if message.turnID == nil { message.turnID = activeTurnIDsByThread[threadID] }
        guard let metadata = liveTurnMetadataByThread[threadID] else { return }
        message.model = metadata.model
        message.reasoningEffort = metadata.reasoningEffort
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
