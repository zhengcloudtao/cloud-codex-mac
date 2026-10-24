import SwiftUI

struct CodexAccountsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: CodexAccountStore
    @State private var showReceive = false
    @State private var removing: CodexSavedAccount?
    @State private var pendingSwitchID: String?
    @State private var switchRequestTask: Task<Void, Never>?
    @State private var switchWaitError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("账号管理", systemImage: "person.crop.circle.badge.checkmark").font(.title2.bold())
                Spacer()
                Button("通过分享码添加") { showReceive = true }
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
                    AccountSharingStatusView(sharing: model.accountDeviceSharing, accounts: store.library.accounts)
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
        .sheet(isPresented: $showReceive) { AccountShareReceiveSheet().environmentObject(model) }
        .onDisappear { switchRequestTask?.cancel(); model.accountDeviceSharing.generatedCode = nil }
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
                    Text(account.isShared ? "来自其他设备的共享账号" : (account.isLocal ? "本机默认账号" : "独立账号"))
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
                    if !account.isShared { Button(account.identity == nil ? "登录" : "重新登录") { Task { await store.login(account) } }.disabled(busy) }
                    Button("移除", role: .destructive) { removing = account }.disabled(busy)
                }
                if current && !account.isLocal && !account.isShared {
                    Text("重新授权前，请先切换到本机默认账号。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !account.isShared {
                    Button("共享到我的设备") { Task { await model.accountDeviceSharing.create(accountID: account.id) } }
                        .disabled(busy || account.identity == nil || model.accountDeviceSharing.busy)
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

private struct AccountSharingStatusView: View {
    @ObservedObject var sharing: AccountDeviceSharing
    let accounts: [CodexSavedAccount]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let message = sharing.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let code = sharing.generatedCode {
                HStack {
                    Text(code).font(.caption.monospaced()).lineLimit(2).textSelection(.enabled)
                    Button("复制分享码") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(code, forType: .string) }
                    Button("隐藏") { sharing.generatedCode = nil }
                }
            }
            ForEach(sharing.publications) { item in
                HStack {
                    Text((accounts.first { $0.id == item.accountID }?.title ?? "来源账号") + " · " + (sharing.receivers[item.id] ?? "等待同步")).font(.caption)
                    Spacer()
                    Button("停止共享") { Task { await sharing.revoke(item) } }.disabled(sharing.busy)
                }
            }
        }
    }
}

private struct AccountShareReceiveSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var busy = false
    @State private var status = "在来源 Mac 或 Windows 的账号管理中生成分享码。两台电脑需使用同一个 HTTPS 后端。"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("通过分享码添加账号").font(.title2.bold()); Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
            SecureField("粘贴完整分享码；留空可重试上次配对", text: $code)
            Text(status).font(.callout).foregroundStyle(.secondary)
            HStack {
                Button(busy ? "正在配对…" : "连接 / 重试") {
                    busy = true
                    Task {
                        defer { busy = false }
                        do { try await model.connectSharedAccount(code: code); code = ""; status = "账号已添加，请返回账号管理点击切换。来源电脑需保持运行以更新凭据。" }
                        catch { status = "连接未完成：请检查分享码、相同后端及来源设备。可留空重试；更换分享码前请先清除待配对记录。" }
                    }
                }.disabled(busy)
                Button("清除待配对记录") { model.accountShareReceiver.discardPending(preserving: Set(model.accounts.library.accounts.map(\.id))); code = ""; status = "已清除待配对记录，可输入新的分享码。" }.disabled(busy)
            }
            Text("共享账号只接收短期访问凭据，不覆盖本机登录；无法再次转分享。来源电脑离线时暂时无法续期。").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 540)
    }
}
