import Foundation
import Security

struct RemoteWorkspaceSnapshot: Codable, Equatable {
    let path: String
    let name: String
}

struct RemoteThreadSnapshot: Codable, Equatable {
    let id: String
    let title: String
    let workspace: String
    let model: String
    let status: String
}

struct RemoteHeartbeatBody: Codable, Equatable {
    let name: String
    let permissionLabel: String
    let remoteControlReady: Bool
    let workspaces: [RemoteWorkspaceSnapshot]
    let threads: [RemoteThreadSnapshot]
}

struct RemoteTask: Codable, Equatable {
    let taskId: String
    let deviceId: String
    let threadId: String
    let workspace: String
    let prompt: String
    let model: String
    let effort: String
    let status: String
    var speed: String? = nil
    var permissionMode: String? = nil
    var imageUrls: [String]? = nil
}

struct RemoteRegistration: Codable, Equatable {
    let deviceId: String
    let name: String
    let paired: Bool
    let pairingCode: String
    let pairingExpiresAt: String?
    let pollIntervalSeconds: Int
}

struct RemoteHeartbeatResponse: Codable, Equatable {
    let paired: Bool
}

private struct RemoteRegistrationBody: Codable {
    let name: String
    let resetPairing: Bool
}

struct RemoteTaskStatusBody: Codable, Equatable {
    let status: String
    let threadId: String
    let turnId: String
    let result: String
    let error: String
    var fileDiff: String? = nil
}

private struct RemoteEnvelope<Value: Decodable>: Decodable {
    let status: Int
    let msg: String
    let data: Value?
}

private struct RemoteStatusEnvelope: Decodable {
    let status: Int
    let msg: String
}

enum RemoteControlError: LocalizedError {
    case invalidServerResponse
    case server(String)
    case missingCredential

    var errorDescription: String? {
        switch self {
        case .invalidServerResponse:
            return "远程服务返回了无法识别的数据。"
        case .server(let message):
            return message
        case .missingCredential:
            return "无法创建安全的设备凭据。"
        }
    }
}

final class RemoteControlAPI: @unchecked Sendable {
    static let defaultBaseURL = URL(string: "https://api.cloudslow.com/ai")!

    let deviceID: String
    let deviceSecret: String
    let deviceName: String
    private let baseURL: URL
    private let session: URLSession

    init(
        baseURL: URL = RemoteControlAPI.defaultBaseURL,
        session: URLSession = .shared,
        defaults: UserDefaults = .standard
    ) throws {
        self.baseURL = baseURL
        self.session = session

        let deviceKey = "CloudCodex.remoteControl.deviceID.v1"
        if let saved = defaults.string(forKey: deviceKey), !saved.isEmpty {
            deviceID = saved
        } else {
            let generated = UUID().uuidString.lowercased()
            defaults.set(generated, forKey: deviceKey)
            deviceID = generated
        }

        let keychainAccount = "remote-control-device-secret-v1"
        if let saved = Self.readKeychain(account: keychainAccount) {
            deviceSecret = saved
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw RemoteControlError.missingCredential
            }
            let generated = Data(bytes).base64EncodedString()
            guard Self.writeKeychain(generated, account: keychainAccount) else {
                throw RemoteControlError.missingCredential
            }
            deviceSecret = generated
        }

        deviceName = Host.current().localizedName ?? "CloudCodex Mac"
    }

    func register(resetPairing: Bool = false) async throws -> RemoteRegistration {
        try await request(
            path: "/api/cloud-codex/agent/register",
            method: "POST",
            body: RemoteRegistrationBody(name: deviceName, resetPairing: resetPairing)
        )
    }

    func heartbeat(_ body: RemoteHeartbeatBody) async throws -> RemoteHeartbeatResponse {
        try await request(path: "/api/cloud-codex/agent/heartbeat", method: "POST", body: body)
    }

    func nextTask() async throws -> RemoteTask? {
        let data = try await perform(path: "/api/cloud-codex/agent/tasks/next", method: "GET", bodyData: nil)
        return try Self.decodeOptionalEnvelope(RemoteTask.self, data: data)
    }

    func updateTask(_ taskID: String, body: RemoteTaskStatusBody) async throws {
        let data = try JSONEncoder().encode(body)
        let responseData = try await perform(
            path: "/api/cloud-codex/agent/tasks/\(taskID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? taskID)/status",
            method: "POST",
            bodyData: data
        )
        let envelope = try JSONDecoder().decode(RemoteStatusEnvelope.self, from: responseData)
        guard envelope.status == 0 else { throw RemoteControlError.server(envelope.msg) }
    }

    private func request<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body
    ) async throws -> Response {
        let data = try JSONEncoder().encode(body)
        return try await request(path: path, method: method, bodyData: data)
    }

    private func request<Response: Decodable>(
        path: String,
        method: String,
        bodyData: Data?
    ) async throws -> Response {
        let data = try await perform(path: path, method: method, bodyData: bodyData)
        return try Self.decodeEnvelope(Response.self, data: data)
    }

    private func perform(
        path: String,
        method: String,
        bodyData: Data?
    ) async throws -> Data {
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let endpoint = baseURL.appendingPathComponent(cleanPath)
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceID, forHTTPHeaderField: "X-CloudCodex-Device")
        request.setValue(deviceSecret, forHTTPHeaderField: "X-CloudCodex-Token")
        request.httpBody = bodyData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw RemoteControlError.invalidServerResponse
        }
        return data
    }

    static func decodeEnvelope<Value: Decodable>(_ type: Value.Type, data: Data) throws -> Value {
        let envelope: RemoteEnvelope<Value>
        do {
            envelope = try JSONDecoder().decode(RemoteEnvelope<Value>.self, from: data)
        } catch {
            throw RemoteControlError.invalidServerResponse
        }
        guard envelope.status == 0 else {
            throw RemoteControlError.server(envelope.msg.isEmpty ? "远程服务操作失败。" : envelope.msg)
        }
        guard let value = envelope.data else {
            throw RemoteControlError.invalidServerResponse
        }
        return value
    }

    static func decodeOptionalEnvelope<Value: Decodable>(_ type: Value.Type, data: Data) throws -> Value? {
        let envelope: RemoteEnvelope<Value>
        do {
            envelope = try JSONDecoder().decode(RemoteEnvelope<Value>.self, from: data)
        } catch {
            throw RemoteControlError.invalidServerResponse
        }
        guard envelope.status == 0 else {
            throw RemoteControlError.server(envelope.msg.isEmpty ? "远程服务操作失败。" : envelope.msg)
        }
        return envelope.data
    }

    private static func readKeychain(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.cloudslow.CloudCodex",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeKeychain(_ value: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.cloudslow.CloudCodex",
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
