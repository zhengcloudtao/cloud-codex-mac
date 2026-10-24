import SwiftUI

struct CodexAccountsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CodexAccountStore
    @State private var removing: CodexSavedAccount?
    @State private var pendingSwitchID: String?
    @State private var switchRequestTask: Task<Void, Never>?
    @State private var switchWaitError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("账号管理", systemImage: "person.crop.circle.badge.checkmark").font(.title2.bold())
                Spacer()
                Button("添加账号", systemImage: "plus") { Task { await store.addAccount() } }
                    .disabled(store.busyID != nil || model.isSwitchingModelProvider || pendingSwitchID != nil)
                Button("完成") { dismiss() }
                    .disabled(store.busyID != nil || model.isSwitchingModelProvider)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .help("关闭账号管理")
                .accessibilityLabel("关闭账号管理")
            }
            Text("所有账号共用会话和历史记录，登录状态独立保存。切换后保留当前会话和草稿，可用新账号继续任务。")
                .font(.callout).foregroundStyle(.secondary)
            if model.customModelProvider.enabled {
                Text("当前模型使用 \(model.customModelProvider.name)。切换 ChatGPT 账号后，如需使用套餐额度，请在模型设置中选择 OpenAI。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            // Background polling must not insert/remove banners or move account cards.
            // Explain a blocked switch only after the user requests one.
            if pendingSwitchID == nil, let error = switchWaitError ?? model.accountSwitchError {
                Text(error).foregroundStyle(.orange).font(.callout)
            }
            if let status = store.status { Text(status).font(.callout).foregroundStyle(.secondary) }
            if store.loginURL != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("等待浏览器授权…")
                    Spacer()
                    Button("打开登录页面") { store.reopenLogin() }
                    Button("取消登录") { Task { await store.cancelLogin() } }
                }
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.library.accounts) { account in card(account) }
                }
            }
            Text("新增账号的登录凭据由 Codex 保存在 macOS 钥匙串。首次访问可能需要系统授权。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 700, height: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .interactiveDismissDisabled(store.busyID != nil || model.isSwitchingModelProvider)
        // Opening this sheet only displays the existing account snapshot.
        // Refresh explicitly from a card so opening it never locks switching.
        .onDisappear { switchRequestTask?.cancel() }
        .alert("移除账号？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { account in
            Button("取消", role: .cancel) { removing = nil }
            Button("退出并移除", role: .destructive) {
                removing = nil
                Task { await store.remove(account) }
            }
        } message: { _ in
            Text("将退出此账号并从列表移除。本地会话文件会保留；其他账号不受影响。")
        }
    }

    private func requestSwitch(to id: String) {
        guard pendingSwitchID == nil else { return }
        pendingSwitchID = id
        switchWaitError = nil
        switchRequestTask = Task { @MainActor in
            defer { pendingSwitchID = nil; switchRequestTask = nil }
            let deadline = ContinuousClock.now + .seconds(15)
            while model.isWaitingForRemoteAccountSwitch {
                guard ContinuousClock.now < deadline else {
                    switchWaitError = "远程同步尚未结束，请稍后重试。"
                    return
                }
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            await model.switchAccount(to: id)
        }
    }

    private func card(_ account: CodexSavedAccount) -> some View {
        let current = account.id == store.library.activeID
        let busy = store.busyID != nil || model.isSwitchingModelProvider || pendingSwitchID != nil
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: account.isLocal ? "desktopcomputer" : "person.crop.circle")
                    .font(.title2).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.title).font(.headline).textSelection(.enabled)
                    Text(account.isLocal ? "本机默认账号" : "独立账号")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let plan = account.identity?.planDisplayName { Text(plan).font(.caption.bold()) }
                if current { Text("当前").font(.caption.bold()).foregroundStyle(.green) }
                if store.busyID == account.id { ProgressView().controlSize(.small) }
            }
            if let overview = store.overviews[account.id] {
                HStack(spacing: 20) {
                    if let remaining = overview.compactRemaining(minutes: 300) { Text("5小时剩余 \(remaining)") }
                    if let remaining = overview.compactRemaining(minutes: 10_080) { Text("每周剩余 \(remaining)") }
                }
                .font(.callout).monospacedDigit()
                Text("更新于 \(Date(timeIntervalSince1970: overview.usage.capturedAt).formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let issue = store.issues[account.id] { Text(issue).font(.callout).foregroundStyle(.orange) }
            HStack {
                Button("刷新") { Task { await store.refresh(account) } }.disabled(busy)
                if !account.isLocal && !current {
                    Button(account.identity == nil ? "登录" : "重新登录") { Task { await store.login(account) } }.disabled(busy)
                    Button("移除", role: .destructive) { removing = account }.disabled(busy)
                }
                if current && !account.isLocal {
                    Text("重新授权前，请先切换到本机默认账号。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !current {
                    Button {
                        requestSwitch(to: account.id)
                    } label: {
                        Text(pendingSwitchID == account.id
                             ? (model.isSwitchingModelProvider ? "正在切换…" : "等待同步…") : "切换")
                            .frame(width: 88)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || (!account.isLocal && account.identity == nil))
                }
            }
        }
        .padding(16)
        .background(current ? Color.accentColor.opacity(0.06) : Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(current ? Color.accentColor : Color.secondary.opacity(0.2)))
    }
}
