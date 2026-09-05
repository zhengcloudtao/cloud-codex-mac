import Foundation
import Security

enum RemoteCredentialError: LocalizedError, Equatable {
    case authorizationRequired
    case cancelled
    case invalidCredential
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .authorizationRequired: return "需要授权读取钥匙串；自动连接已暂停。"
        case .cancelled: return "已取消钥匙串授权；不会自动重试。"
        case .invalidCredential: return "设备凭据无法读取，已保留原有钥匙串记录。"
        case .keychain: return "钥匙串暂时不可用；自动连接已暂停。"
        }
    }
}

protocol RemoteCredentialKeychain: Sendable {
    func interactionAllowed() -> (OSStatus, Bool)
    func setInteractionAllowed(_ allowed: Bool) -> OSStatus
    func read() -> (OSStatus, Data?)
    func add(_ data: Data) -> OSStatus
}

private struct SystemRemoteCredentialKeychain: RemoteCredentialKeychain {
    private var identity: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.cloudslow.CloudCodex",
         kSecAttrAccount as String: "remote-control-device-secret-v1"]
    }

    // These legacy APIs are necessary for the existing file-based login
    // keychain: kSecUseAuthenticationUIFail alone does not suppress its UI.
    // Never force interaction on or alter an item's access control list.
    func interactionAllowed() -> (OSStatus, Bool) {
        var allowed: DarwinBoolean = false
        let status = SecKeychainGetUserInteractionAllowed(&allowed)
        return (status, allowed.boolValue)
    }

    func setInteractionAllowed(_ allowed: Bool) -> OSStatus {
        SecKeychainSetUserInteractionAllowed(allowed)
    }

    func read() -> (OSStatus, Data?) {
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return (status, item as? Data)
    }

    func add(_ data: Data) -> OSStatus {
        var query = identity
        query[kSecValueData as String] = data
        // An existing record must never be deleted or overwritten, including
        // when authorization is denied or another process wins a create race.
        return SecItemAdd(query as CFDictionary, nil)
    }
}

/// All credential operations share one worker queue. The legacy interaction
/// flag is process-wide, so its save/restore scope must not overlap or suspend.
final class RemoteCredentialStore: @unchecked Sendable {
    static let shared = RemoteCredentialStore()
    private static let queue = DispatchQueue(label: "CloudCodex.remote-credentials", qos: .userInitiated)
    private let keychain: any RemoteCredentialKeychain
    private let generate: @Sendable () throws -> Data

    init(
        keychain: any RemoteCredentialKeychain = SystemRemoteCredentialKeychain(),
        generate: @escaping @Sendable () throws -> Data = { try RemoteCredentialStore.generateSecret() }
    ) {
        self.keychain = keychain
        self.generate = generate
    }

    func load(allowInteraction: Bool) async throws -> String {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                continuation.resume(with: Result { try self.loadOnWorker(allowInteraction: allowInteraction) })
            }
        }
    }

    private func loadOnWorker(allowInteraction: Bool) throws -> String {
        if allowInteraction { return try readOrCreate(allowCreation: true) }
        let (readStatus, previouslyAllowed) = keychain.interactionAllowed()
        guard readStatus == errSecSuccess else { throw RemoteCredentialError.keychain(readStatus) }
        let status = keychain.setInteractionAllowed(false)
        guard status == errSecSuccess else { throw RemoteCredentialError.keychain(status) }
        let result = Result { try readOrCreate(allowCreation: false) }
        let restoreStatus = keychain.setInteractionAllowed(previouslyAllowed)
        guard restoreStatus == errSecSuccess else { throw RemoteCredentialError.keychain(restoreStatus) }
        return try result.get()
    }

    private func readOrCreate(allowCreation: Bool) throws -> String {
        let (status, data) = keychain.read()
        if status == errSecSuccess { return try decode(data) }
        guard status == errSecItemNotFound else { throw error(for: status) }
        guard allowCreation else { throw RemoteCredentialError.authorizationRequired }
        let generated = try generate()
        let secret = try decode(generated)
        let addStatus = keychain.add(generated)
        if addStatus == errSecDuplicateItem {
            // Keep the winning record, never rotate an already-paired secret.
            let (retryStatus, retryData) = keychain.read()
            guard retryStatus == errSecSuccess else { throw error(for: retryStatus) }
            return try decode(retryData)
        }
        guard addStatus == errSecSuccess else { throw error(for: addStatus) }
        return secret
    }

    private func decode(_ data: Data?) throws -> String {
        guard let data, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw RemoteCredentialError.invalidCredential
        }
        return value
    }

    private func error(for status: OSStatus) -> RemoteCredentialError {
        switch status {
        case errSecUserCanceled: return .cancelled
        case errSecInteractionNotAllowed, errSecAuthFailed: return .authorizationRequired
        default: return .keychain(status)
        }
    }

    static func generateSecret() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RemoteControlError.missingCredential
        }
        return Data(Data(bytes).base64EncodedString().utf8)
    }
}
