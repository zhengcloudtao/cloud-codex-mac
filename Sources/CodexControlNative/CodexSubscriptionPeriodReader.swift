import Foundation
import CryptoKit
import Security
import LocalAuthentication

/// Reads only the subscription-period claim from the local Codex OAuth token.
/// The token and the rest of the auth payload never leave this process.
struct CodexSubscriptionPeriodReader {
    private static let openAIAuthClaim = "https://api.openai.com/auth"
    private static let subscriptionClaim = "chatgpt_subscription_active_until"

    let environment: [String: String]
    let homeDirectory: URL
    let loadData: (URL) -> Data?
    let usesKeychain: Bool
    let loadKeychain: (URL) -> Data?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        loadData: @escaping (URL) -> Data? = { try? Data(contentsOf: $0) },
        usesKeychain: Bool = false,
        loadKeychain: @escaping (URL) -> Data? = Self.keychainData
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.loadData = loadData
        self.usesKeychain = usesKeychain
        self.loadKeychain = loadKeychain
    }

    func read() -> Date? {
        if usesKeychain {
            // Managed accounts explicitly use keyring storage. Never fall back to
            // another account or an obsolete auth.json when keyring data is absent.
            guard let path = authPaths().first,
                  let data = loadKeychain(path.deletingLastPathComponent()) else { return nil }
            return Self.subscriptionPeriodEnd(authData: data)
        }
        for path in authPaths() {
            guard let data = loadData(path), let date = Self.subscriptionPeriodEnd(authData: data) else {
                continue
            }
            return date
        }
        return nil
    }

    func authPaths() -> [URL] {
        if let configuredHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredHome.isEmpty {
            return [URL(fileURLWithPath: configuredHome).appendingPathComponent("auth.json")]
        }
        return [
            homeDirectory.appendingPathComponent(".config/codex/auth.json"),
            homeDirectory.appendingPathComponent(".codex/auth.json")
        ]
    }

    static func keychainData(home: URL) -> Data? {
        let canonical = home.resolvingSymlinksInPath().path
        let hash = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: "Codex Auth",
            kSecAttrAccount: "cli|\(hash.prefix(16))", kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne, kSecUseAuthenticationContext: context
        ]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess else { return nil }
        return value as? Data
    }

    static func subscriptionPeriodEnd(authData: Data) -> Date? {
        guard let json = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any]
        else {
            return nil
        }
        for key in ["access_token", "id_token"] {
            guard let token = tokens[key] as? String,
                  let payload = jwtPayload(token),
                  let claims = payload[openAIAuthClaim] as? [String: Any],
                  let value = claims[subscriptionClaim]
            else {
                continue
            }
            if let text = value as? String, let date = parseISO8601(text) {
                return date
            }
            if let epoch = value as? NSNumber {
                return Date(timeIntervalSince1970: epoch.doubleValue)
            }
        }
        return nil
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while !payload.count.isMultiple(of: 4) {
            payload.append("=")
        }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }

    private static func parseISO8601(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) {
            return date
        }
        return ISO8601DateFormatter().date(from: text)
    }
}
