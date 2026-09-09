import Foundation

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
    var usage: RemoteUsageSnapshot? = nil
    var defaultModel: String? = nil
    var defaultEffort: String? = nil
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
    var action: String? = nil // Reject legacy queued file-preview actions.
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
    var runningTasks: [RemoteRecoveryTask]? = nil
    var queueSummary: RemoteQueueSummary? = nil
}

/// Only identifiers are returned by the relay. Never replay a prompt during recovery.
struct RemoteRecoveryTask: Codable, Equatable {
    let taskId: String
    let threadId: String
    let turnId: String
    let workspace: String

    func terminalUpdate(from turn: [String: Any]) -> RemoteTaskStatusBody? {
        guard !turnId.isEmpty, !threadId.isEmpty, turn["id"] as? String == turnId,
              let status = turn["status"] as? String,
              ["completed", "interrupted", "failed"].contains(status) else { return nil }
        let items = turn["items"] as? [[String: Any]] ?? []
        let result = items.last(where: { $0["type"] as? String == "agentMessage" })?["text"] as? String ?? ""
        let message = (turn["error"] as? [String: Any])?["message"] as? String
        return RemoteTaskStatusBody(
            status: status == "completed" ? "completed" : "failed",
            threadId: threadId, turnId: turnId, result: String(result.suffix(60_000)),
            error: message ?? (status == "interrupted" ? "Codex 此轮已中止，Mac 重连后已同步状态。" : status == "failed" ? "Codex 此轮执行失败，Mac 重连后已同步状态。" : ""),
            recovery: true
        )
    }
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
    var progress: RemoteTaskProgress? = nil
    var recovery: Bool? = nil
    var waitReason: String? = nil
    var actualModel: String? = nil
    var actualEffort: String? = nil

    func withActualSettings(_ metadata: TurnModelMetadata?) -> Self {
        var copy = self
        guard !turnId.isEmpty, let metadata else { return copy }
        copy.actualModel = metadata.model
        copy.actualEffort = metadata.reasoningEffort
        return copy
    }
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
    private let deviceSecret: String
    let deviceName: String
    private let baseURL: URL
    private let session: URLSession

    static func connect(allowInteraction: Bool) async throws -> RemoteControlAPI {
        let secret = try await RemoteCredentialStore.shared.load(allowInteraction: allowInteraction)
        try Task.checkCancellation()
        return RemoteControlAPI(deviceSecret: secret)
    }

    // Constructing the HTTP client never performs Keychain I/O.
    init(
        deviceSecret: String,
        baseURL: URL = RemoteControlAPI.defaultBaseURL,
        session: URLSession = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.baseURL = baseURL
        self.session = session
        self.deviceSecret = deviceSecret

        let deviceKey = "CloudCodex.remoteControl.deviceID.v1"
        if let saved = defaults.string(forKey: deviceKey), !saved.isEmpty {
            deviceID = saved
        } else {
            let generated = UUID().uuidString.lowercased()
            defaults.set(generated, forKey: deviceKey)
            deviceID = generated
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

    func nextHistory() async throws -> RemoteHistoryRead? {
        let data = try await perform(path: "/api/cloud-codex/agent/history/next", method: "GET", bodyData: nil)
        return try Self.decodeOptionalEnvelope(RemoteHistoryRead.self, data: data)
    }
    func finishHistory(_ id: String, body: RemoteHistoryResponse) async throws {
        let data = try await perform(path: "/api/cloud-codex/agent/history/\(id)", method: "POST", bodyData: JSONEncoder().encode(body))
        let envelope = try JSONDecoder().decode(RemoteStatusEnvelope.self, from: data)
        guard envelope.status == 0 else { throw RemoteControlError.server(envelope.msg) }
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

}
