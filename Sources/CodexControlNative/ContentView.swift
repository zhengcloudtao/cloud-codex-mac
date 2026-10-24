import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum MainColumnLayout {
    static let workspaceDefault = 240.0
    static let workspaceRange = 220.0 ... 380.0
    static let threadListDefault = 330.0
    static let threadListRange = 300.0 ... 460.0

    static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

enum WorkspaceCategoryDisclosureState {
    static let uncategorizedKey = "__uncategorized__"

    static func key(for categoryID: String?) -> String {
        categoryID ?? uncategorizedKey
    }

    static func decode(_ rawValue: String) -> Set<String> {
        Set(rawValue.split(separator: "\n").map(String.init))
    }

    static func encode(_ collapsedKeys: Set<String>) -> String {
        collapsedKeys.sorted().joined(separator: "\n")
    }
}

enum CommandInactivityTimeoutInput {
    static let validRange = 1 ... 60

    static func minutes(from text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let minutes = Int(trimmed),
              validRange.contains(minutes) else { return nil }
        return minutes
    }
}

private struct ColumnResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    let defaultWidth: Double
    let accessibilityName: String

    @State private var dragStartWidth: Double?
    @State private var isHovering = false
    @State private var isDragging = false

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.clear
                .contentShape(Rectangle())

            Rectangle()
                .fill(Color.accentColor.opacity(isHovering || isDragging ? 0.85 : 0.18))
                .frame(width: isHovering || isDragging ? 2 : 1)
        }
        // This handle occupies its own strip beside the scroll view. An
        // overlay here would intercept the native scrollbar's mouse events.
        .frame(width: 8)
        .contentShape(Rectangle())
        .zIndex(1_000)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartWidth == nil {
                        dragStartWidth = MainColumnLayout.clamped(width, to: range)
                    }
                    isDragging = true
                    let start = dragStartWidth ?? width
                    width = MainColumnLayout.clamped(start + Double(value.translation.width), to: range)
                }
                .onEnded { _ in
                    dragStartWidth = nil
                    isDragging = false
                }
        )
        .onTapGesture(count: 2) {
            width = MainColumnLayout.clamped(defaultWidth, to: range)
        }
        .accessibilityElement()
        .accessibilityLabel(accessibilityName)
        .accessibilityValue("\(Int(MainColumnLayout.clamped(width, to: range).rounded())) 点")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                width = MainColumnLayout.clamped(width + 20, to: range)
            case .decrement:
                width = MainColumnLayout.clamped(width - 20, to: range)
            @unknown default:
                break
            }
        }
        .help("左右拖动调整宽度，双击恢复默认宽度")
    }
}

private struct DetailColumnSizeReader: NSViewRepresentable {
    @Binding var workspaceWidth: Double
    @Binding var threadListWidth: Double

    func makeNSView(context: Context) -> DetailColumnSizeProbeView {
        let view = DetailColumnSizeProbeView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: DetailColumnSizeProbeView, context: Context) {
        update(nsView)
    }

    static func dismantleNSView(_ nsView: DetailColumnSizeProbeView, coordinator: ()) {
        nsView.disconnect()
    }

    private func update(_ view: DetailColumnSizeProbeView) {
        view.onLeadingColumnWidthsChanged = { newWorkspaceWidth, newThreadListWidth in
            if abs(workspaceWidth - newWorkspaceWidth) > 0.5 {
                workspaceWidth = MainColumnLayout.clamped(
                    newWorkspaceWidth,
                    to: MainColumnLayout.workspaceRange
                )
            }
            if abs(threadListWidth - newThreadListWidth) > 0.5 {
                threadListWidth = MainColumnLayout.clamped(
                    newThreadListWidth,
                    to: MainColumnLayout.threadListRange
                )
            }
        }
        view.connectWhenReady()
    }
}

final class DetailColumnSizeProbeView: NSView {
    private(set) var bridgeRepairCount = 0
    var onLeadingColumnWidthsChanged: ((Double, Double) -> Void)?
    private weak var observedColumn: NSView?
    private weak var observedSplitView: NSSplitView?
    private var observationTokens: [NSObjectProtocol] = []

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        connectWhenReady()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        connectWhenReady()
    }

    override func layout() {
        super.layout()
        // The native inspector owns its two-pane live-resize transaction.
        // Touching bridge frames from this callback makes AppKit lay out the
        // conversation twice for every mouse movement and visibly shakes it.
        if observedSplitView?.arrangedSubviews.count != 2 {
            fillDetailPath()
        }
    }

    func connectWhenReady() {
        DispatchQueue.main.async { [weak self] in self?.connect() }
    }

    func disconnect() {
        observationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        observationTokens.removeAll()
        observedColumn = nil
        observedSplitView = nil
    }

    deinit {
        disconnect()
    }

    private func connect() {
        var candidate: NSView? = self
        var fallbackColumn: NSView?
        while let current = candidate {
            if let splitView = current.superview as? NSSplitView, splitView.isVertical {
                fallbackColumn = fallbackColumn ?? current
                // When the browser is open, SwiftUI's native inspector adds a
                // two-pane split inside NavigationSplitView's detail column.
                // Observe that live conversation pane directly. Walking on to
                // the outer three-column split makes fillDetailPath expand the
                // conversation across the inspector while AppKit is dragging
                // the opposite direction, which is the visible left-side
                // shaking captured in the screen recording.
                if splitView.arrangedSubviews.count == 2,
                   splitView.arrangedSubviews.first === current {
                    // The native inspector already sizes this pane correctly.
                    // Remember its structure only so layout() knows not to run
                    // the three-column bridge repair during live dragging.
                    if observedColumn !== current || observedSplitView !== splitView {
                        disconnect()
                        observedColumn = current
                        observedSplitView = splitView
                    }
                    return
                }
                if splitView.arrangedSubviews.count == 3,
                   let detailColumn = splitView.arrangedSubviews.last {
                    observe(column: detailColumn, splitView: splitView)
                    return
                }
            }
            candidate = current.superview
        }
        if let fallbackColumn, let splitView = fallbackColumn.superview as? NSSplitView {
            observe(column: fallbackColumn, splitView: splitView)
        }
    }

    private func observe(column: NSView, splitView: NSSplitView) {
        guard observedColumn !== column else {
            reportSize()
            return
        }
        disconnect()
        observedColumn = column
        observedSplitView = splitView
        column.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        observationTokens.append(center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: column,
            queue: .main
        ) { [weak self] _ in self?.reportSize() })
        observationTokens.append(center.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: splitView,
            queue: .main
        ) { [weak self, weak splitView] _ in
            self?.reportSize()
            if let splitView {
                self?.reportLeadingColumnWidths(in: splitView)
            }
        })
        if let window {
            observationTokens.append(center.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in self?.reportSize() })
        }
        reportSize()
        reportLeadingColumnWidths(in: splitView)
    }

    private func reportLeadingColumnWidths(in splitView: NSSplitView) {
        guard splitView.arrangedSubviews.count == 3 else { return }
        let workspaceWidth = splitView.arrangedSubviews[0].frame.width
        let threadListWidth = splitView.arrangedSubviews[1].frame.width
        guard workspaceWidth >= MainColumnLayout.workspaceRange.lowerBound - 1,
              threadListWidth >= MainColumnLayout.threadListRange.lowerBound - 1 else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onLeadingColumnWidthsChanged?(workspaceWidth, threadListWidth)
        }
    }

    private func reportSize() {
        guard observedColumn != nil else { return }
        guard observedSplitView?.arrangedSubviews.count != 2 else { return }
        fillDetailPath()
    }

    /// `NavigationSplitView` occasionally resizes its native column wrapper
    /// without resizing one or more SwiftUI/AppKit bridge containers inside
    /// it. Real three-column windows have more bridge layers than isolated
    /// tests, so pin the complete path from this root-background probe to the
    /// split item instead of depending on private class names.
    private func fillDetailPath() {
        guard let observedColumn else { return }
        bridgeRepairCount += 1
        let targetSize = targetColumnSize(for: observedColumn)
        if targetSize.width > observedColumn.bounds.width + 0.5 {
            observedColumn.setFrameSize(targetSize)
        }
        fillSwiftUIBridges(in: observedColumn)
        var current = superview
        while let view = current, view !== observedColumn {
            guard let parent = view.superview else { return }
            view.autoresizingMask.formUnion([.width, .height])
            view.frame = parent.bounds
            current = parent
        }
    }

    private func targetColumnSize(for column: NSView) -> CGSize {
        // A native inspector already keeps both of its panes synchronized
        // during live dragging. Its conversation pane must use the current
        // split width, not the distance from its leading edge to the window's
        // trailing edge (which includes the browser pane).
        if observedSplitView?.arrangedSubviews.count == 2 {
            return column.bounds.size
        }
        guard let contentView = column.window?.contentView else { return column.bounds.size }
        let frameInWindow = column.convert(column.bounds, to: contentView)
        // The leading edge of the detail item remains correct even in the
        // macOS bug where its stored width stops updating. Derive the usable
        // width from that edge to the live window trailing edge.
        let width = max(column.bounds.width, contentView.bounds.maxX - frameInWindow.minX)
        return CGSize(width: width, height: max(column.bounds.height, contentView.bounds.height))
    }

    private func fillSwiftUIBridges(in root: NSView) {
        // A ScrollView's document owns its intrinsic height. Expanding bridge
        // views below the clip view to the detail pane's full bounds truncates
        // long conversations: the scrollbar can reach its reported end while
        // the final message is still hidden behind the composer. Inner bridges
        // still need the live column width, so update only their horizontal
        // geometry and leave every independently measured height untouched.
        for child in root.subviews {
            let parentType = String(describing: type(of: root))
            let childType = String(describing: type(of: child))
            let isSplitItemHost = parentType.contains("NSSplitViewItemViewWrapper")
                && childType.contains("NSHostingView")
            let isSwiftUIPlatformBridge = parentType.contains("NSHostingView")
                && childType.contains("PlatformContainer")
            if isSplitItemHost {
                child.autoresizingMask = [.width, .height]
                child.frame = root.bounds
            } else if isSwiftUIPlatformBridge {
                // The original platform bug is horizontal: the bridge keeps a
                // stale 600-point width while the detail column grows. Preserve
                // its independently measured height so message documents retain
                // their full vertical scroll range.
                child.autoresizingMask = [.width]
                var frame = child.frame
                frame.origin.x = root.bounds.minX
                frame.size.width = root.bounds.width
                child.frame = frame
            }
            fillSwiftUIBridges(in: child)
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var updateController: CloudCodexUpdateController
    @Environment(\.openWindow) private var openWindow
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var filePreview: LocalFilePreviewTarget?
    @State private var detailLayoutRevision = 0
    @State private var showingFavoriteThreads = false
    @State private var showingUnreadThreads = false
    @State private var preferencesTab = 0
    @State private var commandInactivityTimeoutDraft = ""
    @State private var commandInactivityTimeoutInputError: String?
    @FocusState private var isCommandInactivityTimeoutFocused: Bool
    @AppStorage(AppearancePreference.storageKey) private var appearancePreference: AppearancePreference = .system
    @AppStorage(BackgroundPreference.imagePathKey) private var backgroundImagePath = ""
    @AppStorage(BackgroundScope.storageKey) private var backgroundScope: BackgroundScope = .conversation
    @AppStorage(BackgroundPreference.opacityKey) private var backgroundOpacity = BackgroundPreference.defaultOpacity
    @AppStorage(BackgroundPreference.zoomKey) private var backgroundZoom = BackgroundPreference.defaultZoom
    @AppStorage(BackgroundPreference.offsetXKey) private var backgroundOffsetX = 0.0
    @AppStorage(BackgroundPreference.offsetYKey) private var backgroundOffsetY = 0.0
    @AppStorage("cloudcodex.showConversationPreview") private var showConversationPreview = true
    @AppStorage("cloudcodex.showUnreadCompletionDot") private var showUnreadCompletionDot = true
    @AppStorage("cloudcodex.showUnreadDockBadge") private var showUnreadDockBadge = true
    @AppStorage("cloudcodex.workspaceColumnWidth") private var workspaceColumnWidth = MainColumnLayout.workspaceDefault
    @AppStorage("cloudcodex.threadListColumnWidth") private var threadListColumnWidth = MainColumnLayout.threadListDefault
    @AppStorage("cloudcodex.collapsedWorkspaceCategories.v1") private var collapsedWorkspaceCategories = ""
    @AppStorage(SystemMetricsRefreshInterval.storageKey) private var systemMetricsRefreshInterval = SystemMetricsRefreshInterval.fiveSeconds.rawValue
    private let categoryDragPrefix = "cloudcodex-category://"

    @MainActor
    init(initialColumnVisibility: NavigationSplitViewVisibility = .all) {
        self.init(
            initialColumnVisibility: initialColumnVisibility,
            updateController: CloudCodexUpdateController()
        )
    }

    @MainActor
    init(
        initialColumnVisibility: NavigationSplitViewVisibility = .all,
        updateController: CloudCodexUpdateController
    ) {
        _columnVisibility = State(initialValue: initialColumnVisibility)
        _updateController = ObservedObject(wrappedValue: updateController)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let reason = model.creditUsagePauseReason {
                creditUsageProtectionBanner(reason)
                Divider()
            }
        NavigationSplitView(columnVisibility: $columnVisibility) {
            HStack(spacing: 0) {
                folderSidebar
                ColumnResizeHandle(
                    width: $workspaceColumnWidth,
                    range: MainColumnLayout.workspaceRange,
                    defaultWidth: MainColumnLayout.workspaceDefault,
                    accessibilityName: "调整工作区宽度"
                )
            }
                .navigationSplitViewColumnWidth(
                    min: MainColumnLayout.workspaceRange.lowerBound,
                    ideal: renderedWorkspaceColumnWidth,
                    max: MainColumnLayout.workspaceRange.upperBound
                )
        } content: {
            HStack(spacing: 0) {
                threadList
                ColumnResizeHandle(
                    width: $threadListColumnWidth,
                    range: MainColumnLayout.threadListRange,
                    defaultWidth: MainColumnLayout.threadListDefault,
                    accessibilityName: "调整会话列表宽度"
                )
            }
                .navigationSplitViewColumnWidth(
                    min: MainColumnLayout.threadListRange.lowerBound,
                    ideal: renderedThreadListColumnWidth,
                    max: MainColumnLayout.threadListRange.upperBound
                )
        } detail: {
            // NavigationSplitView can give the detail hosting container its
            // final width while leaving the SwiftUI root at its 600-point
            // ideal size. Turn that container size into an exact proposal so
            // the conversation and scrollbar grow during live resizing.
            BrowserConversationLayout(browser: model.browser, threadID: model.selectedThreadID) { width in
                conversation(explicitWidth: width)
                // This probe must be INSIDE the inspector's conversation pane.
                // Outside BrowserConversationLayout its ancestor chain skips
                // the inspector, so it mistakenly repairs the whole detail
                // column while the native divider is resizing that pane.
                .background(
                    DetailColumnSizeReader(
                        workspaceWidth: $workspaceColumnWidth,
                        threadListWidth: $threadListColumnWidth
                    )
                        // Selecting a conversation replaces several SwiftUI/AppKit
                        // bridge views without resizing the window. Recreate the
                        // native probe so it connects to the new detail hierarchy
                        // immediately instead of waiting for the user's first drag.
                        .id(detailLayoutRevision)
                )
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // When the leading columns are hidden, the conversation must reclaim
        // their width immediately. The balanced style preserves the old detail
        // column width and leaves a large blank strip on the right.
        .navigationSplitViewStyle(.prominentDetail)
        .overlay {
            if !backgroundImagePath.isEmpty, backgroundScope == .entireWindow {
                PersonalBackgroundImage(
                    path: backgroundImagePath,
                    opacity: backgroundOpacity,
                    zoom: backgroundZoom,
                    offsetX: backgroundOffsetX,
                    offsetY: backgroundOffsetY
                )
            }
        }
        }
        .toolbar { toolbar }
        .environment(\.openURL, OpenURLAction { url in
            if ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let threadID = model.selectedThreadID {
                do {
                    _ = try BrowserTool.url(url.absoluteString)
                    let tab = try model.browser.create(threadID: threadID)
                    try tab.navigate(url.absoluteString)
                    // Opening a link is an explicit user request to view it.
                    model.browser.show(threadID: threadID)
                } catch { model.errorMessage = error.localizedDescription }
                return .handled
            }
            guard let target = LocalFilePreviewTarget.resolve(url, cwd: model.selectedThread?.cwd ?? model.selectedFolder) else {
                return .systemAction
            }
            filePreview = target
            return .handled
        })
        .sheet(item: $filePreview) { LocalFilePreviewSheet(target: $0) }
        .sheet(isPresented: $model.showingAppearanceSettings) { appearanceSettingsSheet }
        .sheet(isPresented: $model.showingCategoryManager) { categoryManagerSheet }
        .sheet(isPresented: $model.showingThreadNameEditor) { threadNameEditorSheet }
        .sheet(isPresented: $model.showingRemoteControl) { RemoteControlSheet() }
        .sheet(isPresented: $model.showingAccounts) { CodexAccountsSheet(store: model.accounts) }
        .sheet(isPresented: $model.showingUsageInsights) { CodexUsageInsightsSheet() }
        .sheet(isPresented: $model.showingWeeklyQuotaComparison) { WeeklyQuotaComparisonSheet() }
        .sheet(isPresented: $model.showingPersonalSkills) { CodexPersonalSkillsSheet() }
        .alert("操作未完成", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
        .onAppear(perform: applyAppearancePreference)
        .onAppear(perform: updateUnreadDockBadge)
        .onAppear(perform: applySystemMetricsRefreshInterval)
        .onChange(of: model.unreadCompletions.unread) { _, _ in updateUnreadDockBadge() }
        .onChange(of: model.selectedThreadID) { _, _ in
            detailLayoutRevision &+= 1
        }
        .onChange(of: showUnreadDockBadge) { _, _ in updateUnreadDockBadge() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            updateUnreadDockBadge()
        }
        .onChange(of: systemMetricsRefreshInterval) { _, _ in applySystemMetricsRefreshInterval() }
        .onChange(of: appearancePreference) { _, _ in
            applyAppearancePreference()
        }
    }

    private func creditUsageProtectionBanner(_ reason: CreditUsageProtection.Reason) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("额外额度保护已触发", systemImage: "pause.circle.fill")
                .font(.headline)
            Text(reason.message)
            if !model.creditUsagePauseFailures.isEmpty {
                Text("\(model.creditUsagePauseFailures.count) 个会话尚未暂停成功，正在重试；请检查连接或手动停止。")
                    .foregroundStyle(.red)
            }
            HStack {
                Button(model.isRecheckingIncludedQuota ? "正在检查套餐额度…" : "检查套餐额度并解除保护") {
                    Task { await model.recheckIncludedQuota() }
                }
                .disabled(model.isRecheckingIncludedQuota)
                Button("打开个性设置") { model.showingAppearanceSettings = true }
            }
            if let message = model.includedQuotaCheckMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            Text("排队消息已保留。解除保护后排队消息可继续发送，已中断的任务需手动继续。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .padding(.leading, 12)
        .background {
            Color(nsColor: .windowBackgroundColor)
                .overlay(Color.orange.opacity(0.12))
        }
    }

    private var renderedWorkspaceColumnWidth: CGFloat {
        switch columnVisibility {
        case .doubleColumn, .detailOnly:
            return 0
        case .automatic, .all:
            return CGFloat(MainColumnLayout.clamped(workspaceColumnWidth, to: MainColumnLayout.workspaceRange))
        default:
            return CGFloat(MainColumnLayout.clamped(workspaceColumnWidth, to: MainColumnLayout.workspaceRange))
        }
    }

    private var renderedThreadListColumnWidth: CGFloat {
        switch columnVisibility {
        case .detailOnly:
            return 0
        case .automatic, .all, .doubleColumn:
            return CGFloat(MainColumnLayout.clamped(threadListColumnWidth, to: MainColumnLayout.threadListRange))
        default:
            return CGFloat(MainColumnLayout.clamped(threadListColumnWidth, to: MainColumnLayout.threadListRange))
        }
    }

    private func applyAppearancePreference() {
        switch appearancePreference {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }

        // AppKit closes an active sheet while it recomputes a window's appearance.
        // The presentation state lives on AppModel, so restoring it after that
        // short native transition keeps this settings sheet open for another choice.
        guard model.showingAppearanceSettings else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            model.showingAppearanceSettings = true
        }
    }

    private func updateUnreadDockBadge() {
        let count = model.unreadCompletions.unread.count
        NSApp.dockTile.badgeLabel = showUnreadDockBadge && count > 0 ? String(count) : nil
    }

    private func applySystemMetricsRefreshInterval() {
        model.systemMetrics.setRefreshInterval(.resolved(systemMetricsRefreshInterval))
    }

    private var folderSidebar: some View {
        VStack(spacing: 0) {
            workspaceSidebarHeader

            List(selection: Binding(
                get: { showingUnreadThreads ? "__unread__" : showingFavoriteThreads ? "__favorites__" : model.selectedFolder ?? "__all__" },
                set: { selection in
                    guard let selection else { return }
                    showingUnreadThreads = selection == "__unread__"
                    if showingUnreadThreads {
                        showingFavoriteThreads = false
                        return
                    }
                    if selection == "__favorites__" {
                        showingFavoriteThreads = true
                        return
                    }
                    showingFavoriteThreads = false
                    let previous = model.selectedFolder
                    DispatchQueue.main.async {
                        guard model.selectedFolder == previous else { return }
                        model.selectFolder(selection == "__all__" ? nil : selection)
                    }
                }
            )) {
                Label("最近会话", systemImage: "tray.full")
                    .padding(.vertical, 3)
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 10))
                    .tag("__all__")
                Label("收藏会话", systemImage: "star")
                    .padding(.vertical, 3)
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 10))
                    .tag("__favorites__")
                HStack(spacing: 8) {
                    Label {
                        Text("红点会话")
                            .foregroundStyle(showingUnreadThreads ? Color.white : Color.primary)
                    } icon: {
                        Image(systemName: "bubble.left")
                            .foregroundStyle(showingUnreadThreads ? Color.white : Color.accentColor)
                    }
                    Spacer(minLength: 8)
                    Text("\(model.unreadCompletions.unread.count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(showingUnreadThreads ? Color.white : Color.secondary)
                        .padding(.horizontal, 6)
                        .frame(minWidth: 20, minHeight: 18)
                        .background(
                            showingUnreadThreads ? Color.white.opacity(0.18) : Color.primary.opacity(0.07),
                            in: Capsule()
                        )
                }
                .padding(.vertical, 3)
                .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 10))
                .tag("__unread__")
                .help("查看所有工作区中已完成但未查看的会话")

                ForEach(model.workspaceCategories) { category in
                    workspaceCategorySection(category)
                }

                uncategorizedWorkspaceRows
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 0)
        }
        .safeAreaInset(edge: .bottom) {
            ConnectionHealthView(health: model.connectionHealth, localStatus: model.connectionText)
            .padding(12)
            .background(.bar)
        }
    }

    private var workspaceSidebarHeader: some View {
        HStack(spacing: 4) {
            Text("工作区")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button {
                model.chooseWorkspaceFolder()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("新增工作区")
            .accessibilityLabel("新增工作区")

            Button {
                model.showingCategoryManager = true
            } label: {
                Image(systemName: "folder.badge.gearshape")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("管理分类")
            .accessibilityLabel("管理工作区分类")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 32)
    }

    @ViewBuilder
    private func workspaceCategorySection(_ category: WorkspaceCategory) -> some View {
        let isExpanded = categoryExpansionBinding(category.id)
        categoryDropHeader(
            category.name,
            systemImage: "folder.fill",
            categoryID: category.id,
            isExpanded: isExpanded
        )
        .contextMenu {
            Button("重命名") {
                model.showingCategoryManager = true
                model.beginRenamingCategory(category)
            }
            Button("删除分类", role: .destructive) {
                model.deleteCategory(category.id)
            }
        }

        if isExpanded.wrappedValue {
            let folders = model.folders(inCategory: category.id)
            if folders.isEmpty {
                categoryDropPlaceholder("拖动工作区到这里", categoryID: category.id)
            } else {
                ForEach(folders) { folder in
                    workspaceRow(folder)
                }
            }
        }
    }

    @ViewBuilder
    private var uncategorizedWorkspaceRows: some View {
        let isExpanded = categoryExpansionBinding(nil)
        categoryDropHeader(
            "未分类",
            systemImage: "tray",
            categoryID: nil,
            isExpanded: isExpanded
        )

        if isExpanded.wrappedValue {
            if model.uncategorizedFolders.isEmpty {
                categoryDropPlaceholder("拖动工作区到这里", categoryID: nil)
            } else {
                ForEach(model.uncategorizedFolders) { folder in
                    workspaceRow(folder)
                }
            }
        }
    }

    private func workspaceRow(_ folder: WorkspaceFolder) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name).lineLimit(1)
                Text(folder.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } icon: {
            Image(systemName: "folder")
                .foregroundStyle(.blue)
        }
        .padding(.leading, 14)
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 1, leading: 10, bottom: 1, trailing: 10))
        .tag(folder.path)
        .help(folder.path)
        .draggable(folder.path) {
            Label(folder.name, systemImage: "folder.fill")
                .padding(8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .dropDestination(for: String.self) { values, _ in
            let paths = folderPaths(from: values)
            guard !paths.isEmpty, !paths.contains(folder.path) else { return false }
            model.moveFolders(
                paths,
                to: model.categoryID(forFolder: folder.path),
                before: folder.path
            )
            return true
        }
        .contextMenu {
            Menu("移动到分类") {
                Button {
                    model.moveFolders([folder.path], to: nil)
                } label: {
                    Label("未分类", systemImage: model.categoryID(forFolder: folder.path) == nil ? "checkmark" : "tray")
                }
                Divider()
                ForEach(model.workspaceCategories) { category in
                    Button {
                        model.moveFolders([folder.path], to: category.id)
                    } label: {
                        Label(
                            category.name,
                            systemImage: model.categoryID(forFolder: folder.path) == category.id ? "checkmark" : "folder"
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func categoryDropHeader(
        _ title: String,
        systemImage: String,
        categoryID: String?,
        isExpanded: Binding<Bool>
    ) -> some View {
        let header = HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.blue)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
            // Keep the selected workspace capsule visually separate from its
            // category label. A one-point gap makes the sidebar selection look
            // attached to the header, especially in the uncategorized section.
            .padding(.bottom, 7)
            .contentShape(Rectangle())
            .onTapGesture {
                isExpanded.wrappedValue.toggle()
            }
            .dropDestination(for: String.self) { paths, location in
                handleCategoryDrop(paths, targetCategoryID: categoryID, location: location)
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded.wrappedValue ? "已展开" : "已收起")
            .accessibilityHint("点击收起或展开；也可将工作区拖到此分类")
            .help(isExpanded.wrappedValue
                  ? "点击收起；可将工作区拖到此分类"
                  : "点击展开；可将工作区拖到此分类")

        if let categoryID {
            header.draggable(categoryDragPrefix + categoryID) {
                Label(title, systemImage: "folder.fill")
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 0, trailing: 10))
        } else {
            header
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 0, trailing: 10))
        }
    }

    private func categoryExpansionBinding(_ categoryID: String?) -> Binding<Bool> {
        let key = WorkspaceCategoryDisclosureState.key(for: categoryID)
        return Binding(
            get: {
                !WorkspaceCategoryDisclosureState.decode(collapsedWorkspaceCategories).contains(key)
            },
            set: { isExpanded in
                var collapsed = WorkspaceCategoryDisclosureState.decode(collapsedWorkspaceCategories)
                if isExpanded {
                    collapsed.remove(key)
                } else {
                    collapsed.insert(key)
                }
                collapsedWorkspaceCategories = WorkspaceCategoryDisclosureState.encode(collapsed)
            }
        )
    }

    private func categoryDropPlaceholder(_ title: String, categoryID: String?) -> some View {
        Text(title)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .padding(.leading, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { paths, _ in
                let folderPaths = folderPaths(from: paths)
                guard !folderPaths.isEmpty else { return false }
                model.moveFolders(folderPaths, to: categoryID)
                return true
            }
    }

    private func handleCategoryDrop(
        _ values: [String],
        targetCategoryID: String?,
        location: CGPoint
    ) -> Bool {
        if let draggedCategoryID = values.compactMap(categoryID(from:)).first {
            if let targetCategoryID, draggedCategoryID != targetCategoryID {
                model.moveCategory(
                    draggedCategoryID,
                    relativeTo: targetCategoryID,
                    placeAfter: location.y > 15
                )
                return true
            } else if targetCategoryID == nil {
                model.moveCategoryToEnd(draggedCategoryID)
                return true
            }
        }
        if values.contains(where: { $0.hasPrefix(categoryDragPrefix) }) {
            return false
        }
        let paths = folderPaths(from: values)
        guard !paths.isEmpty else { return false }
        model.moveFolders(paths, to: targetCategoryID)
        return true
    }

    private func folderPaths(from values: [String]) -> [String] {
        values.filter { !$0.hasPrefix(categoryDragPrefix) }
    }

    private func categoryID(from value: String) -> String? {
        guard value.hasPrefix(categoryDragPrefix) else { return nil }
        return String(value.dropFirst(categoryDragPrefix.count))
    }

    private var categoryManagerSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("管理工作区分类")
                    .font(.title2.bold())
                Spacer()
                Button("完成") { model.showingCategoryManager = false }
                    .keyboardShortcut(.defaultAction)
            }

            Text("分类只用于整理侧边栏，不会移动或删除磁盘上的文件夹。")
                .font(.callout)
                .foregroundStyle(.secondary)

            if model.workspaceCategories.isEmpty {
                ContentUnavailableView(
                    "还没有分类",
                    systemImage: "folder.badge.plus",
                    description: Text("新建分类后，可以把左侧工作区拖进去。")
                )
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(model.workspaceCategories.enumerated()), id: \.element.id) { index, category in
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue)
                            Text(category.name)
                            Spacer()
                            Button {
                                model.moveCategory(category.id, offset: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                            .help("上移")

                            Button {
                                model.moveCategory(category.id, offset: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.borderless)
                            .disabled(index == model.workspaceCategories.count - 1)
                            .help("下移")

                            Button {
                                model.beginRenamingCategory(category)
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .help("重命名")

                            Button(role: .destructive) {
                                model.deleteCategory(category.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("删除分类；其中的工作区会回到未分类")
                        }
                    }
                }
                .listStyle(.inset)
            }

            Button {
                model.beginCreatingCategory()
            } label: {
                Label("新建分类", systemImage: "plus")
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
        .sheet(isPresented: $model.showingCategoryEditor) {
            categoryEditorSheet
        }
    }

    private var categoryEditorSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.editingCategoryID == nil ? "新建分类" : "重命名分类")
                .font(.title2.bold())
            TextField("分类名称", text: $model.categoryNameDraft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(model.saveCategoryEditor)
            if let error = model.categoryEditorError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") { model.showingCategoryEditor = false }
                    .keyboardShortcut(.cancelAction)
                Button("保存", action: model.saveCategoryEditor)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private var threadNameEditorSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("编辑会话名称")
                .font(.title2.bold())
            TextField("会话名称", text: $model.threadNameDraft)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isSavingThreadName)
                .onSubmit {
                    Task { await model.saveThreadName() }
                }
            if let error = model.threadNameEditorError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                if model.isSavingThreadName {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                Button("取消", action: model.cancelThreadNameEditor)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isSavingThreadName)
                Button("保存") {
                    Task { await model.saveThreadName() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isSavingThreadName)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var threadList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(showingUnreadThreads ? "红点会话" : showingFavoriteThreads
                     ? "收藏会话"
                     : model.selectedFolder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "最近会话")
                    .font(.headline)
                Spacer()
                if !showingUnreadThreads, !showingFavoriteThreads, model.selectedFolder != nil {
                    Button(action: model.prepareNewThread) {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("新建会话")
                }
            }
            .frame(minHeight: 28)
            .padding(.horizontal, 12)
            .padding(.top, 12)

            RecentConversationList(
                rows: displayedThreads.map { thread in
                    RecentConversationRow(
                        thread: thread,
                        isSelected: model.selectedThreadID == thread.id,
                        outcome: model.conversationOutcome(for: thread),
                        showPreview: showConversationPreview,
                        hasUnreadCompletion: (showUnreadCompletionDot || showingUnreadThreads) && model.unreadCompletions.unread.contains(thread.id),
                        needsUserInput: model.userInputRequests.contains { $0.threadID == thread.id },
                        isFavorite: model.isFavoriteConversation(thread.id)
                    )
                },
                onSelect: model.selectThread,
                onRename: model.beginRenamingThread,
                onToggleFavorite: model.toggleFavoriteConversation
            )
            .equatable()
            .searchable(text: $model.searchText, prompt: "搜索会话")
            .overlay {
                if showingUnreadThreads && model.isLoadingUnreadThreads {
                    ProgressView("加载红点会话…")
                        .padding(20)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !showingUnreadThreads && model.isLoading && model.selectedThreadID == nil {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("加载最近会话…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if displayedThreads.isEmpty {
                    ContentUnavailableView(
                        showingUnreadThreads ? "暂无匹配的红点会话" : showingFavoriteThreads ? "暂无收藏会话" : "暂无会话",
                        systemImage: showingUnreadThreads ? "circle" : showingFavoriteThreads ? "star" : "bubble.left.and.bubble.right",
                        description: Text(showingUnreadThreads
                                          ? "显示所有工作区中已完成但未查看的会话；可清空搜索后重试"
                                          : showingFavoriteThreads
                                          ? "在会话上右键即可收藏"
                                          : "在这个文件夹中新建一个 Codex 会话")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if showingUnreadThreads, let error = model.unreadThreadsError {
                    VStack(spacing: 6) {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                        Button("重试") { Task { await model.refreshUnreadThreads() } }
                            .disabled(model.isLoadingUnreadThreads)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                } else if !showingUnreadThreads, !showingFavoriteThreads, model.hasMoreThreads {
                    Text("为保持流畅，仅显示最近 60 个会话")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(.bar)
                }
            }
        }
        .task(id: showingUnreadThreads) {
            if showingUnreadThreads { await model.refreshUnreadThreads() }
        }
        .onChange(of: model.unreadCompletions.unread) { oldValue, newValue in
            if showingUnreadThreads, !newValue.subtracting(oldValue).isEmpty {
                Task { await model.refreshUnreadThreads() }
            }
        }
    }

    private var displayedThreads: [CodexThread] {
        showingUnreadThreads ? model.visibleUnreadThreads : showingFavoriteThreads ? model.visibleFavoriteThreads : model.visibleThreads
    }

    @ViewBuilder
    private func conversation(explicitWidth: CGFloat) -> some View {
        Group {
            if model.showingNewThread {
                NewThreadWorkspace()
            } else if let thread = model.selectedThread {
                VStack(spacing: 0) {
                    ConversationHeader(thread: thread)
                        .zIndex(2)
                    Divider()
                        .zIndex(2)
                    MessageList(
                        viewportWidth: explicitWidth,
                        messages: model.messages,
                        collaborationTasks: model.selectedCollaborationTasks,
                        isLoading: model.isConversationLoading,
                        isThinking: model.isSelectedThreadProcessing
                    )
                    .equatable()
                    // Use the exact width proposed by BrowserConversationLayout.
                    // A flexible frame can leave the AppKit-backed timeline at
                    // its old 600-point ideal width and create an empty column
                    // before the embedded browser.
                    .frame(width: explicitWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The window reserves a narrow trailing safe-area strip on
                    // macOS. It belongs to the vertical scroller, not to empty
                    // conversation content, so let the timeline occupy it.
                    .ignoresSafeArea(.container, edges: .trailing)
                    .id(thread.id)
                    if !model.selectedUserInputRequests.isEmpty {
                        Divider()
                        UserInputRequestsPanel(requests: model.selectedUserInputRequests) { requestID, answers in
                            model.submitUserInput(requestID: requestID, answers: answers)
                        }
                    }
                    if let question = model.assistantReplyQuestion {
                        Divider()
                        AssistantReplyQuestionPanel(question: question,
                            isSubmitting: model.submittingAssistantReplyThreads.contains(thread.id),
                            error: model.assistantReplyErrors[thread.id + ":" + question.id],
                            submit: { answer in
                                Task { await model.submitAssistantReplyAnswer(questionID: question.id, answer: answer) }
                            }, dismiss: { model.dismissAssistantReplyQuestion(question.id) })
                            .id(thread.id + ":" + question.id)
                    }
                    if !model.selectedComputerUseApprovalRequests.isEmpty {
                        Divider()
                        ComputerUseApprovalRequestsPanel(requests: model.selectedComputerUseApprovalRequests) { requestID, decision in
                            model.submitComputerUseApproval(requestID: requestID, decision: decision)
                        }
                    }
                    Divider()
                    switch model.threadInputAvailability {
                    case .checking, .occupied, .unavailable:
                        ThreadInputUnavailableView(state: model.threadInputAvailability)
                    case .available:
                        Composer(mode: .conversation)
                    }
                }
                .frame(width: explicitWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ContentUnavailableView {
                    Label("选择一个会话", systemImage: "message")
                } description: {
                    Text("从左侧工作区中选择现有会话，或新建一个会话。")
                } actions: {
                    Button("新建会话", action: model.prepareNewThread)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .background {
            if !backgroundImagePath.isEmpty, backgroundScope == .conversation {
                PersonalBackgroundImage(
                    path: backgroundImagePath,
                    opacity: backgroundOpacity,
                    zoom: backgroundZoom,
                    offsetX: backgroundOffsetX,
                    offsetY: backgroundOffsetY
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            CloudCodexVersionBadge(
                currentVersion: updateController.currentVersion,
                latestVersion: updateController.latestVersion,
                isChecking: updateController.isChecking
            )
        }
        ToolbarItem(placement: .principal) {
            HStack(spacing: 12) {
                SystemMetricsView(monitor: model.systemMetrics)
                Divider()
                    .frame(height: 26)
                if model.customModelProvider.enabled {
                    Text("\(model.customModelProvider.name) · 按服务商计费")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    AccountOverviewView()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            // Keep the title-bar status strip at its intrinsic width. A flexible
            // max width makes the toolbar background stretch into a large blank area.
            .fixedSize(horizontal: true, vertical: false)
        }
        ToolbarItemGroup {
            Button {
                if let threadID = model.selectedThreadID {
                    model.browser.toggle(threadID: threadID)
                }
            } label: {
                Image(systemName: "globe")
            }
            .disabled(model.selectedThreadID == nil)
            .help("内置浏览器")
            Button {
                Task { await model.refreshThreads() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.isLoading)
            .help("刷新会话")

            Button(action: model.prepareNewThread) {
                Label("新建会话", systemImage: "plus")
            }

            Button {
                model.showingRemoteControl = true
            } label: {
                Label("远程控制", systemImage: "antenna.radiowaves.left.and.right")
            }
            .help("用 AI 小程序远程发送任务")

            Button {
                model.showingAppearanceSettings = true
            } label: {
                Label("偏好设置", systemImage: "slider.horizontal.3")
            }
            .help("偏好设置：调整外观、显示与执行保护")
            Button {
                model.showingPersonalSkills = true
            } label: {
                Label("我的技能", systemImage: "books.vertical")
            }
            .help("查看当前 Codex 识别到的自建技能")
            Button {
                model.showingAccounts = true
            } label: {
                Label("账号管理", systemImage: "person.crop.circle")
            }
            .help("添加和切换 Codex 账号")
            Button {
                model.showingUsageInsights = true
            } label: {
                Label("使用统计", systemImage: "chart.xyaxis.line")
            }
            .help("查看 Token 用量与已记录的第三方模型响应次数")
            Button {
                openWindow(id: "about-cloudcodex")
            } label: {
                Label("关于 CloudCodex", systemImage: "info.circle")
            }
            .help("关于 CloudCodex：功能与工作原理")
        }
    }

    private struct CloudCodexVersionBadge: View {
        let currentVersion: String
        let latestVersion: String?
        let isChecking: Bool

        private var latestVersionText: String {
            if let latestVersion { return latestVersion }
            return isChecking ? "检查中" : "--"
        }

        var body: some View {
            HStack(spacing: 5) {
                Text("当前 \(currentVersion)")
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("最新 \(latestVersionText)")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
            .fixedSize()
            .help("当前版本 \(currentVersion)，最新版本 \(latestVersionText)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("当前版本 \(currentVersion)，最新版本 \(latestVersionText)")
        }
    }

    private var appearanceSettingsSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.purple.gradient, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("偏好设置")
                        .font(.headline)
                    Text("按类别配置；拖动窗口边缘调整大小，尺寸自动保存")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { model.showingAppearanceSettings = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.bottom, 18)

            TabView(selection: $preferencesTab) {
                preferencesPage {
                    appearanceModeSettingsSection
                    backgroundSettingsSection
                }
                .tabItem { Label("外观与背景", systemImage: "paintpalette") }.tag(0)

                preferencesPage { conversationDisplaySettingsSection }
                    .tabItem { Label("会话与显示", systemImage: "text.bubble") }.tag(1)

                preferencesPage { ModelProviderSettings(library: model.providerLibrary) }
                    .tabItem { Label("模型服务商", systemImage: "cpu") }.tag(2)

                preferencesPage { executionProtectionSettingsSection }
                    .tabItem { Label("执行保护", systemImage: "shield") }.tag(3)
            }
        }
        .padding(20)
        .frame(minWidth: PreferencesWindowSizing.minimum.width,
               idealWidth: PreferencesWindowSizing.initial.width, maxWidth: .infinity,
               minHeight: PreferencesWindowSizing.minimum.height,
               idealHeight: PreferencesWindowSizing.initial.height, maxHeight: .infinity)
        .background(PreferencesWindowSizing())
        .onAppear {
            syncCommandInactivityTimeoutDraft()
        }
        .onChange(of: model.commandInactivityTimeoutMinutes) { _, _ in
            if !isCommandInactivityTimeoutFocused {
                syncCommandInactivityTimeoutDraft()
            }
        }
    }

    private func preferencesPage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }

    private var appearanceModeSettingsSection: some View {
        GroupBox("外观模式") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("外观模式", selection: $appearancePreference) {
                    ForEach(AppearancePreference.allCases) { preference in
                        Label(preference.title, systemImage: preference.symbolName)
                            .tag(preference)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Text(appearancePreference == .system
                     ? "将跟随 macOS 当前的明亮或暗黑外观。"
                     : "此选择会立即应用，并保留到下次启动。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
    }

    private var conversationDisplaySettingsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("会话列表") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("显示会话摘要", isOn: $showConversationPreview)
                        .toggleStyle(.switch)
                    Toggle("显示已完成未查看红点", isOn: $showUnreadCompletionDot)
                        .toggleStyle(.switch)
                    Toggle("Dock 显示未查看会话数量", isOn: $showUnreadDockBadge)
                        .toggleStyle(.switch)
                    Text("关闭摘要后列表更紧凑，不影响会话正文与搜索。设置自动保存。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            }

            GroupBox("套餐与额度") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("自动刷新频率")
                            Text("控制顶部套餐、余额与额度信息的定时刷新间隔。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("套餐与额度刷新频率", selection: Binding(
                            get: { model.accountRefreshInterval },
                            set: { model.setAccountRefreshInterval($0) }
                        )) {
                            ForEach(AccountRefreshInterval.allCases) { interval in
                                Text(interval.title).tag(interval)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }
                    Text("修改后立即按新间隔计时并自动保存；仍可在套餐面板中手动刷新。额度保护启用且有任务运行或处于额度保护暂停状态时，仍每 5 秒检查一次。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.customModelProvider.enabled {
                        Text("此设置用于 ChatGPT 套餐；第三方 API 的费用由服务商管理。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            GroupBox("电脑状态") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("刷新频率")
                        Text("控制顶部温度、CPU 和存储信息的采样间隔。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("电脑状态刷新频率", selection: $systemMetricsRefreshInterval) {
                        ForEach(SystemMetricsRefreshInterval.allCases) { interval in
                            Text(interval.title).tag(interval.rawValue)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 92)
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var executionProtectionSettingsSection: some View {
        GroupBox("执行保护") {
            VStack(alignment: .leading, spacing: 10) {
                if model.customModelProvider.enabled {
                    Text("第三方 API 的费用由服务商管理，ChatGPT 额度保护不适用。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Toggle("允许使用额外额度", isOn: Binding(
                        get: { model.allowsExtraCreditUsage },
                        set: { model.setAllowsExtraCreditUsage($0) }
                    ))
                    Text("默认关闭。套餐额度耗尽或检测到额外额度余额下降时，暂停所有会话，并阻止排队消息和自动重试。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("保护依赖额度更新和中断响应，无法撤销检测前已发生的额度消耗。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("命令无输出超时")
                        Text("命令在这段时间内没有任何新输出时，自动停止本轮任务。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        TextField("超时分钟数", text: $commandInactivityTimeoutDraft)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 52)
                        .focused($isCommandInactivityTimeoutFocused)
                        .onSubmit {
                            commitCommandInactivityTimeoutDraft()
                            isCommandInactivityTimeoutFocused = false
                        }
                        .onChange(of: isCommandInactivityTimeoutFocused) { _, focused in
                            if !focused {
                                commitCommandInactivityTimeoutDraft()
                            }
                        }
                        .accessibilityLabel("命令无输出超时分钟数")
                        .help("可直接输入 1 到 60 之间的分钟数")

                        Text("分钟")
                            .foregroundStyle(.secondary)

                        Stepper(
                            "命令无输出超时分钟数",
                            value: commandInactivityTimeoutBinding,
                            in: 1...60
                        )
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                if let commandInactivityTimeoutInputError {
                    Text(commandInactivityTimeoutInputError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text("范围 1–60 分钟，默认 5 分钟。命令每次产生新输出都会重新计时；正常持续输出的长任务不会因总耗时而被停止。设置自动保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
    }

    private var commandInactivityTimeoutBinding: Binding<Int> {
        Binding(
            get: { model.commandInactivityTimeoutMinutes },
            set: { minutes in
                model.setCommandInactivityTimeoutMinutes(minutes)
                syncCommandInactivityTimeoutDraft()
            }
        )
    }

    private func syncCommandInactivityTimeoutDraft() {
        commandInactivityTimeoutDraft = String(model.commandInactivityTimeoutMinutes)
        commandInactivityTimeoutInputError = nil
    }

    private func commitCommandInactivityTimeoutDraft() {
        guard let minutes = CommandInactivityTimeoutInput.minutes(
            from: commandInactivityTimeoutDraft
        ) else {
            commandInactivityTimeoutInputError = "请输入 1–60 之间的整数。"
            return
        }
        model.setCommandInactivityTimeoutMinutes(minutes)
        syncCommandInactivityTimeoutDraft()
    }

    private var backgroundSettingsSection: some View {
        GroupBox("个性背景") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Button(backgroundImagePath.isEmpty ? "选择背景图片" : "更换背景图片") {
                        chooseBackgroundImage()
                    }
                    if !backgroundImagePath.isEmpty {
                        Button("移除背景") {
                            backgroundImagePath = ""
                        }
                        .foregroundStyle(.red)
                    }
                    Spacer()
                    Text("支持 PNG、JPEG、HEIC 等图片")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("应用范围", selection: $backgroundScope) {
                    ForEach(BackgroundScope.allCases) { scope in
                        Label(scope.title, systemImage: scope.symbolName).tag(scope)
                    }
                }
                .pickerStyle(.segmented)

                HStack(alignment: .top, spacing: 18) {
                    if backgroundImagePath.isEmpty {
                        ZStack {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(.quaternary.opacity(0.45))
                            VStack(spacing: 8) {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.title2)
                                Text("选择图片后可预览并裁切")
                                    .font(.caption)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .aspectRatio(backgroundScope == .entireWindow ? 16 / 10 : 4 / 5, contentMode: .fit)
                        .frame(width: 250)
                    } else {
                        BackgroundCropPreview(
                            path: backgroundImagePath,
                            scope: backgroundScope,
                            zoom: $backgroundZoom,
                            offsetX: $backgroundOffsetX,
                            offsetY: $backgroundOffsetY
                        )
                        .frame(width: 250)
                    }

                    VStack(alignment: .leading, spacing: 13) {
                        Label("推荐尺寸：\(backgroundScope.recommendedSize)", systemImage: "ruler")
                            .font(.callout.weight(.medium))
                        Text(backgroundScope.recommendationDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        backgroundSlider(
                            title: "透明度",
                            value: $backgroundOpacity,
                            range: 0.05 ... 0.85,
                            label: "\(Int(backgroundOpacity * 100))%"
                        )
                        backgroundSlider(
                            title: "裁切缩放",
                            value: $backgroundZoom,
                            range: 1 ... 3,
                            label: String(format: "%.1f×", backgroundZoom)
                        )

                        HStack {
                            Text("拖动左侧预览调整裁切中心")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("居中") {
                                backgroundOffsetX = 0
                                backgroundOffsetY = 0
                            }
                            .buttonStyle(.borderless)
                            Button("重置") {
                                backgroundOpacity = BackgroundPreference.defaultOpacity
                                backgroundZoom = BackgroundPreference.defaultZoom
                                backgroundOffsetX = 0
                                backgroundOffsetY = 0
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
        }
    }

    private func backgroundSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        label: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text(label)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.title = "选择 CloudCodex 背景图片"
        panel.prompt = "设为背景"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            backgroundImagePath = try BackgroundImageStore.importImage(from: url)
            backgroundZoom = BackgroundPreference.defaultZoom
            backgroundOffsetX = 0
            backgroundOffsetY = 0
        } catch {
            model.errorMessage = "背景图片无法读取：\(error.localizedDescription)"
        }
    }

}

private struct ThreadInputUnavailableView: View {
    @EnvironmentObject private var model: AppModel
    let state: ThreadInputAvailability

    private var isChecking: Bool { state == .checking }
    private var title: String {
        switch state {
        case .checking: return "正在恢复会话"
        case .occupied: return "已在另一个应用中打开"
        case .unavailable: return "暂时无法继续会话"
        case .available: return "可以继续会话"
        }
    }
    private var detail: String {
        switch state {
        case .checking: return "历史记录可以正常查看，恢复完成后即可继续发送。"
        case .occupied: return model.threadOwnershipNotice ?? AppModel.occupiedThreadMessage
        case .unavailable: return model.threadOwnershipNotice ?? "本地服务暂未响应，请重试。"
        case .available: return ""
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: isChecking ? "arrow.clockwise" : (state == .occupied ? "lock" : "exclamationmark.circle"))
                .font(.title3)
            .frame(width: 26)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Divider()
                .frame(height: 38)
            Button("重试") {
                Task { await model.retrySelectedThreadOwnership() }
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            // A restore is already in flight; do not queue duplicate retries.
            .allowsHitTesting(!isChecking)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(.quaternary)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title + "，" + detail)
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

private struct ConnectionHealthView: View {
    @ObservedObject var health: ConnectionHealth
    let localStatus: String
    @State private var expanded = false
    var body: some View {
        statusButton
            .popover(isPresented: $expanded) { connectionDetails }
    }

    private var statusButton: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 12) {
                indicator("本机", available: localStatus.hasPrefix("已连接"))
                indicator("网络", available: health.networkAvailable == true)
                indicator("GPT", available: health.serviceReachable)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(localStatus) · \(health.networkText) · \(health.serviceText)\n点击查看连接详情")
        .font(.caption2)
    }

    private var connectionDetails: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("连接状态").font(.headline)
                Label(localStatus, systemImage: "desktopcomputer")
                Label(health.networkText, systemImage: "network")
                Label(health.serviceText, systemImage: "checkmark.shield")
                Divider()
                Text(health.detail).font(.caption).foregroundStyle(.secondary)
                if let date = health.checkedAt {
                    Text("检测时间：" + date.formatted(date: .omitted, time: .standard))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(health.isChecking ? "正在检测…" : "重新检测") { Task { await health.check() } }
                    .disabled(health.isChecking || health.networkAvailable != true)
            }
            .padding(18).frame(width: 310)
    }

    private func indicator(_ title: String, available: Bool) -> some View {
        HStack(spacing: 4) {
            Circle().fill(available ? Color.green : Color.orange).frame(width: 6, height: 6)
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
        .accessibilityLabel(title + (available ? "已连接或接口可访问" : "待检测或不可用，查看详情"))
    }
}

private struct RemoteControlSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemoteUnpair = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("远程控制")
                        .font(.headline)
                    Text("通过内置或自建服务向这台 Mac 发送任务")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("允许远程任务")
                                .font(.system(size: 14, weight: .semibold))
                            Text("关闭后不再领取新任务；默认保持关闭。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { model.remoteControlEnabled },
                            set: { model.setRemoteControlEnabled($0) }
                        ))
                        .labelsHidden()
                    }
                    .padding(16)
                    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))

                    RemoteServerSettingsView()

                    HStack(spacing: 10) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 9, height: 9)
                            .shadow(color: statusColor.opacity(0.65), radius: model.remoteControlEnabled ? 5 : 0)
                        Text(model.remoteControlStatus)
                            .font(.subheadline)
                        Spacer()
                    }

                    if model.remoteControlEnabled, model.remoteCredentialIssue != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("远程连接已暂停", systemImage: "lock.shield")
                                .font(.subheadline.weight(.semibold))
                            Text("启动和刷新不会反复弹出系统授权。需要远程控制时，点击下方按钮授权；取消后将继续保持暂停。本地会话不受影响。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("授权钥匙串并连接") { model.authorizeRemoteControl() }
                        }
                        .padding(16)
                        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    } else if model.remoteControlEnabled && model.isLoadingRemoteCredential {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("正在准备安全连接，可继续使用本地会话。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if model.remoteControlEnabled && !model.remoteControlPaired && model.remoteServerConfiguration.mode == .custom {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("在自己的小程序中配对").font(.headline)
                            Text("打开已接入当前后端的小程序，扫描下方设备二维码；也可以输入配对码。")
                                .font(.caption).foregroundStyle(.secondary)
                            if let payload = model.remotePairingQRCodePayload,
                               let image = RemotePairingQRCode.image(payload: payload) {
                                Image(nsImage: image).interpolation(.none).resizable()
                                    .frame(width: 190, height: 190).padding(15)
                                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                                    .accessibilityLabel("自定义服务设备配对二维码")
                                Text("配对码：\(model.remotePairingCode)").monospacedDigit().textSelection(.enabled)
                            } else {
                                Text("连接自定义后端后显示配对二维码。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            HStack {
                                Text("二维码临近过期时会自动更新").font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Button("刷新二维码") { model.resetRemotePairingCode() }.buttonStyle(.link)
                            }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                    } else if model.remoteControlEnabled && !model.remoteControlPaired {
                        VStack(alignment: .leading, spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("首次配对指引")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("需要先进入 CloudCodex 小程序，再使用小程序内的扫一扫完成设备配对。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            HStack(alignment: .top, spacing: 16) {
                                pairingStepCard(
                                    number: 1,
                                    title: "微信扫描小程序码",
                                    detail: "先用微信扫描下方小程序码，打开 CloudCodex 小程序。"
                                ) {
                                    if let image = Self.miniProgramCodeImage {
                                        Image(nsImage: image)
                                            .interpolation(.high)
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 220, height: 220)
                                            .background(.white)
                                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                                    .stroke(.secondary.opacity(0.16))
                                            }
                                            .accessibilityLabel("CloudCodex 小程序码")
                                    } else {
                                        Label("小程序码资源不可用", systemImage: "exclamationmark.triangle")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                            .frame(width: 220, height: 220)
                                    }
                                }

                                Image(systemName: "arrow.right")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24, height: 220)
                                    .accessibilityHidden(true)

                                pairingStepCard(
                                    number: 2,
                                    title: "在小程序中扫码配对",
                                    detail: "进入「设备管理」，点击「扫一扫配对」，再扫描下方二维码。"
                                ) {
                                    if let payload = model.remotePairingQRCodePayload,
                                       let image = RemotePairingQRCode.image(payload: payload) {
                                        Image(nsImage: image)
                                            .interpolation(.none)
                                            .resizable()
                                            .frame(width: 190, height: 190)
                                            .padding(15)
                                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                                            .accessibilityLabel("CloudCodex 设备配对二维码")
                                    } else {
                                        ProgressView("正在生成配对二维码…")
                                            .controlSize(.small)
                                            .frame(width: 220, height: 220)
                                    }
                                }
                            }

                            HStack {
                                Text("二维码临近过期时会自动更新")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Button("刷新二维码") { model.resetRemotePairingCode() }
                                    .buttonStyle(.link)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(18)
                        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.blue.opacity(0.22)))
                    } else if model.remoteControlEnabled && model.remoteControlPaired {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("这台 Mac 已完成配对", systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.green)
                            Text("解除后，当前服务绑定的账号将不能再控制这台 Mac。CloudCodex 会立即生成新的二维码，供原账号或其他账号重新绑定。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack {
                                Spacer()
                                Button("解绑并重新绑定", role: .destructive) {
                                    confirmingRemoteUnpair = true
                                }
                                .disabled(model.isRemoteUnpairing)
                            }
                        }
                        .padding(16)
                        .background(.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.green.opacity(0.18)))
                    }

                    VStack(alignment: .leading, spacing: 11) {
                        Label("执行边界", systemImage: "shield.lefthalf.filled")
                            .font(.system(size: 13, weight: .semibold))
                        detailRow("工作区", "仅限左侧已经出现的工作区")
                        detailRow("会话", "仅限 CloudCodex 已同步的最近会话，或新建会话")
                        detailRow("权限", model.remotePermissionLabel)
                        Text("远程任务会按当前权限执行。若选择“完全访问”，小程序发来的任务也拥有同样权限。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))

                    Label("CloudCodex 主动通过 HTTPS 领取任务，不会在 Mac 上开放公网监听端口。设备密钥按服务分别存放在系统钥匙串；自建后端应只保存不可逆摘要。", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
        }
        .frame(width: 760, height: 680)
        .confirmationDialog(
            "解除这台 Mac 的远程控制配对？",
            isPresented: $confirmingRemoteUnpair,
            titleVisibility: .visible
        ) {
            Button("解绑并生成新二维码", role: .destructive) {
                model.unpairAndPrepareRemoteRebinding()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("存在排队或执行中的远程任务时不会解绑。成功后需重新扫码，Mac 文件、本地会话和历史任务不会删除。")
        }
    }

    private var statusColor: Color {
        if !model.remoteControlEnabled { return .secondary }
        if model.remoteControlPaired { return .green }
        return .orange
    }

    private static let miniProgramCodeImage: NSImage? = {
        guard let url = Bundle.main.url(
            forResource: "CloudCodexMiniProgramCode",
            withExtension: "png"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }()

    private func pairingStepCard<Content: View>(
        number: Int,
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .center, spacing: 10) {
            HStack(alignment: .top, spacing: 9) {
                Text(String(number))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(.blue, in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(14)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 55, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.caption)
    }
}

private struct NewThreadWorkspace: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.black, in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 3) {
                    Text("新建会话")
                        .font(.headline)
                    Text(model.newThreadFolder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                Button(action: model.cancelNewThread) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("取消新建会话")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            Spacer(minLength: 24)

            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 26))
                    .foregroundStyle(.blue)
                Text("开始一个新任务")
                    .font(.title2.bold())
                Text("描述你希望 Codex 在这个工作文件夹中完成的内容")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 28)

            Composer(mode: .newThread)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct ThreadRow: View, Equatable {
    let thread: CodexThread
    var isSelected = false
    var outcome: ConversationOutcome? = nil
    var showPreview = true
    var hasUnreadCompletion = false
    var needsUserInput = false
    var relativeTimeBucket: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                ZStack {
                    ThreadStatusLight(isRunning: thread.status == "active")
                    if hasUnreadCompletion {
                        Circle().fill(.red).frame(width: 7, height: 7)
                            .accessibilityLabel("已完成，尚未查看")
                            .help("已完成，尚未查看；点击会话清除")
                    }
                }
                Text(thread.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ZStack(alignment: .trailing) {
                    Color.clear
                    if needsUserInput {
                        Label("待输入", systemImage: "questionmark.bubble.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.white : Color.orange)
                            .help("Codex 正在等待你的回答")
                    } else if let outcome {
                        Label(outcome.title, systemImage: outcome.symbol)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.white : outcomeColor)
                            .help("最近一轮：\(outcome.title)")
                    }
                }
                .frame(width: 64, alignment: .trailing)
            }
            .frame(height: 18)
            if showPreview {
                Text(thread.visiblePreview.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 32, alignment: .top)
            }
            HStack(spacing: 5) {
                Image(systemName: "folder")
                Text(thread.folderName)
                if let model = thread.model {
                    Text("·")
                    Text(model)
                }
                Spacer(minLength: 8)
                Text(relativeTimeLabel)
                    .fixedSize()
            }
            .font(.system(size: 10))
            .lineLimit(1)
            .foregroundStyle(isSelected ? Color.white.opacity(0.72) : Color.secondary)
            .frame(height: 14)
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        // Keep NSTableView's selection geometry stable while previews/status update.
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .frame(height: showPreview ? 96 : 58)
        .contentShape(Rectangle())
        .help(thread.displayName)
    }

    /// `Text(date, style: .relative)` installs an independent timeline for
    /// every row. With 60 visible summaries those timelines repeatedly wake
    /// and relayout the whole list, so render a snapshot instead. The regular
    /// status refresh and manual refresh keep this label sufficiently current.
    private var relativeTimeLabel: String {
        let now = relativeTimeBucket.map { Date(timeIntervalSince1970: Double($0) * 60) } ?? Date()
        let elapsed = max(0, Int(now.timeIntervalSince(thread.updatedAt)))
        switch elapsed {
        case ..<60:
            return "刚刚"
        case ..<3_600:
            return "\(elapsed / 60)分钟前"
        case ..<86_400:
            return "\(elapsed / 3_600)小时前"
        default:
            return "\(elapsed / 86_400)天前"
        }
    }

    private var outcomeColor: Color {
        switch outcome {
        case .completed: return .green
        case .failed: return .red
        case .interrupted: return .orange
        case .running: return .blue
        case nil: return .secondary
        }
    }
}

private struct ThreadStatusLight: View {
    let isRunning: Bool

    var body: some View {
        if isRunning {
            Circle()
                .fill(Color.green)
                .frame(width: 9, height: 9)
                .shadow(color: .green.opacity(0.9), radius: 5)
                .accessibilityLabel("正在执行")
            .frame(width: 13, height: 13)
        } else {
            Circle()
                .fill(.secondary.opacity(0.35))
                .frame(width: 7, height: 7)
                .frame(width: 13, height: 13)
                .accessibilityLabel("未在执行")
        }
    }
}

private struct ConversationHeader: View {
    let thread: CodexThread

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(thread.cwd)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        // Keep the title bar opaque and above the timeline. Without its own
        // background, a temporarily oversized NSScrollView document remains
        // visible behind the title/path while switching or restoring a task.
        .background(Color(nsColor: .windowBackgroundColor))
        .contentShape(Rectangle())
        .accessibilityIdentifier("conversation-header")
    }
}

private struct MessageList: View, Equatable {
    let viewportWidth: CGFloat
    let messages: [ChatMessage]
    let collaborationTasks: [CollaborationChildTask]
    let isLoading: Bool
    let isThinking: Bool
    @State private var showDelayedLoadingIndicator = false
    @State private var isAtLatest = true
    @State private var hasUnseenUpdates = false
    @State private var hasNewContentBelow = false
    @State private var visibleMessageLimit = 12
    @State private var viewportResetID = UUID()
    @StateObject private var scrollViewportController = MessageScrollViewportController()
    @State private var hasPositionedInitialHistory = false

    private let messageBatchSize = 12
    private let timelinePadding: CGFloat = 22

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.viewportWidth == rhs.viewportWidth
            && lhs.messages == rhs.messages
            && lhs.collaborationTasks == rhs.collaborationTasks
            && lhs.isLoading == rhs.isLoading
            && lhs.isThinking == rhs.isThinking
    }

    var body: some View {
        let entries = scrollViewportController.timeline.entries(from: messages)
        let latestChildTasks = collaborationTasks
        let hiddenEntryCount = max(0, entries.count - visibleMessageLimit)
        let prependAnchor = prependAnchorID(in: entries)
        let currentProcessID: String? = {
            guard isThinking, case .process(let group) = entries.last else { return nil }
            return group.id
        }()
        ZStack(alignment: .bottomTrailing) {
            ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 18) {
                        if messages.isEmpty && !isLoading {
                            ContentUnavailableView("开始对话", systemImage: "sparkles", description: Text("在下方输入任务并发送给 Codex。"))
                                .padding(.top, 80)
                        }

                        if hiddenEntryCount > 0 {
                            Label(
                                "继续上滑，自动加载更早的 \(min(messageBatchSize, hiddenEntryCount)) 段内容",
                                systemImage: "arrow.up.circle"
                            )
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(.quaternary.opacity(0.45), in: Capsule())
                            .background(MessageHistoryProbe(controller: scrollViewportController, role: .trigger))
                            .accessibilityLabel("自动加载更早的 \(min(messageBatchSize, hiddenEntryCount)) 段内容")

                            Text("已折叠更早的 \(hiddenEntryCount) 段对话，上滑到顶部会自动加载")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        ForEach(entries.suffix(visibleMessageLimit)) { entry in
                            VStack(spacing: 0) {
                                switch entry {
                                case .message(let message):
                                    MessageBubble(
                                        message: message,
                                        availableWidth: max(
                                            0,
                                            viewportWidth
                                                - timelinePadding * 2
                                        )
                                    )
                                        .equatable()
                                        .background(messageEntryOffsetReader(id: entry.id, isAnchor: entry.id == prependAnchor))
                                case .process(let group):
                                    ConversationProcessView(group: group, isCurrent: group.id == currentProcessID)
                                        .equatable()
                                        .background(messageEntryOffsetReader(id: entry.id, isAnchor: entry.id == prependAnchor))
                                case .fileChanges(let group):
                                    FileChangeSummaryCard(group: group)
                                        .background(messageEntryOffsetReader(id: entry.id, isAnchor: entry.id == prependAnchor))
                                }
                            }
                            // A vertical ScrollView must not derive its document
                            // width from a long Markdown line or a process row's
                            // intrinsic size. Keep every timeline entry inside
                            // the detail viewport so icons, text and controls do
                            // not slide underneath the conversation-list divider.
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(entry.id)
                        }

                        if !latestChildTasks.isEmpty {
                            CollaborationTaskSummaryView(tasks: latestChildTasks)
                                .id("latest-collaboration-summary")
                        }

                        if isThinking && currentProcessID == nil {
                            ThinkingIndicator()
                                .id("persistent-thinking-indicator")
                        }
                        }
                            // The scroll container proposes its available width
                            // to the document. Never feed the measured clip width
                            // back into its own layout: that locks the initial
                            // 600-point viewport in place and races live resizing.
                            .frame(
                                maxWidth: .infinity,
                                alignment: .leading
                            )
                            .padding(timelinePadding)
                            .background(scrollLatestObserver)
                        }
                        // The timeline is vertical-only. Explicitly occupy the
                        // complete detail pane so collapsing a sidebar or live
                        // resizing the window also moves the scrollbar instead
                        // of leaving the ScrollView at its previous ideal width.
                        .frame(width: viewportWidth)
                        .frame(maxHeight: .infinity, alignment: .leading)
                        // `.bottom` also centers horizontally (x = 0.5), which
                        // shifts a wide timeline to the right in the third
                        // column and clips its trailing controls. This scroll
                        // view is vertical-only, so pin the unused axis left.
                        .defaultScrollAnchor(isAtLatest ? .bottomLeading : .topLeading)
                        .id(viewportResetID)
                        .onChange(of: visibleMessageLimit) { _, _ in
                            guard let (id, alignment) = scrollViewportController.pendingAnchor else { return }
                            scrollViewportController.pendingAnchor = nil
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                proxy.scrollTo(id, anchor: alignment)
                            }
                        }

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            if messages.isEmpty && isLoading && showDelayedLoadingIndicator {
                ConversationLoadingView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            }

            if hasNewContentBelow && !isAtLatest {
                Button {
                    jumpToBottom()
                } label: {
                    Label("回到最新", systemImage: "arrow.down")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(.quaternary))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                .padding(.trailing, 18)
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            isAtLatest = true
            hasUnseenUpdates = false
            hasNewContentBelow = false
            positionInitialHistoryIfNeeded()
        }
        .task(id: isLoading) {
            showDelayedLoadingIndicator = false
            guard isLoading, messages.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, isLoading, messages.isEmpty else { return }
            showDelayedLoadingIndicator = true
        }
        .onChange(of: messages.last?.id) { _, _ in
            if !positionInitialHistoryIfNeeded() {
                handleNewMessage()
            }
        }
        .onChange(of: collaborationTasks) { oldTasks, newTasks in
            guard oldTasks != newTasks, !newTasks.isEmpty else { return }
            if isAtLatest {
                jumpToBottom()
            } else {
                hasUnseenUpdates = true
                hasNewContentBelow = true
            }
        }
        .onChange(of: streamingScrollToken) { _, _ in
            markNewContent()
        }
        .onChange(of: isThinking) { _, active in
            guard active else { return }
            if isAtLatest {
                jumpToBottom()
            } else {
                hasUnseenUpdates = true
                hasNewContentBelow = true
            }
        }
        .onChange(of: isAtLatest) { _, latest in
            if latest {
                hasUnseenUpdates = false
                hasNewContentBelow = false
            } else {
                hasNewContentBelow = hasUnseenUpdates
            }
        }
    }

    private var scrollLatestObserver: ScrollLatestObserver {
        ScrollLatestObserver(
            isAtLatest: $isAtLatest,
            viewportController: scrollViewportController,
            onHistoryRequested: { loadEarlierMessages(in: scrollViewportController.timeline.entries(from: messages)) }
        )
    }

    private func prependAnchorID(in entries: [ConversationTimelineEntry]) -> String? {
        // The automatic load trigger is rendered immediately before the current suffix.
        // Its first entry is therefore the exact boundary that must remain
        // fixed while older entries are inserted above it.
        entries.suffix(visibleMessageLimit).first?.id
    }

    private func loadEarlierMessages(in entries: [ConversationTimelineEntry]) {
        guard entries.count > visibleMessageLimit else { return }
        let anchorID = prependAnchorID(in: entries)
        let alignment = scrollViewportController.prependAlignment(for: anchorID)
        scrollViewportController.pendingAnchor = anchorID.map { ($0, alignment) }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            visibleMessageLimit = min(entries.count, visibleMessageLimit + messageBatchSize)
        }
    }

    @ViewBuilder
    private func messageEntryOffsetReader(id: String, isAnchor: Bool) -> some View {
        if isAnchor {
            MessageHistoryProbe(controller: scrollViewportController, role: .anchor(id))
        }
    }

    private func handleNewMessage() {
        guard let last = messages.last else { return }
        if last.role == .user {
            jumpToBottom()
        } else {
            markNewContent()
        }
    }

    /// A newly selected conversation often mounts while its history is still
    /// loading. The default scroll anchor only applies to the empty viewport;
    /// when the first history snapshot arrives later, explicitly recreate the
    /// viewport once so that selection opens at the latest message. Subsequent
    /// refreshes keep the user's reading position.
    @discardableResult
    private func positionInitialHistoryIfNeeded() -> Bool {
        guard !hasPositionedInitialHistory, !messages.isEmpty else { return false }
        hasPositionedInitialHistory = true
        jumpToBottom()
        return true
    }

    private func markNewContent() {
        guard !messages.isEmpty else { return }
        hasUnseenUpdates = true
        hasNewContentBelow = !isAtLatest
    }

    private func jumpToBottom() {
        // Recreate the bounded 12-entry viewport with a declarative bottom
        // anchor. This is an instant jump and deliberately avoids ScrollView
        // position bindings / proxy scrolling, both of which can create a
        // persistent SwiftUI focus-layout feedback loop on very long content.
        isAtLatest = true
        hasUnseenUpdates = false
        viewportResetID = UUID()
        hasNewContentBelow = false
    }

    private var streamingScrollToken: String {
        guard let last = messages.last else { return "empty" }
        return "\(messages.count):\(last.id):\(last.text.count):\(last.isStreaming)"
    }
}

private struct CollaborationTaskSummaryView: View, Equatable {
    let tasks: [CollaborationChildTask]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(.mint)
                Text("并行子任务 · \(tasks.count)")
                    .font(.callout.weight(.semibold))
                Spacer()
            }
            ForEach(tasks) { task in
                HStack(spacing: 8) {
                    Circle()
                        .fill(color(task))
                        .frame(width: 7, height: 7)
                    Text(task.name)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if task.isRunning { ProgressView().controlSize(.mini) }
                    Text(task.status)
                        .foregroundStyle(color(task))
                }
                .font(.caption)
            }
        }
        .padding(13)
        .background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("并行子任务，\(tasks.map { "\($0.name)，\($0.status)" }.joined(separator: "；"))")
    }

    private func color(_ task: CollaborationChildTask) -> Color {
        if task.hasFailed { return .red }
        if task.isRunning { return .blue }
        if task.status == "已停止" { return .orange }
        if task.status == "已完成" { return .green }
        return .secondary
    }
}

private struct ConversationLoadingView: View {
    var body: some View {
        VStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.11))
                    .frame(width: 46, height: 46)
                Circle()
                    .stroke(Color.accentColor.opacity(0.20), lineWidth: 1)
                    .frame(width: 46, height: 46)
                ProgressView()
                    .controlSize(.regular)
                    .tint(.accentColor)
            }

            VStack(spacing: 5) {
                Text("正在读取会话")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("正在同步消息与执行记录…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 22)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 14, y: 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在读取会话，正在同步消息与执行记录")
    }
}


enum HistoryAutoLoad {
    /// The trigger enters from above as the reader approaches the oldest
    /// rendered message. Allow a small preload band so the next batch is ready
    /// before the user reaches the absolute scroll limit.
    static func triggerIsVisible(_ frame: CGRect?) -> Bool {
        guard let frame, !frame.isNull, !frame.isInfinite else { return false }
        return frame.maxY >= 0 && frame.minY <= 80
    }
}


private struct ThinkingIndicator: View {
    var body: some View {
        HStack(spacing: 11) {
            ProgressView()
                .controlSize(.small)
                .tint(.blue)

            Image(systemName: "sparkles")
                .foregroundStyle(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("思考中…")
                    .font(.callout.weight(.semibold))
                Text("Codex 正在继续处理当前任务")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Text("进行中")
                .font(.caption.weight(.medium))
                .foregroundStyle(.blue)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.blue.opacity(0.22))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("思考中，Codex 正在继续处理当前任务")
    }
}

/// Observes AppKit's clip view instead of feeding scroll offsets through
/// SwiftUI preferences. It only publishes when the bottom/not-bottom state
/// actually changes, avoiding continuous layout invalidation while streaming.
private struct ScrollLatestObserver: NSViewRepresentable {
    @Binding var isAtLatest: Bool
    var viewportController: MessageScrollViewportController? = nil
    var onHistoryRequested: (() -> Void)? = nil

    func makeNSView(context: Context) -> ScrollLatestProbeView {
        let view = ScrollLatestProbeView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: ScrollLatestProbeView, context: Context) {
        update(nsView)
    }

    static func dismantleNSView(_ nsView: ScrollLatestProbeView, coordinator: ()) {
        nsView.disconnect()
    }

    private func update(_ view: ScrollLatestProbeView) {
        view.viewportController = viewportController
        view.onHistoryRequested = onHistoryRequested
        viewportController?.onHistoryRequested = { [weak view] in
            view?.onHistoryRequested?()
        }
        view.onLatestChanged = { latest in
            if isAtLatest != latest {
                isAtLatest = latest
            }
        }
        viewportController?.onLatestChanged = { [weak view] latest in
            view?.onLatestChanged?(latest)
        }
        view.connectWhenReady()
    }
}

final class ScrollLatestProbeView: NSView {
    var onLatestChanged: ((Bool) -> Void)?
    var onHistoryRequested: (() -> Void)?
    weak var viewportController: MessageScrollViewportController?

    private weak var observedScrollView: NSScrollView?
    private var observationTokens: [NSObjectProtocol] = []
    private var lastReportedValue: Bool?
    private var connectionGeneration = 0
    private var connectionScheduled = false
    private var positionReportScheduled = false

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        connectWhenReady()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { disconnect() } else { connectWhenReady() }
    }

    func connectWhenReady() {
        guard !connectionScheduled else { return }
        connectionScheduled = true
        let generation = connectionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connectionGeneration == generation else { return }
            self.connectionScheduled = false
            guard self.window != nil else { return }
            self.connectToEnclosingScrollView()
        }
    }

    func disconnect() {
        connectionGeneration += 1
        connectionScheduled = false
        positionReportScheduled = false
        lastReportedValue = nil
        observationTokens.forEach { NotificationCenter.default.removeObserver($0) }
        observationTokens.removeAll()
        observedScrollView = nil
    }

    deinit {
        disconnect()
    }

    private func connectToEnclosingScrollView() {
        var ancestor = superview
        while let view = ancestor, !(view is NSScrollView) {
            ancestor = view.superview
        }
        guard let scrollView = ancestor as? NSScrollView else { return }
        guard observedScrollView !== scrollView else {
            viewportController?.attach(scrollView)
            schedulePositionReport()
            return
        }

        disconnect()
        observedScrollView = scrollView
        viewportController?.attach(scrollView)

        let center = NotificationCenter.default
        scrollView.postsFrameChangedNotifications = true
        observationTokens.append(center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView,
            queue: .main
        ) { [weak self] _ in
            self?.schedulePositionReport()
        })
        scrollView.contentView.postsFrameChangedNotifications = true
        observationTokens.append(center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.schedulePositionReport()
        })
        scrollView.contentView.postsBoundsChangedNotifications = true
        observationTokens.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.schedulePositionReport()
        })

        if let documentView = scrollView.documentView {
            documentView.postsFrameChangedNotifications = true
            observationTokens.append(center.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: documentView,
                queue: .main
            ) { [weak self] _ in
                self?.schedulePositionReport()
            })
        }
        schedulePositionReport()
    }

    private func schedulePositionReport() {
        guard !positionReportScheduled else { return }
        positionReportScheduled = true
        let generation = connectionGeneration
        // Bounds/frame notifications also fire inside SwiftUI's layout and
        // CA commit. Scrolling the clip view from that callback re-enters the
        // same layout while a conversation is being replaced.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connectionGeneration == generation else { return }
            self.positionReportScheduled = false
            self.reportCurrentPosition()
        }
    }

    private func reportCurrentPosition() {
        guard window != nil, let scrollView = observedScrollView,
              let documentView = scrollView.documentView else { return }
        // This timeline is vertically scrollable only. A previously oversized
        // document can leave AppKit's clip view with a stale horizontal origin
        // after the content is narrowed, shifting every row right and clipping
        // trailing controls. Reset x without disturbing the reading position.
        let leadingX = documentView.bounds.minX
        let currentOrigin = scrollView.contentView.bounds.origin
        if abs(currentOrigin.x - leadingX) > 0.5 {
            scrollView.contentView.scroll(to: NSPoint(x: leadingX, y: currentOrigin.y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        let visibleRect = scrollView.documentVisibleRect
        let documentBounds = documentView.bounds
        let threshold: CGFloat = 28
        let remaining = documentView.isFlipped
            ? documentBounds.maxY - visibleRect.maxY
            : visibleRect.minY - documentBounds.minY
        let latest = remaining <= threshold
        if let viewportController {
            viewportController.reportHistoryPosition()
            return
        }
        guard latest != lastReportedValue else { return }
        lastReportedValue = latest
        let generation = connectionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.connectionGeneration == generation else { return }
            self.onLatestChanged?(latest)
        }
    }
}

enum HistoryPrependGeometry {
    static func windowAnchorLockedOrigin(
        currentOrigin: CGFloat,
        anchorDisplacement: CGFloat,
        documentIsFlipped: Bool
    ) -> CGFloat {
        // Scroll toward earlier content by exactly the old anchor's measured
        // viewport offset. SwiftUI currently hosts this in a non-flipped
        // document, where moving visually upward increases the AppKit origin.
        return documentIsFlipped
            ? currentOrigin - anchorDisplacement
            : currentOrigin + anchorDisplacement
    }

    static func lockedOrigin(
        baselineOrigin: CGFloat,
        baselineDocumentHeight: CGFloat,
        currentDocumentHeight: CGFloat,
        documentIsFlipped: Bool
    ) -> CGFloat {
        let insertedHeight = currentDocumentHeight - baselineDocumentHeight
        return documentIsFlipped
            ? baselineOrigin + insertedHeight
            : baselineOrigin - insertedHeight
    }
}


private struct MessageBubble: View, Equatable {
    @EnvironmentObject private var model: AppModel
    let message: ChatMessage
    let availableWidth: CGFloat

    var body: some View {
        MessageBubbleContent(message: message, availableWidth: availableWidth,
            isEditing: message.role == .user && model.isEditingInterruptedMessage(message.id))
            .equatable()
    }

    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message == rhs.message && abs(lhs.availableWidth - rhs.availableWidth) < 0.5
    }
}

private struct MessageBubbleContent: View, Equatable {
    let message: ChatMessage
    let availableWidth: CGFloat
    let isEditing: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message && abs(lhs.availableWidth - rhs.availableWidth) < 0.5
            && lhs.isEditing == rhs.isEditing
    }

    private var userLeadingSpacer: CGFloat {
        min(70, max(16, availableWidth * 0.12))
    }

    private var messageColumnMaximumWidth: CGFloat {
        let reservedWidth: CGFloat
        if message.role == .user {
            // Leading breathing room, two HStack gaps and the avatar.
            reservedWidth = userLeadingSpacer + 16 + 26
        } else {
            // Sparkle icon, two gaps and the trailing spacer.
            reservedWidth = 26 + 16 + 30
        }
        return min(
            UserMessagePresentation.maximumBubbleWidth,
            max(180, availableWidth - reservedWidth)
        )
    }

    @ViewBuilder
    var body: some View {
        if message.id == "turn-progress" {
            ProcessingBubble(message: message)
        } else if message.role == .activity {
            ActivityBubble(message: message)
        } else {
            HStack(alignment: .top) {
                if message.role == .user { Spacer(minLength: userLeadingSpacer) }
                if message.role == .assistant {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.blue)
                        .frame(width: 26, height: 26)
                        .background(.blue.opacity(0.1), in: Circle())
                }
                Group {
                    if message.role == .user {
                        // Keep the user's messages on the familiar right side
                        // and give them a calm blue surface distinct from AI replies.
                        VStack(alignment: .trailing, spacing: 6) {
                            if isEditing {
                                InterruptedMessageEditor(message: message)
                            } else {
                                bubbleSurface {
                                    UserMessageContent(
                                        message: message,
                                        maximumContentWidth: max(
                                            80,
                                            messageColumnMaximumWidth
                                                - UserMessagePresentation.bubbleHorizontalPadding * 2
                                        )
                                    )
                                }
                            }
                            UserMessageFooter(message: message)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            bubbleSurface {
                                Group {
                                    if message.isStreaming {
                                        StreamingMarkdownContent(text: message.text, contentWidth: messageColumnMaximumWidth - 28)
                                    } else {
                                        AssistantMessageContent(text: message.text, contentWidth: messageColumnMaximumWidth - 28)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            MessageMetadataFooter(message: message)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                    .frame(
                        maxWidth: messageColumnMaximumWidth,
                        alignment: message.role == .user ? .trailing : .leading
                    )
                if message.role == .user {
                    Image(systemName: "person.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .background(.quaternary.opacity(0.75), in: Circle())
                } else {
                    Spacer(minLength: 30)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var background: some ShapeStyle {
        if message.role == .user {
            return AnyShapeStyle(Color.accentColor.opacity(0.18))
        }
        return AnyShapeStyle(Color.gray.opacity(0.18))
    }

    private func bubbleSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(.primary)
            .background(background, in: RoundedRectangle(cornerRadius: 13))
    }

}

private struct FileChangeSummaryCard: View {
    @EnvironmentObject private var model: AppModel
    let group: ConversationFileChangeGroup

    var body: some View {
        FileChangeSummaryContent(
            group: group,
            isReverted: model.isFileChangeTurnReverted(group.turnID),
            isReverting: model.isRevertingFileChangeTurn(group.turnID),
            isProcessing: model.isSelectedThreadProcessing,
            onUndo: { Task { await model.revertFileChanges(group) } }
        ).equatable()
    }
}

// Only the adapter above subscribes to the broad AppModel. Offscreen file
// cards retain their body/layout when quota, polling or composer state changes.
private struct FileChangeSummaryContent: View, Equatable {
    let group: ConversationFileChangeGroup
    let isReverted: Bool
    let isReverting: Bool
    let isProcessing: Bool
    let onUndo: () -> Void
    @State private var reviewRequest: FileChangeReviewRequest?
    @State private var showingUndoConfirmation = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.group == rhs.group && lhs.isReverted == rhs.isReverted
            && lhs.isReverting == rhs.isReverting && lhs.isProcessing == rhs.isProcessing
    }

    private var hasRevertableDiff: Bool { group.changes.contains { !$0.diff.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, height: 42)
                    .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text(isReverted ? "已撤销 \(group.changes.count) 个文件的修改" : "已编辑 \(group.changes.count) 个文件")
                        .font(.headline)
                    HStack(spacing: 5) {
                        Text("+\(group.addedLines)").foregroundStyle(.green)
                        Text("−\(group.deletedLines)").foregroundStyle(.red)
                    }
                    .font(.callout.monospacedDigit())
                }

                Spacer(minLength: 12)

                Button {
                    showingUndoConfirmation = true
                } label: {
                    if isReverting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label(isReverted ? "已撤销" : "撤销", systemImage: "arrow.uturn.backward")
                    }
                }
                .buttonStyle(.plain)
                .disabled(isReverted || isReverting || !hasRevertableDiff || isProcessing)
                .help(hasRevertableDiff ? "安全检查通过后反向应用本轮补丁" : "该会话没有返回可撤销的差异")

                Button("审核") {
                    reviewRequest = FileChangeReviewRequest(group: group)
                }
                    .buttonStyle(.bordered)
            }
            .padding(16)

            Divider()

            VStack(spacing: 0) {
                ForEach(Array(group.changes.enumerated()), id: \.element.id) { index, change in
                    Button {
                        reviewRequest = FileChangeReviewRequest(
                            group: ConversationFileChangeGroup(
                                turnID: group.turnID,
                                changes: [change]
                            )
                        )
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: change.kind == .add ? "doc.badge.plus" : (change.kind == .delete ? "doc.badge.minus" : "doc.text"))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(change.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 12)
                            Text("+\(change.addedLines)")
                                .foregroundStyle(.green)
                            Text("−\(change.deletedLines)")
                                .foregroundStyle(.red)
                        }
                        .font(.callout.monospacedDigit())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < group.changes.count - 1 { Divider().padding(.leading, 46) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
        .sheet(item: $reviewRequest) { request in
            FileChangeReviewSheet(group: request.group)
        }
        .confirmationDialog(
            "撤销本轮文件修改？",
            isPresented: $showingUndoConfirmation,
            titleVisibility: .visible
        ) {
            Button("撤销 \(group.changes.count) 个文件的修改", role: .destructive) {
                onUndo()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("CloudCodex 会先确认所有文件仍与本轮补丁一致，再一次性反向应用；检查不通过时不会修改任何文件。")
        }
    }
}

private struct FileChangeReviewRequest: Identifiable {
    let id = UUID()
    let group: ConversationFileChangeGroup
}

private struct FileChangeReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let group: ConversationFileChangeGroup

    private static let minimumSize = NSSize(width: 860, height: 520)
    private static let defaultSize = NSSize(width: 1_120, height: 720)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("审核文件修改").font(.title3.weight(.semibold))
                    Text("\(group.changes.count) 个文件 · +\(group.addedLines) −\(group.deletedLines)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)

            Divider()

            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(group.changes) { change in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack {
                                Text(change.path)
                                    .font(.callout.weight(.semibold))
                                    .textSelection(.enabled)
                                Spacer(minLength: 20)
                                Text("+\(change.addedLines)").foregroundStyle(.green)
                                Text("−\(change.deletedLines)").foregroundStyle(.red)
                            }
                            .font(.caption.monospacedDigit())
                            .padding(12)
                            .frame(minWidth: 760, alignment: .leading)
                            .background(.quaternary.opacity(0.55))

                            if change.diff.isEmpty {
                                Text("该文件没有返回可展示的文本差异。")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .padding(14)
                            } else {
                                UnifiedDiffCodeView(diff: change.diff)
                            }
                        }
                        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                    }
                }
                .padding(18)
            }
        }
        .frame(
            minWidth: Self.minimumSize.width,
            idealWidth: Self.defaultSize.width,
            minHeight: Self.minimumSize.height,
            idealHeight: Self.defaultSize.height
        )
        .background(
            FileChangeReviewWindowConfigurator(
                minimumSize: Self.minimumSize,
                defaultSize: Self.defaultSize
            )
        )
    }
}

private struct FileChangeReviewWindowConfigurator: NSViewRepresentable {
    let minimumSize: NSSize
    let defaultSize: NSSize

    func makeNSView(context: Context) -> FileChangeReviewWindowProbe {
        let view = FileChangeReviewWindowProbe()
        update(view)
        return view
    }

    func updateNSView(_ view: FileChangeReviewWindowProbe, context: Context) {
        update(view)
    }

    static func dismantleNSView(_ view: FileChangeReviewWindowProbe, coordinator: ()) {
        view.disconnect()
    }

    private func update(_ view: FileChangeReviewWindowProbe) {
        view.minimumSize = minimumSize
        view.defaultSize = defaultSize
        view.connectWhenReady()
    }
}

private final class FileChangeReviewWindowProbe: NSView {
    private static let widthKey = "cloudcodex.fileChangeReviewWindowWidth"
    private static let heightKey = "cloudcodex.fileChangeReviewWindowHeight"

    var minimumSize = NSSize(width: 860, height: 520)
    var defaultSize = NSSize(width: 1_120, height: 720)

    private weak var observedWindow: NSWindow?
    private var resizeObservations: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        connectWhenReady()
    }

    func connectWhenReady() {
        DispatchQueue.main.async { [weak self] in self?.connect() }
    }

    func disconnect() {
        persistCurrentSize()
        resizeObservations.forEach { NotificationCenter.default.removeObserver($0) }
        resizeObservations.removeAll()
        observedWindow = nil
    }

    deinit {
        disconnect()
    }

    private func connect() {
        guard let window, observedWindow !== window else { return }
        disconnect()
        observedWindow = window

        window.styleMask.insert(.resizable)
        window.contentMinSize = minimumSize
        window.contentMaxSize = NSSize(width: 10_000, height: 10_000)
        window.standardWindowButton(.zoomButton)?.isEnabled = true

        let defaults = UserDefaults.standard
        let savedWidth = defaults.double(forKey: Self.widthKey)
        let savedHeight = defaults.double(forKey: Self.heightKey)
        let restoredSize = NSSize(
            width: max(minimumSize.width, savedWidth > 0 ? savedWidth : defaultSize.width),
            height: max(minimumSize.height, savedHeight > 0 ? savedHeight : defaultSize.height)
        )
        window.setContentSize(restoredSize)

        let center = NotificationCenter.default
        resizeObservations.append(center.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in self?.persistCurrentSize() })
        if let contentView = window.contentView {
            contentView.postsFrameChangedNotifications = true
            resizeObservations.append(center.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: contentView,
                queue: .main
            ) { [weak self] _ in self?.persistCurrentSize() })
        }
        persistCurrentSize()
    }

    private func persistCurrentSize() {
        guard let size = observedWindow?.contentView?.bounds.size else { return }
        let width = max(minimumSize.width, size.width)
        let height = max(minimumSize.height, size.height)
        let defaults = UserDefaults.standard
        defaults.set(width, forKey: Self.widthKey)
        defaults.set(height, forKey: Self.heightKey)
    }
}

private struct UnifiedDiffCodeView: View {
    let diff: String

    var body: some View {
        let lines = UnifiedDiffPresentation.lines(from: diff)
        ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(lines) { line in
                        backgroundColor(for: line.kind)
                            .frame(minWidth: 760, minHeight: 22, maxHeight: 22)
                    }
                }

                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(lines) { line in
                            HStack(spacing: 0) {
                                Text(line.oldLine.map(String.init) ?? "")
                                    .frame(width: 44, alignment: .trailing)
                                Text(line.newLine.map(String.init) ?? "")
                                    .frame(width: 44, alignment: .trailing)
                            }
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(foregroundColor(for: line.kind))
                            .frame(height: 22)
                        }
                    }
                    .frame(width: 88)
                    .fixedSize(horizontal: true, vertical: true)

                    ZStack(alignment: .topLeading) {
                        HStack(alignment: .top, spacing: 0) {
                            VStack(spacing: 0) {
                                ForEach(lines) { line in
                                    ZStack(alignment: .leading) {
                                        Rectangle()
                                            .fill(markerColor(for: line.kind))
                                            .frame(width: 3)
                                        Text(markerSymbol(for: line.kind))
                                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                                            .foregroundStyle(foregroundColor(for: line.kind))
                                            .frame(width: 24, alignment: .trailing)
                                    }
                                    .frame(height: 22)
                                    .allowsHitTesting(false)
                                }
                            }
                            .frame(width: 28)
                            .fixedSize(horizontal: true, vertical: true)

                            ReliableSelectableAttributedText(
                                text: UnifiedDiffTextDocument.attributed(from: lines),
                                maximumWidth: 20_000
                            )
                            .fixedSize(horizontal: true, vertical: true)

                            Spacer(minLength: 18)
                        }

                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(lines) { line in
                                Text(line.kind == .hunk ? line.text : "")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Color.blue)
                                    .frame(height: 22, alignment: .leading)
                            }
                        }
                        .padding(.leading, 28)
                        .allowsHitTesting(false)
                    }
                }
            }
            .frame(minWidth: 760, alignment: .leading)
            .fixedSize(horizontal: true, vertical: true)
        }
        .background(Color.black.opacity(0.08))
    }

    private func markerColor(for kind: DiffDisplayLine.Kind) -> Color {
        switch kind {
        case .addition: return .green
        case .deletion: return .red
        case .hunk: return .blue
        case .metadata, .context: return .clear
        }
    }

    private func markerSymbol(for kind: DiffDisplayLine.Kind) -> String {
        switch kind {
        case .addition: return "+"
        case .deletion: return "−"
        case .metadata, .hunk, .context: return ""
        }
    }

    private func foregroundColor(for kind: DiffDisplayLine.Kind) -> Color {
        switch kind {
        case .addition: return .green
        case .deletion: return .red
        case .hunk: return .blue
        case .metadata: return .secondary
        case .context: return .primary
        }
    }

    private func backgroundColor(for kind: DiffDisplayLine.Kind) -> Color {
        switch kind {
        case .addition: return .green.opacity(0.12)
        case .deletion: return .red.opacity(0.12)
        case .hunk: return .blue.opacity(0.10)
        case .metadata: return .secondary.opacity(0.035)
        case .context: return .clear
        }
    }
}

private struct InterruptedMessageEditor: View {
    @EnvironmentObject private var model: AppModel
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !message.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                            MessageAttachmentCard(attachment: attachment)
                        }
                    }
                }
            }

            ComposerTextEditor(
                text: $model.interruptedMessageEditText,
                pasteImages: { false },
                submit: { Task { await model.submitInterruptedMessageEdit() } },
                focusRequest: model.interruptedMessageEditFocusRequest
            )
            .frame(minHeight: 86, maxHeight: 180)

            if let error = model.interruptedMessageEdit?.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Label("重新执行不会撤销上一轮已产生的文件修改", systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 12)
                Button("取消", action: model.cancelInterruptedMessageEdit)
                    .disabled(model.interruptedMessageEdit?.isSubmitting == true)
                Button {
                    Task { await model.submitInterruptedMessageEdit() }
                } label: {
                    if model.interruptedMessageEdit?.isSubmitting == true {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("发送")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSubmitInterruptedMessageEdit)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.gray.opacity(0.18), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.quaternary))
    }
}

private struct MessageMetadataFooter: View {
    let message: ChatMessage

    var body: some View {
        if message.modelUsageLabel != nil || message.timestamp != nil {
            HStack(spacing: 9) {
                if let modelUsageLabel = message.modelUsageLabel {
                    Label(modelUsageLabel, systemImage: "cpu")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                        .accessibilityLabel("本轮使用模型 \(modelUsageLabel)")
                }
                if let timestamp = message.timestamp {
                    Label(MessageTimeFormatter.string(from: timestamp), systemImage: "clock")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel("消息时间 \(MessageTimeFormatter.accessibilityString(from: timestamp))")
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
        }
    }
}

private struct UserMessageFooter: View {
    @EnvironmentObject private var model: AppModel
    let message: ChatMessage

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                editButton
                Spacer(minLength: 0)
                MessageMetadataFooter(message: message)
            }
            VStack(alignment: .trailing, spacing: 6) {
                editButton
                MessageMetadataFooter(message: message)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .font(.caption2.weight(.medium))
    }

    @ViewBuilder
    private var editButton: some View {
        if !model.isEditingInterruptedMessage(message.id),
           model.canEditInterruptedMessage(message) {
            Button {
                model.beginEditingInterruptedMessage(message)
            } label: {
                Label("编辑并重新执行", systemImage: "pencil")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("撤回已停止的最后一轮，修改后重新执行；不会回滚已经修改的本地文件")
        }
    }
}

private enum MessageTimeFormatter {
    static func string(from date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(.dateTime.hour().minute())
        }
        if calendar.isDateInYesterday(date) {
            return "昨天 " + date.formatted(.dateTime.hour().minute())
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
        return date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute())
    }

    static func accessibilityString(from date: Date) -> String {
        date.formatted(.dateTime.year().month().day().hour().minute())
    }
}

private struct AssistantMessageContent: View {
    let text: String
    var contentWidth: CGFloat? = nil

    var body: some View {
        if text.count > LongAssistantMessageView.pageSize {
            LongAssistantMessageView(text: text, contentWidth: contentWidth)
        } else {
            MarkdownMessageView(markdown: text, contentWidth: contentWidth).equatable()
        }
    }
}

/// Very long final replies can contain hundreds of Markdown blocks. Building
/// all of them at once causes a large one-off CPU and memory spike even though
/// only a small part is visible. Render one bounded Markdown page at a time so
/// headings, lists, links and code retain their formatting without the spike.
private struct LongAssistantMessageView: View {
    static let pageSize = 8_000

    let text: String
    let contentWidth: CGFloat?
    @State private var page: Int

    init(text: String, contentWidth: CGFloat?) {
        self.text = text
        self.contentWidth = contentWidth
        let lastPage = max(0, (text.count - 1) / Self.pageSize)
        _page = State(initialValue: lastPage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MarkdownMessageView(markdown: pageText, contentWidth: contentWidth).equatable()
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            HStack(spacing: 10) {
                Label(
                    "长回复性能模式 · 第 \(boundedPage + 1) / \(totalPages) 页",
                    systemImage: "doc.text.magnifyingglass"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    page = max(0, boundedPage - 1)
                } label: {
                    Label("上一页", systemImage: "chevron.left")
                }
                .disabled(boundedPage == 0)

                Button {
                    page = min(totalPages - 1, boundedPage + 1)
                } label: {
                    Label("下一页", systemImage: "chevron.right")
                }
                .disabled(boundedPage >= totalPages - 1)

                Button("复制全文") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
    }

    private var totalPages: Int {
        pages.count
    }

    private var boundedPage: Int {
        min(max(0, page), totalPages - 1)
    }

    private var pageText: String {
        pages[boundedPage]
    }

    private var pages: [String] {
        MarkdownPageWindow.pages(text, limit: Self.pageSize)
    }
}

enum UserMessagePresentation {
    static let collapsedLineLimit = 8
    static let collapsedCharacterLimit = 600
    static let maximumBubbleWidth: CGFloat = 720
    static let bubbleHorizontalPadding: CGFloat = 14
    static let maximumContentWidth = maximumBubbleWidth - bubbleHorizontalPadding * 2

    static func shouldCollapse(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let lineCount = text.lazy.filter { $0 == "\n" }.count + 1
        return text.count > collapsedCharacterLimit || lineCount > collapsedLineLimit
    }

    static func collapsedText(_ text: String) -> String {
        guard shouldCollapse(text) else { return text }
        let lines = text.components(separatedBy: .newlines)
        var value = lines.prefix(collapsedLineLimit).joined(separator: "\n")
        if value.count > collapsedCharacterLimit {
            value = String(value.prefix(collapsedCharacterLimit))
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

private struct UserMessageContent: View {
    let message: ChatMessage
    let maximumContentWidth: CGFloat
    @State private var isExpanded = false

    private var displayedText: String {
        isExpanded ? message.text : UserMessagePresentation.collapsedText(message.text)
    }

    @ViewBuilder
    var body: some View {
        let content = VStack(alignment: .leading, spacing: 10) {
            if !message.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
                            MessageAttachmentCard(attachment: attachment)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    let selectableText = ReliableSelectableText(
                        text: displayedText,
                        maximumWidth: maximumContentWidth
                    )

                    if message.attachments.isEmpty {
                        selectableText
                            .frame(maxWidth: maximumContentWidth, alignment: .leading)
                    } else {
                        // Attachment rows already establish a card-like
                        // message. Use the final measured content width instead
                        // of accepting HStack's provisional narrow proposal;
                        // otherwise text and metadata collapse into a thin
                        // vertical strip in the third column.
                        selectableText
                            .frame(width: maximumContentWidth, alignment: .leading)
                    }

                    if UserMessagePresentation.shouldCollapse(message.text) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            Label(
                                isExpanded ? "收起" : "展开全文",
                                systemImage: isExpanded ? "chevron.up" : "chevron.down"
                            )
                            .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityHint(isExpanded ? "折叠这条用户消息" : "显示这条用户消息的完整内容")
                    }
                }
            }
        }

        content.fixedSize(horizontal: false, vertical: true)
    }
}

private struct MessageAttachmentCard: View {
    let attachment: ChatMessageAttachment
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: openAttachment) {
                if attachment.kind == .image,
                   let image = NSImage(contentsOfFile: attachment.path) {
                    VStack(alignment: .leading, spacing: 6) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 148, height: 92)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        Label(attachment.name, systemImage: "photo")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 148, alignment: .leading)
                    }
                    .padding(6)
                    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    Label(attachment.name, systemImage: attachment.kind == .image ? "photo" : "doc")
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: 260, alignment: .leading)
                        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))
                }
            }
            .buttonStyle(.plain)
            .help(attachment.path.isEmpty ? attachment.name : "在 CloudCodex 中预览 \(attachment.name)")

            if !attachment.path.isEmpty {
                Button(action: revealAttachment) {
                    Image(systemName: "folder")
                        .font(.caption.weight(.semibold))
                        .frame(width: 25, height: 25)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(5)
                .help("在 Finder 中显示")
            }
        }
    }

    private func openAttachment() {
        guard !attachment.path.isEmpty else { return }
        openURL(URL(fileURLWithPath: attachment.path))
    }

    private func revealAttachment() {
        guard !attachment.path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: attachment.path)])
    }
}

private struct ProcessingBubble: View {
    let message: ChatMessage

    var body: some View {
        if message.isStreaming {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(at: context.date)
            }
        } else {
            content(at: message.completedAt ?? message.startedAt ?? Date())
        }
    }

    private func content(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if message.isStreaming {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: completionIcon)
                        .foregroundStyle(completionColor)
                }

                Text(durationLabel(at: date))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(message.activityStatus ?? "进行中")
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            Divider()

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.blue)
                    .padding(.top, 1)
                Text(message.text.isEmpty ? "Codex 正在处理你的任务…" : message.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func durationLabel(at currentDate: Date) -> String {
        let start = message.startedAt ?? currentDate
        let end = message.completedAt ?? currentDate
        let elapsed = max(0, Int(end.timeIntervalSince(start)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        let duration = minutes > 0 ? "\(minutes)分钟 \(seconds)秒" : "\(seconds)秒"
        return message.isStreaming ? "已处理 \(duration)" : "处理完成，用时 \(duration)"
    }

    private var completionIcon: String {
        switch message.activityStatus {
        case "失败", "发送失败": return "exclamationmark.triangle.fill"
        case "已停止": return "stop.circle.fill"
        default: return "checkmark.circle.fill"
        }
    }

    private var completionColor: Color {
        switch message.activityStatus {
        case "失败", "发送失败": return .red
        case "已停止": return .orange
        default: return .green
        }
    }

    private var statusColor: Color {
        switch message.activityStatus {
        case "失败", "发送失败": return .red
        case "已停止": return .orange
        case "进行中": return .blue
        default: return .secondary
        }
    }
}

private struct StopCurrentTaskButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            Task { await model.cancelTurn() }
        } label: {
            Image(systemName: "stop.fill")
                .font(.caption.weight(.semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.orange)
        .background(Color.orange.opacity(0.10), in: Circle())
        .help("停止当前任务；已经完成的文件修改不会自动回滚")
        .accessibilityLabel("停止当前任务")
        .fixedSize()
    }
}

/// One compact, bounded log instead of a full-height card for every tool event.
struct ConversationProcessView: View, Equatable {
    let group: ConversationProcessGroup
    let isCurrent: Bool
    @State private var isExpanded = false
    @State private var isAtLatest = true
    @State private var logViewportID = UUID()
    @State private var requestedLatest = false

    init(group: ConversationProcessGroup, isCurrent: Bool, initiallyExpanded: Bool = false) {
        self.group = group
        self.isCurrent = isCurrent
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.group == rhs.group && lhs.isCurrent == rhs.isCurrent
    }

    private var statusPresentation: ConversationProcessStatusPresentation {
        .init(group: group, isCurrent: isCurrent)
    }

    private var currentStepPresentation: ConversationCurrentStepPresentation {
        .init(group: group)
    }

    var body: some View {
        let steps = group.steps
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    isExpanded.toggle()
                } label: {
                    HStack(alignment: .center, spacing: 9) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)

                        if isCurrent {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: group.hasFailure ? "exclamationmark.circle" : "list.bullet.rectangle")
                                .foregroundStyle(group.hasFailure ? Color.orange : .secondary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                Text("执行过程")
                                    .font(.callout.weight(.semibold))
                                    .fixedSize(horizontal: true, vertical: false)
                                Text("\(steps.count) 项")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.10), in: Capsule())
                                    .fixedSize(horizontal: true, vertical: false)
                                if let start = group.progress?.startedAt {
                                    if let end = group.progress?.completedAt {
                                        Text("\(max(0, Int(end.timeIntervalSince(start)))) 秒")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                    } else if isCurrent {
                                        Text(start, style: .timer)
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }

                            if isCurrent {
                                Label(
                                    currentStepPresentation.label,
                                    systemImage: currentStepPresentation.systemImage
                                )
                                .font(.caption.weight(.medium))
                                .foregroundStyle(currentStepPresentation.color)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(
                                    currentStepPresentation.color.opacity(0.08),
                                    in: Capsule()
                                )
                                .overlay {
                                    Capsule()
                                        .stroke(currentStepPresentation.color.opacity(0.16), lineWidth: 0.75)
                                }
                                .accessibilityLabel(currentStepPresentation.accessibilityLabel)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if isCurrent,
                           group.latestStep?.isStreaming == true,
                           let startedAt = group.latestStep?.startedAt {
                            ActivityElapsedLabel(startedAt: startedAt)
                                .fixedSize(horizontal: true, vertical: false)
                        }

                        Label(statusPresentation.label, systemImage: statusPresentation.systemImage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(statusPresentation.color)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                statusPresentation.color.opacity(0.11),
                                in: Capsule()
                            )
                            .overlay {
                                Capsule()
                                    .stroke(statusPresentation.color.opacity(0.24), lineWidth: 0.75)
                            }
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("执行过程，\(steps.count) 项，\(group.status(isCurrent: isCurrent))，\(isExpanded ? "收起" : "展开")")

                if isCurrent {
                    StopCurrentTaskButton()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if isExpanded {
                Divider()
                if steps.isEmpty {
                    ScrollView {
                        Text(group.progress?.text ?? "等待可展示的处理记录…")
                            .font(.caption)
                            .foregroundStyle(group.hasFailure ? Color.orange : .secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                    }
                    .frame(height: 64)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            if let progress = group.progress, progress.isFailedActivity {
                                Text(progress.text)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .textSelection(.enabled)
                                    .padding(.bottom, 10)
                            }
                            ForEach(steps) { message in
                                ActivityBubble(message: message, compact: true)
                                if message.id != steps.last?.id {
                                    Divider().padding(.leading, 26)
                                }
                            }
                        }
                        .padding(10)
                        .background(ScrollLatestObserver(isAtLatest: $isAtLatest))
                    }
                    .defaultScrollAnchor(requestedLatest ? .bottom : .top)
                    // Keep the viewport independent from streaming text layout.
                    // Measuring the complete log and feeding that height back
                    // into this ScrollView creates a loop: scrollbar width
                    // changes wrapping, wrapping changes the measured height,
                    // and every delta relays out the whole conversation.
                    .frame(
                        height: ProcessLogLayout.viewportHeight(
                            stepCount: steps.count,
                            includesFailureSummary: group.progress?.isFailedActivity == true
                        ),
                        alignment: .top
                    )
                    .clipped()
                    .id(logViewportID)
                    .accessibilityLabel("可滚动的执行过程")

                    HStack {
                        Text("在此区域内滚动 · 点击步骤查看详情")
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 6)
                        if !isAtLatest {
                            Button("最新步骤 ↓") {
                                isAtLatest = true
                                requestedLatest = true
                                logViewportID = UUID()
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                        }
                    }
                    .font(.caption2)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (isCurrent ? Color.blue.opacity(0.045) : group.hasFailure ? Color.orange.opacity(0.025) : Color.secondary.opacity(0.035)),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isCurrent ? Color.blue.opacity(0.18) : group.hasFailure ? Color.orange.opacity(0.16) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        }
    }

}

struct ConversationCurrentStepPresentation {
    enum Tone: Equatable {
        case active
        case warning
        case waiting
    }

    let label: String
    let accessibilityLabel: String
    let systemImage: String
    let tone: Tone

    init(group: ConversationProcessGroup) {
        if group.hasFailure {
            label = group.failureCount > 0
                ? "\(group.failureCount) 项失败 · 仍在继续"
                : "已记录失败 · 仍在继续"
            accessibilityLabel = group.failureCount > 0
                ? "已记录 \(group.failureCount) 项失败，任务仍在继续"
                : "已记录失败详情，任务仍在继续"
            systemImage = "exclamationmark.triangle.fill"
            tone = .warning
        } else if let step = group.latestStep, step.isStreaming {
            let title = step.activityTitle ?? "正在处理"
            label = "正在处理 · \(title)"
            accessibilityLabel = "当前步骤：\(title)"
            systemImage = step.activityKind?.iconName ?? "gearshape.2"
            tone = .active
        } else {
            label = "等待下一步"
            accessibilityLabel = "正在继续思考，等待下一步"
            systemImage = "ellipsis"
            tone = .waiting
        }
    }

    var color: Color {
        switch tone {
        case .active: return .blue
        case .warning: return .orange
        case .waiting: return .secondary
        }
    }
}

private struct ConversationProcessStatusPresentation {
    let label: String
    let systemImage: String
    let color: Color

    init(group: ConversationProcessGroup, isCurrent: Bool) {
        if isCurrent {
            label = group.latestStep?.isStreaming == true ? "执行中" : "思考中"
            systemImage = group.latestStep?.isStreaming == true ? "bolt.fill" : "ellipsis"
            color = .blue
        } else if group.failureCount > 0 {
            label = "\(group.failureCount) 项失败或被拒绝"
            systemImage = "exclamationmark.triangle.fill"
            color = .orange
        } else if group.hasFailure {
            label = "任务未成功"
            systemImage = "exclamationmark.triangle.fill"
            color = .orange
        } else if group.wasStopped {
            label = "已停止"
            systemImage = "stop.fill"
            color = .secondary
        } else {
            label = "已结束"
            systemImage = "checkmark"
            color = .secondary
        }
    }
}

enum ActivityWaitPresentation {
    static let longWaitThreshold: TimeInterval = 30

    static func label(startedAt: Date, now: Date) -> String {
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
        let duration = ActivityDurationPresentation.duration(
            startedAt: startedAt,
            completedAt: nil,
            now: now
        )
        return elapsed >= Int(longWaitThreshold) ? "等待较久 \(duration)" : "已等待 \(duration)"
    }

    static func isLongWait(startedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(startedAt) >= longWaitThreshold
    }
}

enum ActivityDurationPresentation {
    static func duration(startedAt: Date, completedAt: Date?, now: Date) -> String {
        let elapsed = max(0, Int((completedAt ?? now).timeIntervalSince(startedAt)))
        if elapsed >= 3_600 {
            return String(format: "%d:%02d:%02d", elapsed / 3_600, (elapsed % 3_600) / 60, elapsed % 60)
        }
        if elapsed >= 60 {
            return String(format: "%d:%02d", elapsed / 60, elapsed % 60)
        }
        return "\(elapsed) 秒"
    }

    static func label(startedAt: Date, completedAt: Date?, now: Date) -> String {
        let prefix = completedAt == nil ? "已耗时" : "耗时"
        return "\(prefix) \(duration(startedAt: startedAt, completedAt: completedAt, now: now))"
    }
}

private struct ActivityElapsedLabel: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(at: context.date)
        }
    }

    private func content(at date: Date) -> some View {
        let isLongWait = ActivityWaitPresentation.isLongWait(startedAt: startedAt, now: date)
        return Text(ActivityWaitPresentation.label(startedAt: startedAt, now: date))
            .font(.caption.monospacedDigit())
            .foregroundStyle(isLongWait ? Color.orange : Color.secondary.opacity(0.7))
            .help(isLongWait
                  ? "工具仍在运行；如果长时间没有新进度，可以点击停止后重试"
                  : "当前步骤已经运行的时间")
    }
}

private struct ActivityDurationLabel: View {
    let startedAt: Date
    let completedAt: Date?

    var body: some View {
        if completedAt == nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                label(at: context.date)
            }
        } else {
            label(at: completedAt ?? Date())
        }
    }

    private func label(at date: Date) -> some View {
        let isLongRunning = completedAt == nil
            && ActivityWaitPresentation.isLongWait(startedAt: startedAt, now: date)
        return Text(ActivityDurationPresentation.label(
            startedAt: startedAt,
            completedAt: completedAt,
            now: date
        ))
        .font(.caption2.monospacedDigit())
        .foregroundStyle(isLongRunning ? Color.orange : Color.secondary)
        .fixedSize(horizontal: true, vertical: false)
        .help(completedAt == nil ? "当前步骤从开始到现在的耗时" : "该步骤的最终耗时")
    }
}

enum ProcessLogLayout {
    static let maximumViewportHeight: CGFloat = 320
    static let minimumViewportHeight: CGFloat = 64
    static let estimatedStepHeight: CGFloat = 44
    static let verticalPadding: CGFloat = 20
    static let failureSummaryHeight: CGFloat = 44

    static func viewportHeight(stepCount: Int, includesFailureSummary: Bool) -> CGFloat {
        let rows = CGFloat(max(0, stepCount)) * estimatedStepHeight
        let failure = includesFailureSummary ? failureSummaryHeight : 0
        return min(
            maximumViewportHeight,
            max(minimumViewportHeight, rows + verticalPadding + failure)
        )
    }
}

private struct ActivityBubble: View {
    let message: ChatMessage
    let compact: Bool
    @State private var isExpanded = false
    @State private var visibleDetailLimit = 8_000

    init(message: ChatMessage, compact: Bool = false) {
        self.message = message
        self.compact = compact
        _isExpanded = State(initialValue: message.id.hasPrefix("connection-notice-"))
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            // Do not parse or lay out hidden logs, especially while streaming.
            if isExpanded && !message.text.isEmpty {
                if message.activityKind == .reasoning || message.activityKind == .plan {
                    Group {
                        if message.isStreaming {
                            StreamingMarkdownContent(text: message.text)
                        } else {
                            AssistantMessageContent(text: message.text)
                        }
                    }
                    .padding(.top, 9)
                } else if message.isStreaming {
                    Text(liveDetail)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(12)
                        .padding(.top, 9)
                } else {
                    Text(String(message.text.prefix(visibleDetailLimit)))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 9)
                    if message.text.count > visibleDetailLimit {
                        Button("显示更多输出（还剩 \(message.text.count - visibleDetailLimit) 字符）") {
                            visibleDetailLimit += 8_000
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                        .padding(.top, 6)
                    }
                }
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: message.activityKind?.iconName ?? "gearshape.2")
                    .foregroundStyle(iconColor)
                    .frame(width: 20)
                Text(message.activityTitle ?? "Codex 处理过程")
                    .font(compact ? .caption.weight(.medium) : .callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if message.isStreaming {
                    ProgressView().controlSize(.small)
                }
                if let startedAt = message.startedAt,
                   message.isStreaming || message.completedAt != nil {
                    ActivityDurationLabel(
                        startedAt: startedAt,
                        completedAt: message.isStreaming ? nil : message.completedAt
                    )
                }
                if let status = message.activityStatus {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                }
            }
        }
        .padding(.horizontal, compact ? 4 : 12)
        .padding(.vertical, compact ? 7 : 10)
        .background(Color.secondary.opacity(compact ? 0 : 0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(compact ? Color.clear : Color.secondary.opacity(0.2)))
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .clipped()
    }

    private var liveDetail: String {
        let limit = 2_000
        guard message.text.count > limit else { return message.text }
        return "…仅显示最新输出…\n" + String(message.text.suffix(limit))
    }

    private var iconColor: Color {
        switch message.activityKind {
        case .reasoning: return .purple
        case .plan: return .indigo
        case .command: return .green
        case .file: return .orange
        case .tool: return .blue
        case .web: return .cyan
        case .collaboration: return .mint
        case .warning: return .yellow
        default: return .secondary
        }
    }

    private var statusColor: Color {
        switch message.activityStatus {
        case "失败", "已拒绝": return .red
        case "已停止": return .orange
        case "进行中", "运行中": return .blue
        default: return .secondary
        }
    }
}

private enum ComposerMode {
    case conversation
    case newThread
}

enum WaitingQueueLayout {
    static let rowHeight: CGFloat = 58
    static let rowSpacing: CGFloat = 8
    static let maximumVisibleRows = 3

    static func viewportHeight(for itemCount: Int) -> CGFloat {
        let visibleRows = min(max(0, itemCount), maximumVisibleRows)
        guard visibleRows > 0 else { return 0 }
        return CGFloat(visibleRows) * rowHeight
            + CGFloat(visibleRows - 1) * rowSpacing
    }
}

private struct Composer: View {
    @EnvironmentObject private var model: AppModel
    let mode: ComposerMode
    @State private var showingModelPicker = false
    @State private var draftModelID: String?
    @State private var draftProviderID = ModelProviderLibrary.openAI
    @State private var modelSelectionError: String?
    @State private var draftEffort: String?
    @State private var draftFastMode = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if mode == .conversation, let notice = model.threadOwnershipNotice {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "macwindow.badge.plus")
                            .foregroundStyle(.orange)
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button {
                            model.threadOwnershipNotice = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.plain)
                        .help("关闭提示")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
                }

                if mode == .conversation, !model.selectedWaitingMessages.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.blue)
                                .frame(width: 26, height: 26)
                                .background(Color.blue.opacity(0.12), in: Circle())
                            Text("等待队列")
                                .font(.callout.weight(.semibold))
                            Text("\(model.selectedWaitingMessages.count) 项")
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.blue, in: Capsule())
                            Spacer(minLength: 8)
                            Label("拖动排序 · 结束后依次发送", systemImage: "arrow.up.arrow.down")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }

                        ScrollView(.vertical) {
                            LazyVStack(alignment: .leading, spacing: WaitingQueueLayout.rowSpacing) {
                                ForEach(Array(model.selectedWaitingMessages.enumerated()), id: \.element.id) { index, item in
                                    WaitingMessageQueueRow(item: item, position: index + 1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, model.selectedWaitingMessages.count > WaitingQueueLayout.maximumVisibleRows ? 5 : 0)
                        }
                        .scrollIndicators(.visible)
                        .frame(height: WaitingQueueLayout.viewportHeight(for: model.selectedWaitingMessages.count))
                        .clipped()
                    }
                    .padding(12)
                    .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.blue.opacity(0.34), lineWidth: 1)
                    )
                    .help("当前任务结束后按顺序发送。等待消息仅保留在本次应用运行期间，退出应用前请先处理。")
                }

                if !currentAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(currentAttachments) { attachment in
                                AttachmentPreview(attachment: attachment) {
                                    removeAttachment(attachment.id)
                                }
                            }
                        }
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .id(currentAttachments.map(\.id))
                    .defaultScrollAnchor(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 82)
                    .clipped()
                }

                ComposerTextEditor(
                    text: composerText,
                    pasteImages: pasteImages,
                    submit: submit,
                    focusRequest: mode == .newThread ? model.newThreadFocusRequest
                        : model.editingWaitingMessageID ?? model.replyChoiceFocusRequest,
                    suggestion: mode == .conversation ? model.composerSuggestion : nil,
                    acceptSuggestion: model.acceptComposerSuggestion
                )
                    .frame(
                        minHeight: mode == .newThread ? 110 : 54,
                        maxHeight: mode == .newThread ? 200 : 120
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if mode == .conversation, model.composerSuggestion != nil {
                            Button("Tab 采纳建议", action: model.acceptComposerSuggestion)
                                .font(.caption2).buttonStyle(.plain).foregroundStyle(.secondary)
                                .padding(4)
                        }
                    }
                    .task(id: mode == .conversation ? model.composerPredictionSource : nil) {
                        if mode == .conversation, let source = model.composerPredictionSource {
                            await model.requestComposerPrediction(source)
                        }
                    }

                if mode == .conversation, model.isExternalThreadProcessing {
                    Label("Codex 中处理中", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !model.speechStatus.isEmpty {
                    Label(model.speechStatus, systemImage: model.isRecording ? "waveform" : "mic")
                        .font(.caption)
                        .foregroundStyle(model.isRecording ? Color.blue : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isEditingWaiting {
                    HStack {
                        Text("正在编辑待发送消息 · 已暂停发送")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("取消", action: model.cancelWaitingMessageEdit)
                        Button("保存修改", action: model.saveWaitingMessageEdit)
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canSaveWaitingMessageEdit)
                    }
                } else {
                HStack(spacing: 12) {
                    Button(action: chooseAttachments) {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .help("添加图片或文件；也可按 ⌘V 直接粘贴图片")

                    if mode == .newThread {
                        Button(action: model.chooseNewThreadFolder) {
                            Label(newThreadFolderName, systemImage: "folder")
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                        .help("工作文件夹：\(model.newThreadFolder)")
                    }

                    permissionMenu

                    Spacer(minLength: 18)

                    modelMenu

                    Button(action: toggleDictation) {
                        Image(systemName: model.isRecording ? "waveform.circle.fill" : "mic")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(model.isRecording ? .red : .primary)
                            .symbolEffect(.pulse, isActive: model.isRecording)
                    }
                    .buttonStyle(.plain)
                    .help(model.isRecording ? "停止语音输入" : "语音输入")

                    if mode == .conversation, model.isSending, canSubmit {
                        Button { Task { await model.cancelTurn() } } label: {
                            Image(systemName: "stop.fill")
                        }
                        .help("停止当前任务")
                        .disabled(model.activeTurnID == nil && !model.selectedHasCapacityRetry)
                    }

                    Button {
                        submitOrCancel()
                    } label: {
                        Group {
                            if mode == .newThread, model.isCreatingThread {
                                ProgressView().controlSize(.small)
                            } else if mode == .conversation, canSubmit {
                                Image(systemName: model.isSelectedThreadProcessing ? "text.badge.plus" : "arrow.up")
                                    .font(.system(size: 17, weight: .semibold))
                            } else if mode == .conversation, model.isExternalThreadProcessing {
                                ProgressView().controlSize(.small)
                            } else if mode == .conversation, model.isSending && model.activeTurnID == nil {
                                ProgressView().controlSize(.small)
                            } else if mode == .conversation, model.isSending {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 13, weight: .semibold))
                            } else {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 17, weight: .semibold))
                            }
                        }
                        .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Circle())
                    .disabled(!canSubmit && !canCancel)
                    .help(sendButtonHelp)
                }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.quaternary))
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(.bar)
        .sheet(isPresented: $showingModelPicker) {
            modelSelectionPanel
                .interactiveDismissDisabled()
        }
    }

    private var isEditingWaiting: Bool {
        mode == .conversation && model.editingWaitingMessageID != nil
    }

    private var composerText: Binding<String> {
        Binding(
            get: { isEditingWaiting ? model.waitingMessageEditText : mode == .newThread ? model.newThreadPrompt : model.composerText },
            set: { value in
                if isEditingWaiting {
                    model.waitingMessageEditText = value
                } else if mode == .newThread {
                    model.newThreadPrompt = value
                } else {
                    model.composerText = value
                }
            }
        )
    }

    private var currentAttachments: [ComposerAttachment] {
        if isEditingWaiting {
            return model.waitingMessages.first(where: { $0.id == model.editingWaitingMessageID })?.attachments ?? []
        }
        return mode == .newThread ? model.newThreadAttachments : model.attachments
    }

    private var newThreadFolderName: String {
        let name = URL(fileURLWithPath: model.newThreadFolder).lastPathComponent
        return name.isEmpty ? "选择文件夹" : name
    }

    private var canSubmit: Bool {
        mode == .newThread ? model.canCreateThread : model.canSend
    }

    private var canCancel: Bool {
        mode == .conversation && model.isSending
    }

    private var sendButtonHelp: String {
        if mode == .newThread {
            return model.isCreatingThread ? "正在创建会话" : "创建会话并发送（Return）"
        }
        if canSubmit, model.isSelectedThreadProcessing { return "加入等待队列（Return），当前任务结束后发送" }
        if canSubmit { return "发送（Return）" }
        if model.isExternalThreadProcessing { return "此任务正在 Codex 主应用中处理" }
        return model.isSending ? "停止当前任务" : "发送（Return）"
    }

    private func chooseAttachments() {
        if mode == .newThread {
            model.chooseNewThreadAttachments()
        } else {
            model.chooseAttachments()
        }
    }

    private func removeAttachment(_ id: UUID) {
        guard !isEditingWaiting else { return }
        if mode == .newThread {
            model.removeNewThreadAttachment(id)
        } else {
            model.removeAttachment(id)
        }
    }

    private func pasteImages() -> Bool {
        if isEditingWaiting { return false }
        return mode == .newThread ? model.pasteNewThreadImages() : model.pasteImages()
    }

    private func toggleDictation() {
        if mode == .newThread {
            model.toggleNewThreadDictation()
        } else {
            model.toggleDictation()
        }
    }

    private func submit() {
        if isEditingWaiting { model.saveWaitingMessageEdit(); return }
        guard canSubmit else { return }
        Task {
            if mode == .newThread {
                await model.createThread()
            } else {
                await model.sendMessage()
            }
        }
    }

    private func submitOrCancel() {
        if mode == .conversation, model.isSending, !canSubmit {
            Task { await model.cancelTurn() }
        } else {
            submit()
        }
    }

    private var permissionMenu: some View {
        Menu {
            ForEach(model.permissionProfiles) { profile in
                Button {
                    model.selectedPermissionID = profile.id
                } label: {
                    Label {
                        Text(profile.displayName)
                    } icon: {
                        if model.selectedPermissionID == profile.id {
                            Image(systemName: "checkmark")
                        } else {
                            Image(systemName: profile.iconName)
                        }
                    }
                }
            }
        } label: {
            Label(
                model.selectedPermission?.displayName ?? "权限",
                systemImage: model.selectedPermission?.iconName ?? "shield"
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(model.selectedPermissionID == ":danger-full-access" ? .orange : .secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Codex 文件与命令权限")
    }

    private var modelMenu: some View {
        Button {
            beginModelSelection()
        } label: {
            HStack(spacing: 5) {
                Text(modelAndEffortCompactLabel)
                    .font(.callout)
                    .lineLimit(1)
                    .layoutPriority(1)
                if model.isFastModeEnabled && model.supportsFastMode {
                    Label("加速", systemImage: "bolt.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .fixedSize()
                        .layoutPriority(2)
                } else {
                    Text(model.selectedSpeedLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .layoutPriority(2)
                }
                Image(systemName: showingModelPicker ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minWidth: 0, maxWidth: 240, alignment: .trailing)
        .accessibilityLabel(modelAndEffortAccessibilityLabel)
        .help("选择模型、推理强度和响应速度")
    }

    private var draftModel: CodexModelOption? {
        draftModelID == AppModel.recommendedModelSelectionID
            ? model.recommendedModel
            : model.modelOptions.first { $0.id == draftModelID }
    }

    private var modelSelectionPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("全局模型设置").font(.headline)
                Spacer()
                Button {
                    showingModelPicker = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("取消并关闭")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("厂商", selection: $draftProviderID) {
                        Text("OpenAI（本机 Codex）").tag(ModelProviderLibrary.openAI)
                        ForEach(model.providerLibrary.profiles.filter { $0.configuration.enabled }) { profile in
                            Text(profile.configuration.name).tag(profile.id)
                        }
                    }
                    .onChange(of: draftProviderID) { _, provider in
                        let options = model.modelOptions.filter { model.providerID(for: $0.id) == provider }
                        if let option = options.first(where: \.isDefault) ?? options.first {
                            draftModelID = option.id
                            draftEffort = option.defaultComposerEffort
                            draftFastMode = false
                        }
                        modelSelectionError = nil
                    }

                    Divider()

                    HStack(alignment: .top, spacing: 18) {
                        selectionSection("模型") {
                            if draftProviderID == model.currentModelProviderID { selectionRow(
                                "默认",
                                subtitle: model.customModelProvider.enabled ? model.customModelProvider.name : "OpenAI · 本机 Codex",
                                selected: draftModelID == AppModel.recommendedModelSelectionID
                            ) {
                                draftModelID = AppModel.recommendedModelSelectionID
                                if let recommended = model.recommendedModel,
                                   !recommended.composerEfforts.contains(draftEffort ?? "") {
                                    draftEffort = recommended.defaultComposerEffort
                                }
                            } }
                            ForEach(model.modelOptions.filter { model.providerID(for: $0.id) == draftProviderID }) { option in
                                selectionRow(option.pickerName,
                                             subtitle: option.id.hasPrefix("provider:") ? option.model : nil,
                                             selected: draftModelID == option.id) {
                                    if draftModelID != option.id {
                                        draftEffort = option.defaultComposerEffort
                                    }
                                    draftModelID = option.id
                                    if option.fastServiceTierID == nil { draftFastMode = false }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)

                        Divider()

                        selectionSection("推理强度") {
                            if let draftModel, !draftModel.composerEfforts.isEmpty {
                                ForEach(draftModel.composerEfforts, id: \.self) { effort in
                                    selectionRow(effortDisplayName(effort), selected: draftEffort == effort) {
                                        draftEffort = effort
                                    }
                                }
                            } else {
                                Text("当前模型无需设置")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 8)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    Divider()

                    selectionSection("响应速度") {
                        HStack(spacing: 12) {
                            selectionRow("标准", selected: !draftFastMode) {
                                draftFastMode = false
                            }
                            selectionRow(
                                draftModel?.fastServiceTierID == nil ? "加速（当前模型不支持）" : "加速",
                                selected: draftFastMode
                            ) {
                                if draftModel?.fastServiceTierID != nil { draftFastMode = true }
                            }
                            .disabled(draftModel?.fastServiceTierID == nil)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .frame(maxHeight: .infinity)

            Divider()
            HStack {
                Text(modelSelectionError ?? (model.canApplyModelSelection(draftModelID)
                    ? "全局选择：影响所有对话的后续请求；跨厂商需等待任务结束"
                    : "请等待运行中及排队任务结束后再切换厂商"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("确定", action: applyModelSelection)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftModelID == nil || !model.canApplyModelSelection(draftModelID))
            }
            .padding(12)
            .fixedSize(horizontal: false, vertical: true)
        }
        // Keep the model, reasoning, and speed controls visible; scroll when
        // a larger catalog or a small display needs additional room.
        .frame(width: 560, height: 540)
        .task { await model.refreshModelCatalog() }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.quaternary))
        .shadow(color: .black.opacity(0.3), radius: 18, y: 7)
    }

    private func selectionSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func selectionRow(
        _ title: String,
        subtitle: String? = nil,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func beginModelSelection() {
        if showingModelPicker { return }
        draftModelID = model.selectedModelID
        draftProviderID = model.currentModelProviderID
        modelSelectionError = nil
        draftEffort = model.selectedEffort
        draftFastMode = model.isFastModeEnabled && model.supportsFastMode
        showingModelPicker = true
    }

    private func applyModelSelection() {
        guard let draftModelID else { return }
        Task {
            do {
                try await model.applyConversationModel(draftModelID, effort: draftEffort)
                model.setFastModeEnabled(draftFastMode && model.supportsFastMode)
                showingModelPicker = false
            } catch { modelSelectionError = error.localizedDescription }
        }
    }

    private var modelAndEffortCompactLabel: String {
        let modelName = model.selectedModelDisplayName
        guard let effort = model.selectedEffort else {
            return modelName
        }
        return "\(modelName) · \(effortCompactName(effort))"
    }

    private var modelAndEffortAccessibilityLabel: String {
        let modelName = model.selectedModelDisplayName
        guard let effort = model.selectedEffort else {
            return "\(modelName)，\(model.selectedSpeedLabel)速度"
        }
        return "\(modelName)，\(effortDisplayName(effort))，\(model.selectedSpeedLabel)速度"
    }

    private func effortDisplayName(_ effort: String) -> String {
        ReasoningEffortLabel.name(effort)
    }

    private func effortCompactName(_ effort: String) -> String {
        ReasoningEffortLabel.name(effort)
    }
}

private struct WaitingMessageQueueRow: View {
    @EnvironmentObject private var model: AppModel
    @State private var isHovered = false
    @State private var isDropTarget = false
    let item: AppModel.WaitingMessage
    let position: Int

    private var displayedError: String? {
        guard let error = item.error else { return nil }
        let protectionReasons: [CreditUsageProtection.Reason] = [
            .balanceDecreased, .includedQuotaExhausted, .usageUnavailable
        ]
        return protectionReasons.contains { $0.message == error } ? nil : error
    }

    var body: some View {
        HStack(spacing: 10) {
            dragHandle
            editButton
            actionButtons
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: WaitingQueueLayout.rowHeight, alignment: .leading)
        .background(
            isDropTarget ? Color.blue.opacity(0.20) : (isHovered ? Color.blue.opacity(0.11) : Color.primary.opacity(0.055)),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(isDropTarget ? Color.blue : (isHovered ? Color.blue.opacity(0.55) : Color.primary.opacity(0.08)), lineWidth: isDropTarget ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.14), value: isHovered)
        .animation(.easeOut(duration: 0.14), value: isDropTarget)
        .onHover { isHovered = $0 }
        .dropDestination(for: String.self) { values, location in
            guard let rawID = values.first, let sourceID = UUID(uuidString: rawID) else { return false }
            return model.moveWaitingMessage(
                sourceID,
                relativeTo: item.id,
                placeAfter: location.y > WaitingQueueLayout.rowHeight / 2
            )
        } isTargeted: { isDropTarget = $0 }
        .disabled(model.deliveringWaitingMessages.contains(item.id))
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.caption.weight(.semibold))
            .foregroundStyle(isHovered ? Color.blue : Color.secondary)
            .frame(width: 26, height: 34)
            .background(Color.primary.opacity(isHovered ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
            .draggable(item.id.uuidString) {
                Label("第 \(position) 位", systemImage: "line.3.horizontal")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            }
            .help("按住拖动，调整这条消息的发送顺序")
            .accessibilityLabel("拖动调整第 \(position) 位消息的顺序")
    }

    private var editButton: some View {
        Button {
            model.beginEditingWaitingMessage(item.id)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Text("\(position)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Color.blue, in: Circle())
                    .accessibilityLabel("排队第 \(position) 位")

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.text.isEmpty ? "附件消息" : item.text)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 8) {
                        Text("第 \(position) 位")
                            .fontWeight(.semibold)
                            .foregroundStyle(.blue)
                        Label("点击编辑", systemImage: "pencil")
                        if !item.attachments.isEmpty {
                            Label("\(item.attachments.count) 个附件", systemImage: "paperclip")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    if let error = displayedError {
                        Text(error)
                            .foregroundStyle(.orange)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("点击编辑待发送内容，保留附件和排队位置")
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            if model.isSelectedThreadProcessing {
                Button {
                    Task { await model.deliverWaitingMessage(item.id, steer: true) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.turn.up.right")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 18, height: 18)
                            .background(Color.white.opacity(0.16), in: Circle())
                        Text("立即引导")
                    }
                }
                .buttonStyle(WaitingMessagePrimaryActionButtonStyle())
                .help("将这条消息补充给正在执行的任务，沿用当前任务的模型。")
            } else if displayedError != nil {
                Button {
                    Task { await model.deliverWaitingMessage(item.id, steer: false) }
                } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button {
                model.removeWaitingMessage(item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("从等待队列移除")
        }
        .fixedSize()
    }
}

private struct WaitingMessagePrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.leading, 7)
            .padding(.trailing, 11)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue, Color.blue.opacity(0.78)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            }
            .shadow(
                color: Color.blue.opacity(configuration.isPressed ? 0.12 : (isHovered ? 0.34 : 0.24)),
                radius: configuration.isPressed ? 2 : (isHovered ? 6 : 4),
                y: configuration.isPressed ? 1 : 2
            )
            .scaleEffect(configuration.isPressed ? 0.97 : (isHovered ? 1.01 : 1))
            .brightness(configuration.isPressed ? -0.05 : (isHovered ? 0.04 : 0))
            .opacity(isEnabled ? 1 : 0.48)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.14), value: isHovered)
    }
}

private struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let pasteImages: () -> Bool
    let submit: () -> Void
    var focusRequest: UUID? = nil
    var suggestion: String? = nil
    var acceptSuggestion: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = ComposerNSTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textContainerInset = NSSize(width: 5, height: 7)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.pasteImages = pasteImages
        textView.submit = submit
        textView.suggestion = suggestion
        textView.acceptSuggestion = acceptSuggestion
        textView.toolTip = suggestion.map { "\($0)\n按 Tab 采纳，可编辑后发送" }
        scrollView.documentView = textView
        textView.requestFocus(focusRequest)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        context.coordinator.parent = self
        textView.pasteImages = pasteImages
        textView.submit = submit
        textView.suggestion = suggestion
        textView.acceptSuggestion = acceptSuggestion
        textView.toolTip = suggestion.map { "\($0)\n按 Tab 采纳，可编辑后发送" }
        textView.requestFocus(focusRequest)
        textView.synchronizeBoundText(text)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextEditor

        init(parent: ComposerTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
        }
    }
}

final class ComposerNSTextView: NSTextView {
    var pasteImages: (() -> Bool)?
    var submit: (() -> Void)?
    var suggestion: String? { didSet { if suggestion != oldValue { needsDisplay = true } } }
    var acceptSuggestion: (() -> Void)?
    private var pendingFocusRequest: UUID?
    private var appliedFocusRequest: UUID?

    var showsSuggestion: Bool { string.isEmpty && !hasMarkedText() && suggestion != nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let placeholder = NSAttributedString(string: suggestion ?? "和 Codex 一起工作", attributes: [
            .font: font ?? NSFont.preferredFont(forTextStyle: .body),
            .foregroundColor: NSColor.placeholderTextColor,
            .paragraphStyle: paragraph
        ])
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = textContainerOrigin
        placeholder.draw(with: NSRect(x: origin.x + padding, y: origin.y,
                                     width: max(0, bounds.width - origin.x * 2 - padding * 2),
                                     height: min(34, max(0, bounds.height - origin.y - 16))),
                         options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    @discardableResult
    func acceptVisibleSuggestion() -> Bool {
        guard showsSuggestion, let suggestion, let acceptSuggestion else { return false }
        acceptSuggestion()
        // Apply immediately in the native editor, including its undo stack and
        // caret, before SwiftUI synchronizes the accepted draft back to us.
        insertText(suggestion, replacementRange: NSRange(location: 0, length: 0))
        setSelectedRange(NSRange(location: string.utf16.count, length: 0))
        return true
    }

    func requestFocus(_ request: UUID?) {
        pendingFocusRequest = request
        scheduleRequestedFocus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleRequestedFocus()
    }

    private func scheduleRequestedFocus() {
        guard let request = pendingFocusRequest, request != appliedFocusRequest, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingFocusRequest == request,
                  self.appliedFocusRequest != request, let window = self.window else { return }
            if window.makeFirstResponder(self) { self.appliedFocusRequest = request }
        }
    }

    /// Streaming progress can redraw the SwiftUI wrapper while the input method
    /// owns an uncommitted marked range. Never replace its text or selection.
    func synchronizeBoundText(_ text: String) {
        guard !hasMarkedText(), string != text else { return }
        let selection = selectedRange()
        let location = min(selection.location, text.utf16.count)
        let length = min(selection.length, text.utf16.count - location)
        string = text
        setSelectedRange(NSRange(location: location, length: length))
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Handle Tab before AppKit uses it for keyboard focus navigation.
        if window?.firstResponder === self, event.keyCode == 48,
           event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty,
           acceptVisibleSuggestion() { return true }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command,
           event.charactersIgnoringModifiers?.lowercased() == "v",
           pasteImages?() == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
        if pasteImages?() == true { return }
        super.paste(sender)
    }

    override func insertTab(_ sender: Any?) {
        if acceptVisibleSuggestion() { return }
        super.insertTab(sender)
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if event.keyCode == 48, modifiers.isEmpty, acceptVisibleSuggestion() { return }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && !event.modifierFlags.contains(.shift) && !hasMarkedText() {
            submit?()
            return
        }
        super.keyDown(with: event)
    }
}

private struct AttachmentPreview: View {
    let attachment: ComposerAttachment
    let remove: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                openURL(attachment.url)
            } label: {
                Group {
                    if attachment.isImage, let image = NSImage(contentsOf: attachment.url) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        VStack(spacing: 5) {
                            Image(systemName: "doc.fill").font(.title2)
                            Text(attachment.url.lastPathComponent)
                                .font(.caption2)
                                .lineLimit(2)
                        }
                        .padding(7)
                    }
                }
                .frame(width: 72, height: 72)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
            }
            .buttonStyle(.plain)
            .help("在 CloudCodex 中预览 \(attachment.url.lastPathComponent)")

            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.caption.bold())
                    .foregroundStyle(.primary)
                    .frame(width: 22, height: 22)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .offset(x: 6, y: -6)
            .help("移除附件")
        }
        .padding(.top, 6)
        .padding(.trailing, 6)
    }
}
