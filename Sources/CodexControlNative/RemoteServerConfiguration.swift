import Foundation
import CryptoKit

struct RemoteServerConfiguration: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable { case builtIn, custom }
    static let defaultsKey = "CloudCodex.remoteControl.server.v1"
    var mode: Mode = .builtIn
    var customAddress = ""

    static func load(_ defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: defaultsKey) else { return Self() }
        // A damaged custom configuration must never silently use the built-in relay.
        return (try? JSONDecoder().decode(Self.self, from: data)) ?? Self(mode: .custom)
    }

    func validatedURL() throws -> URL {
        if mode == .builtIn { return RemoteControlAPI.defaultBaseURL }
        let raw = customAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: raw),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!),
              !parts.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw RemoteControlError.server("请输入完整 HTTPS 服务地址，不含账号、密码、查询参数或片段；可保留后端路径前缀。")
        }
        parts.scheme = "https"
        parts.host = host.lowercased()
        if parts.port == 443 { parts.port = nil }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let url = parts.url else { throw RemoteControlError.server("服务地址无效。") }
        return url
    }

    static func scope(for url: URL) -> String {
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if parts.port == 443 { parts.port = nil }
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        let normalized = parts.string!
        if normalized == RemoteControlAPI.defaultBaseURL.absoluteString { return "" }
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func credentialAccount(for url: URL) -> String {
        let scope = scope(for: url)
        return "remote-control-device-secret-v1" + (scope.isEmpty ? "" : "-\(scope)")
    }

    static func deviceIDKey(for url: URL) -> String {
        let scope = scope(for: url)
        return "CloudCodex.remoteControl.deviceID.v1" + (scope.isEmpty ? "" : ".\(scope)")
    }
}
