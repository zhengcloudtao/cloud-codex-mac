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
        .sheet(isPresented: $model.showingNewThread) { newThreadSheet }
        .sheet(isPresented: $model.showingCategoryManager) { categoryManagerSheet }
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
            set: { model.selectFolder($0 == "__all__" ? nil : $0) }
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
                set: model.selectThread
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
        if let thread = model.selectedThread {
            VStack(spacing: 0) {
                ConversationHeader(thread: thread)
                Divider()
                MessageList(messages: model.messages, isLoading: model.isLoading)
                Divider()
                Composer()
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
        }
    }

    private var newThreadSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("新建 Codex 会话")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 7) {
                Text("工作文件夹").font(.headline)
                HStack {
                    TextField("选择一个文件夹", text: $model.newThreadFolder)
                        .textFieldStyle(.roundedBorder)
                    Button("选择…", action: model.chooseNewThreadFolder)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("第一条消息（可选）").font(.headline)
                TextEditor(text: $model.newThreadPrompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    .frame(height: 130)
            }

            HStack {
                Text("会话将使用你当前的 Codex 登录和默认模型设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { model.showingNewThread = false }
                    .keyboardShortcut(.cancelAction)
                Button("创建") { Task { await model.createThread() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.newThreadFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isLoading)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}

private struct ThreadRow: View {
    let thread: CodexThread

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Circle()
                    .fill(thread.status == "active" ? .green : .secondary.opacity(0.35))
                    .frame(width: 7, height: 7)
                Text(thread.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(thread.updatedAt, style: .relative)
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
                Text([model, thread.reasoningEffort].compactMap { $0 }.joined(separator: " · "))
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

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 18) {
                    if messages.isEmpty && isLoading {
                        ProgressView("正在读取会话…").padding(.top, 80)
                    } else if messages.isEmpty {
                        ContentUnavailableView("开始对话", systemImage: "sparkles", description: Text("在下方输入任务并发送给 Codex。"))
                            .padding(.top, 80)
                    }
                    ForEach(messages) { message in
                        MessageBubble(message: message).id(message.id)
                    }
                }
                .padding(22)
            }
            .onChange(of: messages.last?.id) { _, _ in
                if let lastID = messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(lastID, anchor: .bottom) }
                }
            }
            .onChange(of: streamingScrollToken) { _, _ in
                if let lastID = messages.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(lastID, anchor: .bottom) }
                }
            }
        }
    }

    private var streamingScrollToken: String {
        guard let last = messages.last else { return "empty" }
        return "\(messages.count):\(last.id):\(last.text.count):\(last.isStreaming)"
    }
}

private struct MessageBubble: View {
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
                        UserMessageContent(message: message)
                    } else {
                        MarkdownMessageView(markdown: message.text)
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
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    if message.isStreaming {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: completionIcon)
                            .foregroundStyle(completionColor)
                    }

                    Text(durationLabel(at: context.date))
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
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(message.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 9)
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
            if streaming { isExpanded = true }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

private struct Composer: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if let notice = model.threadOwnershipNotice {
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

                if !model.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(model.attachments) { attachment in
                                AttachmentPreview(attachment: attachment) {
                                    model.removeAttachment(attachment.id)
                                }
                            }
                        }
                    }
                    .frame(height: 82)
                }

                TextEditor(text: $model.composerText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 5)
                    .frame(minHeight: 54, maxHeight: 120)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        if model.canSend { Task { await model.sendMessage() } }
                        return .handled
                    }

                HStack(spacing: 12) {
                    Button(action: model.chooseAttachments) {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .help("添加图片或文件")

                    permissionMenu

                    if model.isExternalThreadProcessing {
                        Label("Codex 中处理中", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 18)

                    modelMenu

                    Button(action: model.toggleDictation) {
                        Image(systemName: model.isRecording ? "waveform.circle.fill" : "mic")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(model.isRecording ? .red : .primary)
                            .symbolEffect(.pulse, isActive: model.isRecording)
                    }
                    .buttonStyle(.plain)
                    .help(model.isRecording ? "停止语音输入" : "语音输入")

                    Button {
                        Task {
                            if model.isSending { await model.cancelTurn() }
                            else { await model.sendMessage() }
                        }
                    } label: {
                        Group {
                            if model.isExternalThreadProcessing {
                                ProgressView().controlSize(.small)
                            } else if model.isSending && model.activeTurnID == nil {
                                ProgressView().controlSize(.small)
                            } else if model.isSending {
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
                    .disabled(!model.canSend && !model.isSending)
                    .help(
                        model.isExternalThreadProcessing
                            ? "此任务正在 Codex 主应用中处理"
                            : (model.isSending ? "停止当前任务" : "发送（Return）")
                    )
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
        } label: {
            Text(modelAndEffortCompactLabel)
                .font(.callout)
                .lineLimit(1)
                .layoutPriority(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(modelAndEffortAccessibilityLabel)
        .help("选择模型和推理强度")
    }

    private var modelAndEffortCompactLabel: String {
        let modelName = model.selectedModel?.compactName ?? "选择模型"
        guard let effort = model.selectedEffort else { return modelName }
        return "\(modelName) · \(effortCompactName(effort))"
    }

    private var modelAndEffortAccessibilityLabel: String {
        let modelName = model.selectedModel?.compactName ?? "选择模型"
        guard let effort = model.selectedEffort else { return modelName }
        return "\(modelName)，\(effortDisplayName(effort))"
    }

    private func effortDisplayName(_ effort: String) -> String {
        switch effort {
        case "low": return "低"
        case "medium": return "中"
        case "high": return "高"
        case "xhigh": return "超高"
        case "max": return "最大"
        case "ultra": return "极致（自动委派）"
        default: return effort
        }
    }

    private func effortCompactName(_ effort: String) -> String {
        switch effort {
        case "low": return "低"
        case "medium": return "中"
        case "high": return "高"
        case "xhigh": return "超高"
        case "max": return "最大"
        case "ultra": return "极致"
        default: return effort
        }
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
