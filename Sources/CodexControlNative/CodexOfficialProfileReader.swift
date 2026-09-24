import Foundation

/// Reads the same first-party ChatGPT profile metadata used by Codex's desktop
/// sign-in surface. The bearer token stays in memory and is never persisted or
/// included in diagnostics.
struct CodexOfficialProfileReader {
    private static let profileURL = URL(string: "https://chatgpt.com/backend-api/me")!

    let tokenReader: CodexProfileReader
    let session: URLSession

    init(
        tokenReader: CodexProfileReader = CodexProfileReader(),
        session: URLSession = .shared
    ) {
        self.tokenReader = tokenReader
        self.session = session
    }

    func read() async -> CodexProfileReader.Profile? {
        guard let token = tokenReader.accessToken() else { return nil }

        var request = URLRequest(url: Self.profileURL)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else { return nil }
        return Self.profile(responseData: data)
    }

    static func profile(responseData: Data) -> CodexProfileReader.Profile? {
        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return nil
        }

        func text(_ keys: [String]) -> String? {
            for key in keys {
                if let value = json[key] as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }

        let email = text(["email"])
        let avatarURL = text(["picture", "profile_picture_url", "avatar_url"]).flatMap { raw -> URL? in
            guard let url = URL(string: raw),
                  url.scheme?.lowercased() == "https",
                  url.user == nil,
                  url.password == nil else { return nil }
            return url
        }
        let profile = CodexProfileReader.Profile(
            id: text(["id"]),
            name: text(["name"]),
            email: email,
            username: text(["preferred_username", "username"])
                ?? email?.split(separator: "@").first.map(String.init),
            avatarURL: avatarURL
        )
        return profile.id == nil && profile.name == nil && profile.email == nil && profile.avatarURL == nil
            ? nil
            : profile
    }
}

struct CodexProfileDisplayNameStore {
    private static let profileIDKey = "usageInsights.profileDisplayName.profileID"
    private static let displayNameKey = "usageInsights.profileDisplayName.value"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func displayName(for profileID: String?) -> String? {
        guard let profileID,
              defaults.string(forKey: Self.profileIDKey) == profileID,
              let value = defaults.string(forKey: Self.displayNameKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    func setDisplayName(_ value: String, for profileID: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        defaults.set(profileID, forKey: Self.profileIDKey)
        defaults.set(trimmed, forKey: Self.displayNameKey)
    }
}
