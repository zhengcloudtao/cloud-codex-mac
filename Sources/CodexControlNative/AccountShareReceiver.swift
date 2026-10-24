import Foundation
import Security

struct AccountShareBinding: Codable {
    let id: String
    var code: String
    let key: String
    let receiverSecret: String
    let serverAddress: String
    var minimumVersion: Int64 = 1
    var boundAccountID: String?

    static func decodeProof(_ value: String) throws -> Data {
        let text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: text + String(repeating: "=", count: (4 - text.count % 4) % 4)), data.count == 32 else { throw AccountShareCrypto.failure }
        return data
    }
    static func parse(_ code: String, server: String) throws -> Self {
        let parts = code.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: ".")
        guard parts.count == 4, parts[0] == "CCS1", UUID(uuidString: parts[1]) != nil else { throw AccountShareCrypto.failure }
        _ = try decodeProof(parts[2]); _ = try decodeProof(parts[3]); _ = try serverURL(server)
        return .init(id: parts[1], code: parts[2], key: parts[3], receiverSecret: AccountShareCrypto.randomProof(), serverAddress: server)
    }
    static func serverURL(_ server: String) throws -> URL {
        guard let url = URL(string: server), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw AccountShareCrypto.failure }
        return url
    }
    func open(_ snapshot: AccountShareSnapshot, now: Double = Date().timeIntervalSince1970) throws -> SharedAccountAccess {
        guard snapshot.id == id, snapshot.version >= minimumVersion, snapshot.ciphertext.utf8.count <= 32768 else { throw AccountShareCrypto.failure }
        let access = try AccountShareCrypto.open(snapshot, key: Self.decodeProof(key))
        guard !access.accessToken.isEmpty, !access.chatgptAccountId.isEmpty, access.expiresAt > now + 30,
              access.expiresAt < now + 30 * 86400, boundAccountID == nil || boundAccountID == access.chatgptAccountId else { throw AccountShareCrypto.failure }
        return access
    }
}

enum AccountShareReceiverVault {
    static func read(_ id: String) throws -> Data {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([kSecClass: kSecClassGenericPassword, kSecAttrService: "CloudCodex.AccountReceiver.v1",
            kSecAttrAccount: id, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne] as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw AccountShareCrypto.failure }
        return data
    }
    static func save(_ data: Data, id: String) throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: "CloudCodex.AccountReceiver.v1", kSecAttrAccount: id]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging([kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { _, b in b } as CFDictionary, nil) == errSecSuccess else { throw AccountShareCrypto.failure }
        } else if status != errSecSuccess { throw AccountShareCrypto.failure }
    }
    static func delete(_ id: String) {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: "CloudCodex.AccountReceiver.v1", kSecAttrAccount: id] as CFDictionary)
    }
}

@MainActor
final class AccountShareReceiver {
    private let defaults: UserDefaults
    private let session: URLSession
    private let load: (String) throws -> Data
    private let save: (Data, String) throws -> Void
    private let delete: (String) -> Void
    private var busy: Set<String> = []
    private let pendingKey = "CloudCodex.accountShareReceiver.pending.v1"
    init(defaults: UserDefaults = .standard, session: URLSession? = nil,
         load: @escaping (String) throws -> Data = AccountShareReceiverVault.read,
         save: @escaping (Data, String) throws -> Void = { try AccountShareReceiverVault.save($0, id: $1) },
         delete: @escaping (String) -> Void = AccountShareReceiverVault.delete) {
        self.defaults = defaults; self.load = load; self.save = save; self.delete = delete
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 15; config.timeoutIntervalForResource = 20
        self.session = session ?? URLSession(configuration: config, delegate: AccountShareNoRedirect(), delegateQueue: nil)
    }
    private func binding(_ id: String) throws -> AccountShareBinding { try JSONDecoder().decode(AccountShareBinding.self, from: load(id)) }
    private func persist(_ value: AccountShareBinding, id: String) throws { try save(JSONEncoder().encode(value), id) }
    func pair(code: String, server: String) async throws -> (String, SharedAccountAccess) {
        let accountID: String
        if let pending = defaults.string(forKey: pendingKey) {
            let existing = try binding(pending)
            if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { accountID = pending }
            else {
                let next = try AccountShareBinding.parse(code, server: server)
                guard existing.id == next.id, existing.key == next.key, existing.serverAddress == next.serverAddress else { throw AccountShareCrypto.failure }
                accountID = pending
            }
        } else {
            accountID = UUID().uuidString
            try persist(AccountShareBinding.parse(code, server: server), id: accountID)
            defaults.set(accountID, forKey: pendingKey)
        }
        let access = try await access(accountID: accountID)
        return (accountID, access)
    }
    func finishPairing() { defaults.removeObject(forKey: pendingKey) }
    func discardPending(preserving accounts: Set<String> = []) {
        if let id = defaults.string(forKey: pendingKey), !accounts.contains(id) { delete(id) }
        finishPairing()
    }
    func remove(_ id: String) { delete(id) }
    private func request(_ value: AccountShareBinding, suffix: String = "", method: String = "GET", body: [String: String]? = nil) async throws -> Data {
        let base = try AccountShareBinding.serverURL(value.serverAddress)
        guard let url = URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/cloud-codex/account-shares/\(value.id)" + suffix) else { throw AccountShareCrypto.failure }
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue(value.receiverSecret, forHTTPHeaderField: "X-CloudCodex-Share-Token")
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.expectedContentLength <= 40000 else { throw AccountShareCrypto.failure }
        var data = Data()
        for try await byte in bytes { guard data.count < 40000 else { throw AccountShareCrypto.failure }; data.append(byte) }
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any], envelope["status"] as? Int == 0 else { throw AccountShareCrypto.failure }
        return data
    }
    func access(accountID: String, refresh: Bool = false) async throws -> SharedAccountAccess {
        let deadline = ContinuousClock.now + .seconds(30)
        while busy.contains(accountID) {
            guard ContinuousClock.now < deadline else { throw AccountShareCrypto.failure }
            try await Task.sleep(for: .milliseconds(100))
        }
        busy.insert(accountID)
        defer { busy.remove(accountID) }
        var value = try binding(accountID)
        if refresh { _ = try await request(value, suffix: "/refresh", method: "POST") }
        for attempt in 0..<(refresh ? 8 : 1) {
            if refresh { try await Task.sleep(for: .seconds(2)) }
            let claim = !value.code.isEmpty
            let data = try await request(value, suffix: claim ? "/claim" : "", method: claim ? "POST" : "GET",
                body: claim ? ["code": value.code, "name": String((Host.current().localizedName ?? "Mac").prefix(80))] : nil)
            struct Envelope: Decodable { let data: AccountShareSnapshot }
            let snapshot = try JSONDecoder().decode(Envelope.self, from: data).data
            if refresh && snapshot.version <= value.minimumVersion { if attempt < 7 { continue }; throw AccountShareCrypto.failure }
            let access = try value.open(snapshot)
            value.code = ""; value.minimumVersion = snapshot.version; value.boundAccountID = access.chatgptAccountId
            try persist(value, id: accountID)
            return access
        }
        throw AccountShareCrypto.failure
    }
}
private final class AccountShareNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
