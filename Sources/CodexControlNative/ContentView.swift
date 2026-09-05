import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    private let categoryDragPrefix = "cloudcodex-category://"

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            folderSidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } content: {
            threadList
                .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 430)
        } detail: {
            conversation
        }
        .toolbar { toolbar }
        .sheet(isPresented: $model.showingCategoryManager) { categoryManagerSheet }
        .sheet(isPresented: $model.showingRemoteControl) { RemoteControlSheet() }
        .alert("操作未完成", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    private var folderSidebar: some View {
        List(selection: Binding(
            get: { model.selectedFolder ?? "__all__" },
            set: { selection in
                guard let selection else { return }
                let previous = model.selectedFolder
                DispatchQueue.main.async {
                    guard model.selectedFolder == previous else { return }
                    model.selectFolder(selection == "__all__" ? nil : selection)
                }
            }
        )) {
            Section {
                Label("最近会话", systemImage: "tray.full")
                    .padding(.vertical, 6)
                    .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 10))
                    .tag("__all__")
            } header: {
                HStack {
                    Text("工作区")
                    Spacer()
                    Button {
                        model.showingCategoryManager = true
                    } label: {
                        Image(systemName: "folder.badge.gearshape")
                    }
                    .buttonStyle(.plain)
                    .help("管理分类")
                }
                .padding(.trailing, 12)
                .padding(.bottom, 4)
            }

            sidebarSectionSpacer

            ForEach(model.workspaceCategories) { category in
                workspaceCategorySection(category)
                sidebarSectionSpacer
            }

            Section {
                if model.uncategorizedFolders.isEmpty {
                    categoryDropPlaceholder("拖动工作区到这里", categoryID: nil)
                } else {
                    ForEach(model.uncategorizedFolders) { folder in
                        workspaceRow(folder)
                    }
                }
            } header: {
                categoryDropHeader("未分类", systemImage: "tray", categoryID: nil)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.connectionText.hasPrefix("已连接") ? .green : .orange)
                    .frame(width: 7, height: 7)
                Text(model.connectionText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
            .background(.bar)
        }
    }

    private var sidebarSectionSpacer: some View {
        Color.clear
            .frame(height: 8)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .accessibilityHidden(true)
    }

    private func workspaceCategorySection(_ category: WorkspaceCategory) -> some View {
        Section {
            let folders = model.folders(inCategory: category.id)
            if folders.isEmpty {
                categoryDropPlaceholder("拖动工作区到这里", categoryID: category.id)
            } else {
                ForEach(folders) { folder in
                    workspaceRow(folder)
                }
            }
        } header: {
            categoryDropHeader(category.name, systemImage: "folder.fill", categoryID: category.id)
                .contextMenu {
                    Button("重命名") {
                        model.showingCategoryManager = true
                        model.beginRenamingCategory(category)
                    }
                    Button("删除分类", role: .destructive) {
                        model.deleteCategory(category.id)
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
        .padding(.vertical, 6)
        .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
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
    private func categoryDropHeader(_ title: String, systemImage: String, categoryID: String?) -> some View {
        let header = Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 7)
            .padding(.bottom, 5)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { paths, location in
                handleCategoryDrop(paths, targetCategoryID: categoryID, location: location)
            }
            .help("可将工作区拖到此分类")

        if let categoryID {
            header.draggable(categoryDragPrefix + categoryID) {
                Label(title, systemImage: "folder.fill")
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        } else {
            header
        }
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

    private var threadList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.selectedFolder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "最近会话")
                    .font(.headline)
                Spacer()
                Button(action: model.prepareNewThread) {
                    Image(systemName: "square.and.pencil")
                }
                .help("新建会话")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            List(selection: Binding(
                get: { model.selectedThreadID },
                set: { selection in
                    // List sends transient nil during row replacement/filtering.
                    // It is not an explicit request to close the conversation.
                    guard let selection else { return }
                    let previous = model.selectedThreadID
                    DispatchQueue.main.async {
                        guard model.selectedThreadID == previous else { return }
                        model.selectThread(selection)
                    }
                }
            )) {
                ForEach(model.visibleThreads) { thread in
                    ThreadRow(thread: thread)
                        .tag(Optional(thread.id))
                }
            }
            .searchable(text: $model.searchText, prompt: "搜索会话")
            .overlay {
                if model.isLoading && model.selectedThreadID == nil {
                    ProgressView("加载最近会话…")
                } else if model.visibleThreads.isEmpty {
                    ContentUnavailableView(
                        "暂无会话",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text("在这个文件夹中新建一个 Codex 会话")
                    )
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.hasMoreThreads {
                    Text("为保持流畅，仅显示最近 60 个会话")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(.bar)
                }
            }
        }
    }

    @ViewBuilder
    private var conversation: some View {
        if model.showingNewThread {
            NewThreadWorkspace()
        } else if let thread = model.selectedThread {
            VStack(spacing: 0) {
                ConversationHeader(thread: thread)
                Divider()
                MessageList(
                    messages: model.messages,
                    isLoading: model.isLoading,
                    isThinking: model.isSelectedThreadProcessing
                )
                    .id(thread.id)
                Divider()
                Composer(mode: .conversation)
            }
        } else {
            ContentUnavailableView {
                Label("选择一个会话", systemImage: "message")
            } description: {
                Text("从左侧工作区中选择现有会话，或新建一个会话。")
            } actions: {
                Button("新建会话", action: model.prepareNewThread)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
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
        }
    }

}

private struct RemoteControlSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

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
                    Text("通过 AI 小程序向这台 Mac 发送任务")
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

                    HStack(spacing: 10) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 9, height: 9)
                            .shadow(color: statusColor.opacity(0.65), radius: model.remoteControlEnabled ? 5 : 0)
                        Text(model.remoteControlStatus)
                            .font(.subheadline)
                        Spacer()
                    }

                    if model.remoteControlEnabled && !model.remoteControlPaired {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("在 AI 小程序中输入配对码")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if model.remotePairingCode.isEmpty {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                HStack {
                                    Text(model.remotePairingCode)
                                        .font(.system(size: 34, weight: .bold, design: .monospaced))
                                        .tracking(5)
                                        .textSelection(.enabled)
                                    Spacer()
                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(model.remotePairingCode, forType: .string)
                                    } label: {
                                        Label("复制", systemImage: "doc.on.doc")
                                    }
                                }
                            }
                            HStack {
                                Text("配对码 10 分钟内有效")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Spacer()
                                Button("生成新配对码") { model.resetRemotePairingCode() }
                                    .buttonStyle(.link)
                            }
                        }
                        .padding(18)
                        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.blue.opacity(0.22)))
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

                    Label("CloudCodex 主动通过 HTTPS 领取任务，不会在 Mac 上开放公网监听端口。设备密钥存放在系统钥匙串，服务端只保存不可逆摘要。", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
        }
        .frame(width: 520, height: 510)
    }

    private var statusColor: Color {
        if !model.remoteControlEnabled { return .secondary }
        if model.remoteControlPaired { return .green }
        return .orange
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

private struct ThreadRow: View {
    let thread: CodexThread

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                ThreadStatusLight(isRunning: thread.status == "active")
                Text(thread.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(relativeTimeLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if !thread.visiblePreview.isEmpty {
                Text(thread.visiblePreview.replacingOccurrences(of: "\n", with: " "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            HStack(spacing: 5) {
                Image(systemName: "folder")
                Text(thread.folderName)
                if let model = thread.model {
                    Text("·")
                    Text(model)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
    }

    /// `Text(date, style: .relative)` installs an independent timeline for
    /// every row. With 60 visible summaries those timelines repeatedly wake
    /// and relayout the whole list, so render a snapshot instead. The regular
    /// status refresh and manual refresh keep this label sufficiently current.
    private var relativeTimeLabel: String {
        let elapsed = max(0, Int(Date().timeIntervalSince(thread.updatedAt)))
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
                Text(thread.displayName).font(.headline).lineLimit(1)
                Text(thread.cwd)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let model = thread.model {
                Text(TurnModelMetadata(model: model, reasoningEffort: thread.reasoningEffort).displayLabel ?? model)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

private struct MessageList: View {
    let messages: [ChatMessage]
    let isLoading: Bool
    let isThinking: Bool
    @State private var isAtLatest = true
    @State private var hasUnseenUpdates = false
    @State private var hasNewContentBelow = false
    @State private var visibleMessageLimit = 12
    @State private var viewportResetID = UUID()

    private let messageBatchSize = 12

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: 18) {
                    if messages.isEmpty && isLoading {
                        ProgressView("正在读取会话…").padding(.top, 80)
                    } else if messages.isEmpty {
                        ContentUnavailableView("开始对话", systemImage: "sparkles", description: Text("在下方输入任务并发送给 Codex。"))
                            .padding(.top, 80)
                    }

                    if hiddenMessageCount > 0 {
                        Button {
                            showEarlierMessages()
                        } label: {
                            Label(
                                "显示更早的 \(min(messageBatchSize, hiddenMessageCount)) 条消息",
                                systemImage: "clock.arrow.circlepath"
                            )
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                        }
                        .buttonStyle(.plain)
                        .background(.quaternary.opacity(0.65), in: Capsule())

                        Text("为保持流畅，已隐藏更早的 \(hiddenMessageCount) 条消息")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    ForEach(renderedMessages) { message in
                        MessageBubble(message: message)
                            .equatable()
                            .id(message.id)
                    }

                    if isThinking {
                        ThinkingIndicator()
                            .id("persistent-thinking-indicator")
                    }
                }
                .padding(22)
            }
            .defaultScrollAnchor(.bottom)
            .background(ScrollLatestObserver(isAtLatest: $isAtLatest))
            .id(viewportResetID)

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
        .onAppear {
            isAtLatest = true
            hasUnseenUpdates = false
            hasNewContentBelow = false
        }
        .onChange(of: messages.last?.id) { _, _ in
            handleNewMessage()
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

    private var renderedMessages: ArraySlice<ChatMessage> {
        messages.suffix(visibleMessageLimit)
    }

    private var hiddenMessageCount: Int {
        max(0, messages.count - visibleMessageLimit)
    }

    private func handleNewMessage() {
        guard let last = messages.last else { return }
        if last.role == .user {
            jumpToBottom()
        } else {
            markNewContent()
        }
    }

    private func markNewContent() {
        guard !messages.isEmpty else { return }
        hasUnseenUpdates = true
        hasNewContentBelow = !isAtLatest
    }

    private func jumpToBottom() {
        // Recreate the bounded 12-message viewport with a declarative bottom
        // anchor. This is an instant jump and deliberately avoids ScrollView
        // position bindings / proxy scrolling, both of which can create a
        // persistent SwiftUI focus-layout feedback loop on very long content.
        isAtLatest = true
        hasUnseenUpdates = false
        viewportResetID = UUID()
        hasNewContentBelow = false
    }

    private func showEarlierMessages() {
        visibleMessageLimit = min(messages.count, visibleMessageLimit + messageBatchSize)
    }

    private var streamingScrollToken: String {
        guard let last = messages.last else { return "empty" }
        return "\(messages.count):\(last.id):\(last.text.count):\(last.isStreaming)"
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
        view.onLatestChanged = { latest in
            if isAtLatest != latest {
                isAtLatest = latest
            }
        }
        view.connectWhenReady()
    }
}

private final class ScrollLatestProbeView: NSView {
    var onLatestChanged: ((Bool) -> Void)?

    private weak var observedScrollView: NSScrollView?
    private var observationTokens: [NSObjectProtocol] = []
    private var lastReportedValue: Bool?

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        connectWhenReady()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        connectWhenReady()
    }

    func connectWhenReady() {
        DispatchQueue.main.async { [weak self] in
            self?.connectToEnclosingScrollView()
        }
    }

    func disconnect() {
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
            reportCurrentPosition()
            return
        }

        disconnect()
        observedScrollView = scrollView

        let center = NotificationCenter.default
        scrollView.contentView.postsBoundsChangedNotifications = true
        observationTokens.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.reportCurrentPosition()
        })

        if let documentView = scrollView.documentView {
            documentView.postsFrameChangedNotifications = true
            observationTokens.append(center.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: documentView,
                queue: .main
            ) { [weak self] _ in
                self?.reportCurrentPosition()
            })
        }
        reportCurrentPosition()
    }

    private func reportCurrentPosition() {
        guard let scrollView = observedScrollView,
              let documentView = scrollView.documentView else { return }
        let visibleRect = scrollView.documentVisibleRect
        let documentBounds = documentView.bounds
        let threshold: CGFloat = 28
        let remaining = documentView.isFlipped
            ? documentBounds.maxY - visibleRect.maxY
            : visibleRect.minY - documentBounds.minY
        let latest = remaining <= threshold
        guard latest != lastReportedValue else { return }
        lastReportedValue = latest
        DispatchQueue.main.async { [weak self] in
            self?.onLatestChanged?(latest)
        }
    }
}

private struct MessageBubble: View, Equatable {
    let message: ChatMessage

    @ViewBuilder
    var body: some View {
        if message.id == "turn-progress" {
            ProcessingBubble(message: message)
        } else if message.role == .activity {
            ActivityBubble(message: message)
        } else {
            HStack(alignment: .top) {
                if message.role == .user { Spacer(minLength: 70) }
                if message.role == .assistant {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.blue)
                        .frame(width: 26, height: 26)
                        .background(.blue.opacity(0.1), in: Circle())
                }
                Group {
                    if message.role == .user {
                        VStack(alignment: .trailing, spacing: 8) {
                            UserMessageContent(message: message)
                            MessageMetadataFooter(message: message)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 9) {
                            if message.isStreaming {
                                StreamingMarkdownContent(text: message.text)
                            } else {
                                AssistantMessageContent(text: message.text)
                            }

                            MessageMetadataFooter(message: message)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .foregroundStyle(.primary)
                    .background(background, in: RoundedRectangle(cornerRadius: 13))
                    .frame(maxWidth: 720, alignment: .leading)
                if message.role != .user { Spacer(minLength: 30) }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var background: some ShapeStyle {
        if message.role == .user { return AnyShapeStyle(Color.accentColor.opacity(0.14)) }
        return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
    }

}

private struct MessageMetadataFooter: View {
    let message: ChatMessage

    var body: some View {
        if message.modelUsageLabel != nil || message.timestamp != nil {
            HStack(spacing: 9) {
                if let modelUsageLabel = message.modelUsageLabel {
                    Label(modelUsageLabel, systemImage: "cpu")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                        .accessibilityLabel("本轮使用模型 \(modelUsageLabel)")
                }
                if let timestamp = message.timestamp {
                    Label(MessageTimeFormatter.string(from: timestamp), systemImage: "clock")
                        .accessibilityLabel("消息时间 \(MessageTimeFormatter.accessibilityString(from: timestamp))")
                }
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
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

    var body: some View {
        if text.count > LongAssistantMessageView.pageSize {
            LongAssistantMessageView(text: text)
        } else {
            MarkdownMessageView(markdown: text)
        }
    }
}

/// Very long final replies can contain hundreds of Markdown blocks. Building
/// all of them at once causes a large one-off CPU and memory spike even though
/// only a small part is visible. Page the raw text so every page has a strict
/// layout ceiling while preserving access to the entire answer.
private struct LongAssistantMessageView: View {
    static let pageSize = 8_000

    let text: String
    @State private var page: Int

    init(text: String) {
        self.text = text
        let lastPage = max(0, (text.count - 1) / Self.pageSize)
        _page = State(initialValue: lastPage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pageText)
                .font(.body)
                .textSelection(.enabled)
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
        max(1, (text.count + Self.pageSize - 1) / Self.pageSize)
    }

    private var boundedPage: Int {
        min(max(0, page), totalPages - 1)
    }

    private var pageText: String {
        let characterCount = text.count
        let lowerOffset = min(characterCount, boundedPage * Self.pageSize)
        let upperOffset = min(characterCount, lowerOffset + Self.pageSize)
        let lower = text.index(text.startIndex, offsetBy: lowerOffset)
        let upper = text.index(text.startIndex, offsetBy: upperOffset)
        return String(text[lower..<upper])
    }
}

private struct UserMessageContent: View {
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                MarkdownMessageView(markdown: message.text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MessageAttachmentCard: View {
    let attachment: ChatMessageAttachment

    var body: some View {
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
        .help(attachment.path.isEmpty ? attachment.name : "打开 \(attachment.name)")
    }

    private func openAttachment() {
        guard !attachment.path.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: attachment.path))
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

private struct ActivityBubble: View {
    let message: ChatMessage
    @State private var isExpanded: Bool

    init(message: ChatMessage) {
        self.message = message
        _isExpanded = State(initialValue: message.isStreaming)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if !message.text.isEmpty {
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
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(message.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 9)
                    }
                }
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: message.activityKind?.iconName ?? "gearshape.2")
                    .foregroundStyle(iconColor)
                    .frame(width: 20)
                Text(message.activityTitle ?? "Codex 处理过程")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if message.isStreaming {
                    ProgressView().controlSize(.small)
                }
                if let status = message.activityStatus {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
        .onChange(of: message.isStreaming) { _, streaming in
            isExpanded = streaming
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

private struct Composer: View {
    @EnvironmentObject private var model: AppModel
    let mode: ComposerMode

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

                if !currentAttachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(currentAttachments) { attachment in
                                AttachmentPreview(attachment: attachment) {
                                    removeAttachment(attachment.id)
                                }
                            }
                        }
                    }
                    .frame(height: 82)
                }

                ComposerTextEditor(
                    text: composerText,
                    pasteImages: pasteImages,
                    submit: submit
                )
                    .frame(
                        minHeight: mode == .newThread ? 110 : 54,
                        maxHeight: mode == .newThread ? 200 : 120
                    )

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

                    if mode == .conversation, model.isExternalThreadProcessing {
                        Label("Codex 中处理中", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

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

                    Button {
                        submitOrCancel()
                    } label: {
                        Group {
                            if mode == .newThread, model.isCreatingThread {
                                ProgressView().controlSize(.small)
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
    }

    private var composerText: Binding<String> {
        Binding(
            get: { mode == .newThread ? model.newThreadPrompt : model.composerText },
            set: { value in
                if mode == .newThread {
                    model.newThreadPrompt = value
                } else {
                    model.composerText = value
                }
            }
        )
    }

    private var currentAttachments: [ComposerAttachment] {
        mode == .newThread ? model.newThreadAttachments : model.attachments
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
        if mode == .newThread {
            model.removeNewThreadAttachment(id)
        } else {
            model.removeAttachment(id)
        }
    }

    private func pasteImages() -> Bool {
        mode == .newThread ? model.pasteNewThreadImages() : model.pasteImages()
    }

    private func toggleDictation() {
        if mode == .newThread {
            model.toggleNewThreadDictation()
        } else {
            model.toggleDictation()
        }
    }

    private func submit() {
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
        if mode == .conversation, model.isSending {
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
        Menu {
            Section("模型") {
                ForEach(model.modelOptions) { option in
                    Button {
                        model.selectModel(option.id)
                    } label: {
                        HStack {
                            Text(option.displayName)
                            if model.selectedModelID == option.id { Image(systemName: "checkmark") }
                        }
                    }
                }
            }

            if !model.availableEfforts.isEmpty {
                Section("推理强度") {
                    ForEach(model.availableEfforts, id: \.self) { effort in
                        Button {
                            model.selectedEffort = effort
                        } label: {
                            HStack {
                                Text(effortDisplayName(effort))
                                if model.selectedEffort == effort { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }

            Section("响应速度") {
                Button {
                    model.setFastModeEnabled(false)
                } label: {
                    HStack {
                        Text("标准")
                        if !model.isFastModeEnabled || !model.supportsFastMode {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Button {
                    model.setFastModeEnabled(true)
                } label: {
                    HStack {
                        Text(model.supportsFastMode ? "加速" : "加速（当前模型不支持）")
                        if model.isFastModeEnabled && model.supportsFastMode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .disabled(!model.supportsFastMode)
            }
        } label: {
            Text(modelAndEffortCompactLabel)
                .font(.callout)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(modelAndEffortAccessibilityLabel)
        .help("选择模型、推理强度和响应速度")
    }

    private var modelAndEffortCompactLabel: String {
        let modelName = model.selectedModel?.compactName ?? "选择模型"
        guard let effort = model.selectedEffort else {
            return "\(modelName) · \(model.selectedSpeedLabel)"
        }
        return "\(modelName) · \(effortCompactName(effort)) · \(model.selectedSpeedLabel)"
    }

    private var modelAndEffortAccessibilityLabel: String {
        let modelName = model.selectedModel?.compactName ?? "选择模型"
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

private struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let pasteImages: () -> Bool
    let submit: () -> Void

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
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        context.coordinator.parent = self
        textView.pasteImages = pasteImages
        textView.submit = submit
        guard textView.string != text else { return }
        let selectionLocation = min(textView.selectedRange().location, text.utf16.count)
        textView.string = text
        textView.setSelectedRange(NSRange(location: selectionLocation, length: 0))
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
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

    override func keyDown(with event: NSEvent) {
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

    var body: some View {
        ZStack(alignment: .topTrailing) {
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
