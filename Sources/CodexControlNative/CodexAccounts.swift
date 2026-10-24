import AppKit
import Foundation

struct CodexAccountIdentity: Codable, Equatable {
    let email: String
    let plan: String
    var planDisplayName: String { CodexPlanName.displayName(plan) }

    static func parse(_ response: [String: Any]) throws -> Self {
        guard let account = response["account"] as? [String: Any],
              account["type"] as? String == "chatgpt" else {
            throw ModelProviderError.message("此目录尚未登录 ChatGPT 账号，请先完成登录。")
        }
        return .init(email: account["email"] as? String ?? "ChatGPT 账号（未提供邮箱）", plan: account["planType"] as? String ?? "未提供")
    }
}

struct CodexSavedAccount: Identifiable, Codable, Equatable {
    static let localID = "local"
    let id: String
    var identity: CodexAccountIdentity?
    var shared: Bool?
    var isShared: Bool { shared == true }
    var isLocal: Bool { id == Self.localID }
    var title: String { identity?.email ?? (isLocal ? "本机默认账号" : "待登录账号") }
}

/// Only labels and UUIDs go into preferences. Codex stores each managed home's
/// credentials in the macOS Keychain. The existing local home is never migrated.
@MainActor
final class CodexAccountStore: ObservableObject {
    static let defaultsKey = "CloudCodex.accounts.v1"
    struct Library: Codable {
        var accounts: [CodexSavedAccount] = [.init(id: CodexSavedAccount.localID)]
        var activeID = CodexSavedAccount.localID
    }
    @Published private(set) var library: Library
    @Published private(set) var overviews: [String: AccountOverview] = [:]
    @Published private(set) var issues: [String: String] = [:]
    @Published private(set) var busyID: String?
    @Published private(set) var loginURL: URL?
    @Published private(set) var status: String?
    private let defaults: UserDefaults
    let root: URL
    private let makeClient: (URL?, Bool) -> AppServerClient
    private let openURL: (URL) -> Bool
    var configureSharedClient: ((AppServerClient, String) -> Void)?
    var removeSharedBinding: ((String) -> Void)?
    private var worker: AppServerClient?
    private var loginID: String?
    private var generation = 0
    private var timeoutTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, root: URL? = nil,
         makeClient: ((URL?, Bool) -> AppServerClient)? = nil,
         openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.defaults = defaults
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CloudCodex/Accounts", isDirectory: true)
        self.makeClient = makeClient ?? { AppServerClient(codexHomeOverride: $0, usesManagedAccount: $1) }
        self.openURL = openURL
        var saved = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(Library.self, from: $0) } ?? Library()
        var seen: Set<String> = []
        saved.accounts = saved.accounts.filter {
            ($0.isLocal || UUID(uuidString: $0.id) != nil) && seen.insert($0.id).inserted
        }
        if !saved.accounts.contains(where: \.isLocal) { saved.accounts.insert(.init(id: CodexSavedAccount.localID), at: 0) }
        if !saved.accounts.contains(where: { $0.id == saved.activeID }) { saved.activeID = CodexSavedAccount.localID }
        library = saved
    }

    var active: CodexSavedAccount { library.accounts.first { $0.id == library.activeID }! }
    func home(for account: CodexSavedAccount) -> URL? {
        account.isLocal ? nil : root.appendingPathComponent(account.id, isDirectory: true)
    }
    func prepareHome(for account: CodexSavedAccount) throws {
        guard let home = home(for: account) else { return }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
    }
    private func save() { defaults.set(try? JSONEncoder().encode(library), forKey: Self.defaultsKey) }
    func lockForSwitch(_ id: String) { busyID = id }
    func unlockAfterSwitch() { busyID = nil }
    func activate(_ id: String) {
        guard library.accounts.contains(where: { $0.id == id }) else { return }
        library.activeID = id
        save()
    }
    func update(_ id: String, identity: CodexAccountIdentity) {
        guard let index = library.accounts.firstIndex(where: { $0.id == id }) else { return }
        library.accounts[index].identity = identity
        issues[id] = nil
        save()
    }
    func setOverview(_ overview: AccountOverview, for id: String) { overviews[id] = overview }

    func addSharedAccount(id: String, access: SharedAccountAccess) throws {
        guard UUID(uuidString: id) != nil, !library.accounts.contains(where: { $0.id == id }) else { throw AccountShareCrypto.failure }
        let account = CodexSavedAccount(id: id, identity: .init(email: access.email, plan: access.chatgptPlanType), shared: true)
        try prepareHome(for: account)
        library.accounts.append(account); save()
    }

    func addAccount() async {
        guard busyID == nil else { return }
        let account = CodexSavedAccount(id: UUID().uuidString)
        library.accounts.append(account)
        save()
        await login(account)
    }

    func login(_ account: CodexSavedAccount) async {
        // Reauthorizing an active home could replace the running inference identity.
        guard busyID == nil, !account.isLocal, !account.isShared, account.id != library.activeID else { return }
        generation += 1
        let ticket = generation
        busyID = account.id
        issues[account.id] = nil
        status = "正在准备官方登录…"
        let client = makeClient(home(for: account), true)
        worker = client
        client.onDisconnect = { [weak self] _ in
            guard let self, self.generation == ticket else { return }
            self.issues[account.id] = "登录服务已断开，请重新发起登录。"
            self.finishWorker()
        }
        client.onEvent = { [weak self, weak client] method, params in
            guard method == "account/login/completed", let self, let client,
                  self.generation == ticket else { return }
            // A completion may arrive before the start RPC's response. This
            // dedicated process owns exactly one login attempt.
            let succeeded = params["success"] as? Bool == true
            Task { await self.finishLogin(account, client: client, ticket: ticket, succeeded: succeeded) }
        }
        do {
            try prepareHome(for: account)
            try await client.start()
            guard generation == ticket else { return }
            let login = try await client.beginAccountLogin()
            guard generation == ticket else { return }
            loginID = login.id
            loginURL = login.url
            status = openURL(login.url) ? "请在浏览器中完成登录，完成后会自动保存。" : "未能打开浏览器，请点击“打开登录页面”。"
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(600)) } catch { return }
                guard let self, self.generation == ticket else { return }
                await self.cancelLogin()
                self.issues[account.id] = "登录等待已超时，请重试。"
            }
        } catch {
            guard generation == ticket else { return }
            issues[account.id] = "无法发起登录，请确认本机 Codex 支持账号登录且钥匙串可用。"
            finishWorker()
        }
    }

    private func finishLogin(_ account: CodexSavedAccount, client: AppServerClient, ticket: Int, succeeded: Bool) async {
        guard generation == ticket else { return }
        guard succeeded else {
            issues[account.id] = "登录未完成，请重新授权。"
            finishWorker()
            return
        }
        do {
            let identity = try await client.readAccountIdentity()
            guard generation == ticket else { return }
            if let original = account.identity, original.email != identity.email {
                try await client.logoutAccount()
                guard generation == ticket else { return }
                issues[account.id] = "登录的账号与此卡片不一致，已退出。请使用原账号重新授权，或添加新账号。"
                finishWorker()
                return
            }
            update(account.id, identity: identity)
            let overview = try? await client.readAccountOverview()
            guard generation == ticket else { return }
            overviews[account.id] = overview
            status = "账号已保存，点击“切换”即可使用。"
        } catch {
            guard generation == ticket else { return }
            issues[account.id] = "登录结果未能确认，请刷新账号或重新授权。"
        }
        finishWorker()
    }

    func reopenLogin() { if let loginURL { _ = openURL(loginURL) } }
    func cancelLogin() async {
        guard let worker else { return }
        generation += 1
        if let loginID { await worker.cancelAccountLogin(loginID) }
        finishWorker()
        status = "已取消登录。"
    }
    private func finishWorker() {
        generation += 1
        timeoutTask?.cancel(); timeoutTask = nil
        worker?.onEvent = nil
        worker?.shutdown(); worker = nil
        busyID = nil; loginID = nil; loginURL = nil
    }

    func refresh(_ account: CodexSavedAccount) async {
        guard busyID == nil else { return }
        busyID = account.id
        let ticket = generation
        let client = makeClient(home(for: account), !account.isLocal)
        if account.isShared { configureSharedClient?(client, account.id) }
        worker = client
        defer { if generation == ticket { finishWorker() } }
        do {
            try prepareHome(for: account)
            try await client.start()
            let identity = try await client.readAccountIdentity()
            guard generation == ticket else { return }
            update(account.id, identity: identity)
            let overview = try await client.readAccountOverview()
            guard generation == ticket else { return }
            overviews[account.id] = overview
        } catch {
            guard generation == ticket else { return }
            issues[account.id] = "读取失败：登录可能已失效，或网络暂时不可用。"
            // Keep the last snapshot with its original timestamp, never fabricate a new quota.
        }
    }

    func remove(_ account: CodexSavedAccount) async {
        guard busyID == nil, !account.isLocal, account.id != library.activeID else { return }
        if account.isShared {
            removeSharedBinding?(account.id)
            library.accounts.removeAll { $0.id == account.id }; overviews[account.id] = nil; issues[account.id] = nil; save()
            status = "已断开共享账号；本地会话文件保留。"
            return
        }
        busyID = account.id
        let client = makeClient(home(for: account), true)
        defer { client.shutdown(); busyID = nil }
        do {
            try await client.start()
            try await client.logoutAccount()
            library.accounts.removeAll { $0.id == account.id }
            overviews[account.id] = nil; issues[account.id] = nil
            save()
            status = "账号已退出并移除；本地会话文件保留。"
        } catch { issues[account.id] = "退出登录失败，账号已保留，请重试。" }
    }
}
