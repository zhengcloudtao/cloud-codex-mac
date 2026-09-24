import Foundation

/// Reads display-only profile claims from the local Codex OAuth token.
/// Raw tokens and unrelated claims never leave this process.
struct CodexProfileReader {
    struct Profile: Equatable {
        let id: String?
        let name: String?
        let email: String?
        let username: String?
        let avatarURL: URL?

        init(
            id: String? = nil,
            name: String?,
            email: String?,
            username: String?,
            avatarURL: URL?
        ) {
            self.id = id
            self.name = name
            self.email = email
            self.username = username
            self.avatarURL = avatarURL
        }

        func mergingFallback(_ fallback: Profile?) -> Profile {
            Profile(
                id: id ?? fallback?.id,
                name: name ?? fallback?.name,
                email: email ?? fallback?.email,
                username: username ?? fallback?.username,
                avatarURL: avatarURL ?? fallback?.avatarURL
            )
        }
    }

    private static let profileClaim = "https://api.openai.com/profile"
    let environment: [String: String]
    let homeDirectory: URL
    let loadData: (URL) -> Data?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        loadData: @escaping (URL) -> Data? = { try? Data(contentsOf: $0) }
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.loadData = loadData
    }

    func read() -> Profile? {
        for path in authPaths() {
            guard let data = loadData(path), let profile = Self.profile(authData: data) else { continue }
            return profile
        }
        return nil
    }

    func accessToken() -> String? {
        for path in authPaths() {
            guard let data = loadData(path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = json["tokens"] as? [String: Any],
                  let token = tokens["access_token"] as? String else { continue }
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private func authPaths() -> [URL] {
        if let configuredHome = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configuredHome.isEmpty {
            return [URL(fileURLWithPath: configuredHome).appendingPathComponent("auth.json")]
        }
        return [
            homeDirectory.appendingPathComponent(".config/codex/auth.json"),
            homeDirectory.appendingPathComponent(".codex/auth.json")
        ]
    }

    static func profile(authData: Data) -> Profile? {
        guard let json = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any] else { return nil }
        let payloads = ["access_token", "id_token"].compactMap { key -> [String: Any]? in
            guard let token = tokens[key] as? String else { return nil }
            return jwtPayload(token)
        }
        guard !payloads.isEmpty else { return nil }

        let nestedProfiles = payloads.compactMap { $0[profileClaim] as? [String: Any] }
        func firstString(_ keys: [String]) -> String? {
            for values in nestedProfiles + payloads {
                for key in keys {
                    if let value = values[key] as? String,
                       !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return value.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
            return nil
        }

        let email = firstString(["email"])
        let username = firstString(["preferred_username", "username"])
            ?? email?.split(separator: "@").first.map(String.init)
        let avatarURL = firstString(["picture", "avatar_url", "avatarUrl"]).flatMap { raw -> URL? in
            guard let url = URL(string: raw), url.scheme?.lowercased() == "https" else { return nil }
            return url
        }
        let result = Profile(
            id: firstString(["sub"]),
            name: firstString(["name"]),
            email: email,
            username: username,
            avatarURL: avatarURL
        )
        return result.name == nil && result.email == nil && result.avatarURL == nil ? nil : result
    }

    private static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while !payload.count.isMultiple(of: 4) { payload.append("=") }
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return json
    }
}
