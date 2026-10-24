import Foundation
import CryptoKit
import Security
import LocalAuthentication

struct SharedAccountAccess: Codable {
    let accessToken: String
    let chatgptAccountId: String
    let chatgptPlanType: String
    let email: String
    let expiresAt: Double
}
struct AccountShareSnapshot: Codable { let id: String; let version: Int64; let ciphertext: String }
struct AccountShareRemoteState: Decodable {
    let id: String
    let version: Int64
    let refreshRequested: Bool
    let paired: Bool
    let receiverName: String
}
struct AccountSharePublication: Codable, Identifiable {
    let id: String
    let accountID: String
    let serverAddress: String
    var version: Int64
    var lastDigest: String
    var boundAccountID: String
}

enum AccountShareCrypto {
    static func randomProof() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncoded
    }
    static func seal(_ access: SharedAccountAccess, id: String, version: Int64, key: Data) throws -> String {
        let aad = Data("cloudcodex-account-share-v1|\(id)|\(version)".utf8)
        return try AES.GCM.seal(JSONEncoder().encode(access), using: SymmetricKey(data: key), authenticating: aad)
            .combined!.base64EncodedString()
    }
    static func open(_ snapshot: AccountShareSnapshot, key: Data) throws -> SharedAccountAccess {
        guard key.count == 32, let data = Data(base64Encoded: snapshot.ciphertext) else { throw failure }
        let aad = Data("cloudcodex-account-share-v1|\(snapshot.id)|\(snapshot.version)".utf8)
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: key), authenticating: aad)
        return try JSONDecoder().decode(SharedAccountAccess.self, from: plain)
    }
    static var failure: Error { ModelProviderError.message("账号同步失败，请检查配对或在来源设备 重新登录。") }
}
extension Data {
    fileprivate var base64URLEncoded: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

// Secret material never goes into UserDefaults, share metadata, logs or relay plaintext.
enum AccountShareKeychain {
    static func key(_ id: String) throws -> Data {
        var value: CFTypeRef?
        let context = LAContext(); context.interactionNotAllowed = true
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: "CloudCodex.AccountSharing.v1",
            kSecAttrAccount: id, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context] as CFDictionary, &value)
        guard status == errSecSuccess, let data = value as? Data, data.count == 32 else { throw AccountShareCrypto.failure }
        return data
    }
    static func save(_ key: Data, id: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "CloudCodex.AccountSharing.v1", kSecAttrAccount: id]
        let status = SecItemAdd(query.merging([kSecValueData: key, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { _, b in b } as CFDictionary, nil)
        guard status == errSecSuccess else { throw AccountShareCrypto.failure }
    }
    static func delete(_ id: String) { SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: "CloudCodex.AccountSharing.v1", kSecAttrAccount: id] as CFDictionary) }

    // Match Codex's direct keyring namespace, scoped to the canonical CODEX_HOME.
    // This deliberately returns only a short-lived access token, never a refresh token.
    static func access(home: URL, identity: CodexAccountIdentity, allowInteraction: Bool) throws -> SharedAccountAccess {
        let canonical = home.resolvingSymlinksInPath().path
        let hash = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        var value: CFTypeRef?
        var query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "Codex Auth", kSecAttrAccount: "cli|\(hash.prefix(16))",
                                    kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        if !allowInteraction { let context = LAContext(); context.interactionNotAllowed = true; query[kSecUseAuthenticationContext] = context }
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        let data: Data
        if status == errSecSuccess, let stored = value as? Data { data = stored }
        else if status == errSecItemNotFound {
            data = try Data(contentsOf: home.appendingPathComponent("auth.json"))
        } else { throw AccountShareCrypto.failure }
        return try parseAccess(data, identity: identity)
    }
    static func parseAccess(_ data: Data, identity: CodexAccountIdentity) throws -> SharedAccountAccess {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any], let token = tokens["access_token"] as? String,
              let account = tokens["account_id"] as? String, !account.isEmpty else { throw AccountShareCrypto.failure }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { throw AccountShareCrypto.failure }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let decoded = Data(base64Encoded: payload), let claims = try JSONSerialization.jsonObject(with: decoded) as? [String: Any],
              let expiry = claims["exp"] as? Double,
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              auth["chatgpt_account_id"] as? String == account else { throw AccountShareCrypto.failure }
        return SharedAccountAccess(accessToken: token, chatgptAccountId: account, chatgptPlanType: identity.plan, email: identity.email, expiresAt: expiry)
    }
}

@MainActor
final class AccountDeviceSharing: ObservableObject {
    @Published private(set) var publications: [AccountSharePublication] = []
    @Published private(set) var receivers: [String: String] = [:]
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published var generatedCode: String?
    private let defaults: UserDefaults
    private let metadataKey = "CloudCodex.accountShares.v1"
    private var monitor: Task<Void, Never>?
    var loadAccess: ((String, Bool, Bool) async throws -> SharedAccountAccess)?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: metadataKey), let saved = try? JSONDecoder().decode([AccountSharePublication].self, from: data) { publications = saved }
    }
    func start() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                await self?.synchronize()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
    private func save() { defaults.set(try? JSONEncoder().encode(publications), forKey: metadataKey) }
    private func api(_ address: String? = nil, interaction: Bool = false) async throws -> RemoteControlAPI {
        var config = RemoteServerConfiguration.load(defaults)
        if let address { config = .init(mode: .custom, customAddress: address) }
        return try await RemoteControlAPI.connect(allowInteraction: interaction, configuration: config, defaults: defaults)
    }
    func create(accountID: String) async {
        guard !busy, let loadAccess else { return }
        busy = true; defer { busy = false }
        generatedCode = nil
        do {
            let access = try await loadAccess(accountID, true, false)
            guard access.expiresAt > Date().timeIntervalSince1970 + 60 else { throw AccountShareCrypto.failure }
            let id = UUID().uuidString.lowercased(), code = AccountShareCrypto.randomProof()
            let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            let server = try RemoteServerConfiguration.load(defaults).validatedURL().absoluteString
            let api = try await api(interaction: true)
            _ = try await api.register()
            let cipher = try AccountShareCrypto.seal(access, id: id, version: 1, key: key)
            try AccountShareKeychain.save(key, id: id)
            // Persist metadata first so a lost create response cannot orphan an unrevokable grant.
            publications.append(.init(id: id, accountID: accountID, serverAddress: server, version: 1, lastDigest: "", boundAccountID: access.chatgptAccountId))
            save()
            try await api.createAccountShare(id: id, accountRef: SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined(), code: code, ciphertext: cipher)
            generatedCode = "CCS1.\(id).\(code).\(key.base64URLEncoded)"
            message = "分享码 10 分钟内有效，仅用于配对一台自己的电脑。请在目标设备配置相同后端；来源设备 需保持运行以更新凭据。"
            start()
        } catch { message = "无法生成分享码。请确认后端已升级、账号已登录且钥匙串允许访问。" }
    }
    func revoke(_ item: AccountSharePublication) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let api = try await api(item.serverAddress, interaction: true)
            let states = try await api.listAccountShares()
            if states.contains(where: { $0.id == item.id }) { try await api.revokeAccountShare(item.id) }
            publications.removeAll { $0.id == item.id }; receivers[item.id] = nil
            AccountShareKeychain.delete(item.id); generatedCode = nil; save()
            message = "已停止此设备的后续同步；已发出的访问凭据会在过期后失效。"
        } catch { message = "撤销未成功，保留原记录，请联网后重试。" }
    }
    func synchronize() async {
        guard !busy, !publications.isEmpty, let loadAccess else { return }
        busy = true; defer { busy = false }
        var remoteStates: [String: [AccountShareRemoteState]] = [:]
        var failedServers: Set<String> = []
        for item in publications {
            do {
                if failedServers.contains(item.serverAddress) { continue }
                let api = try await api(item.serverAddress)
                if remoteStates[item.serverAddress] == nil {
                    do { remoteStates[item.serverAddress] = try await api.listAccountShares() }
                    catch { failedServers.insert(item.serverAddress); throw error }
                }
                let states = remoteStates[item.serverAddress] ?? []
                guard let state = states.first(where: { $0.id == item.id }) else { continue }
                receivers[item.id] = state.paired ? state.receiverName : "等待配对"
                let access = try await loadAccess(item.accountID, false, state.refreshRequested)
                // A re-login must never silently share a different account/workspace.
                guard access.chatgptAccountId == item.boundAccountID, access.expiresAt > Date().timeIntervalSince1970 + 60 else { throw AccountShareCrypto.failure }
                let digest = SHA256.hash(data: Data(access.accessToken.utf8)).map { String(format: "%02x", $0) }.joined()
                guard digest != item.lastDigest || state.refreshRequested else { continue }
                let next = state.version + 1
                let key = try AccountShareKeychain.key(item.id)
                let ciphertext = try AccountShareCrypto.seal(access, id: item.id, version: next, key: key)
                try await api.publishAccountShare(item.id, version: next, ciphertext: ciphertext)
                if let index = publications.firstIndex(where: { $0.id == item.id }) {
                    publications[index].version = next; publications[index].lastDigest = digest; save()
                }
            } catch { message = "部分设备同步暂不可用。来源账号可能需要重新登录，恢复后自动重试。" }
        }
    }
}
