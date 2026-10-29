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
    /// Unix time used by the mini-program to keep Mac-created conversations in recency order.
    var updatedAt: Double? = nil
    var isFavorite: Bool? = nil
}

/// Model capabilities come from the connected Codex app-server. The mini
/// program must not maintain a second, stale model catalog.
struct RemoteModelSnapshot: Codable, Equatable {
    let id: String
    let model: String
    let name: String
    let description: String
    let supportedEfforts: [String]
    let defaultEffort: String
    let supportsFast: Bool
}

struct RemoteHeartbeatBody: Codable, Equatable {
    let name: String
    let permissionLabel: String
    let remoteControlReady: Bool
    let workspaces: [RemoteWorkspaceSnapshot]
    let threads: [RemoteThreadSnapshot]
    var models: [RemoteModelSnapshot] = []
    var usage: RemoteUsageSnapshot? = nil
    var defaultModel: String? = nil
    var defaultEffort: String? = nil
    var systemMetrics: SystemMetricsSnapshot? = nil
    var connectionHealth: RemoteConnectionHealthSnapshot? = nil
    var watchSnapshot: CloudCodexWatchSnapshot? = nil
    var supportsFavorites: Bool = true
    var supportsFiles: Bool = true
    var supportsVoice: Bool = true
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
    var files: [RemoteTaskFile]? = nil
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
    var result: String
    let error: String
    var fileDiff: String? = nil
    var progress: RemoteTaskProgress? = nil
    var recovery: Bool? = nil
    var waitReason: String? = nil
    var actualModel: String? = nil
    var actualEffort: String? = nil
    var tokenUsage: TurnTokenUsageLedger.Record? = nil

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

    let fileExporter = RemoteFileExporter()
    let deviceID: String
    private let deviceSecret: String
    let deviceName: String
    private let baseURL: URL
    private let session: URLSession
    private let ownsSession: Bool

    deinit { if ownsSession { session.invalidateAndCancel() } }

    static func connect(allowInteraction: Bool, configuration: RemoteServerConfiguration = .init(),
                        defaults: UserDefaults = .standard) async throws -> RemoteControlAPI {
        let url = try configuration.validatedURL()
        let secret = try await RemoteCredentialStore.forServer(url).load(allowInteraction: allowInteraction)
        try Task.checkCancellation()
        return RemoteControlAPI(deviceSecret: secret, baseURL: url, defaults: defaults)
    }

    // Constructing the HTTP client never performs Keychain I/O.
    init(
        deviceSecret: String,
        baseURL: URL = RemoteControlAPI.defaultBaseURL,
        session: URLSession? = nil,
        defaults: UserDefaults = .standard
    ) {
        self.baseURL = baseURL
        self.ownsSession = session == nil
        self.session = session ?? URLSession(configuration: .ephemeral, delegate: RemoteRelayRedirectPolicy(), delegateQueue: nil)
        self.deviceSecret = deviceSecret

        let deviceKey = RemoteServerConfiguration.deviceIDKey(for: baseURL)
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

    func createAccountShare(id: String, accountRef: String, code: String, ciphertext: String) async throws {
        let data = try await perform(path: "/api/cloud-codex/agent/account-shares", method: "POST",
            bodyData: JSONSerialization.data(withJSONObject: ["id": id, "accountRef": accountRef, "code": code, "ciphertext": ciphertext, "version": 1]))
        let status = try JSONDecoder().decode(RemoteStatusEnvelope.self, from: data)
        guard status.status == 0 else { throw AccountShareCrypto.failure }
    }
    func listAccountShares() async throws -> [AccountShareRemoteState] {
        try await request(path: "/api/cloud-codex/agent/account-shares", method: "GET", bodyData: nil)
    }
    func publishAccountShare(_ id: String, version: Int64, ciphertext: String) async throws {
        let data = try await perform(path: "/api/cloud-codex/agent/account-shares/\(id)", method: "PUT",
            bodyData: JSONSerialization.data(withJSONObject: ["version": version, "ciphertext": ciphertext]))
        let status = try JSONDecoder().decode(RemoteStatusEnvelope.self, from: data)
        guard status.status == 0 else { throw AccountShareCrypto.failure }
    }
    func revokeAccountShare(_ id: String) async throws {
        let data = try await perform(path: "/api/cloud-codex/agent/account-shares/\(id)", method: "DELETE", bodyData: nil)
        let status = try JSONDecoder().decode(RemoteStatusEnvelope.self, from: data)
        guard status.status == 0 else { throw AccountShareCrypto.failure }
    }

    func unpair() async throws {
        let data = try await perform(path: "/api/cloud-codex/agent/unpair", method: "POST", bodyData: nil)
        let envelope = try JSONDecoder().decode(RemoteStatusEnvelope.self, from: data)
        guard envelope.status == 0 else {
            throw RemoteControlError.server(envelope.msg.isEmpty ? "解除配对失败。" : envelope.msg)
        }
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
    func nextFavorite() async throws -> RemoteFavoriteChange? {
        let data = try await perform(path: "/api/cloud-codex/agent/favorites/next", method: "GET", bodyData: nil)
        return try Self.decodeOptionalEnvelope(RemoteFavoriteChange.self, data: data)
    }
    func finishFavorite(_ id: String, status: String) async throws {
        let data = try await perform(path: "/api/cloud-codex/agent/favorites/\(id)", method: "POST", bodyData: JSONEncoder().encode(["status": status]))
        let envelope = try JSONDecoder().decode(RemoteStatusEnvelope.self, from: data)
        guard envelope.status == 0 else { throw RemoteControlError.server(envelope.msg) }
    }
    func nextReset() async throws -> RemoteResetAttempt? {
        let data = try await perform(path: "/api/cloud-codex/agent/resets/next", method: "GET", bodyData: nil)
        return try Self.decodeOptionalEnvelope(RemoteResetAttempt.self, data: data)
    }
    func finishReset(_ id: String, status: String) async throws {
        let data = try await perform(path: "/api/cloud-codex/agent/resets/\(id)", method: "POST", bodyData: JSONEncoder().encode(["status": status]))
        let envelope = try JSONDecoder().decode(RemoteStatusEnvelope.self, from: data)
        guard envelope.status == 0 else { throw RemoteControlError.server(envelope.msg) }
    }
    func finishHistory(_ id: String, body: RemoteHistoryResponse) async throws {
        let data = try await perform(path: "/api/cloud-codex/agent/history/\(id)", method: "POST", bodyData: JSONEncoder().encode(body))
        let envelope = try JSONDecoder().decode(RemoteStatusEnvelope.self, from: data)
        guard envelope.status == 0 else { throw RemoteControlError.server(envelope.msg) }
    }

    func fileURL(taskID: String, fileID: String) async throws -> RemoteFileDownload {
        try await request(path: "/api/cloud-codex/agent/tasks/\(taskID)/files/\(fileID)", method: "GET", bodyData: nil)
    }

    func uploadFile(_ bytes: Data, name: String, scope: String) async throws -> RemoteTaskFile {
        let boundary = "CloudCodex-" + UUID().uuidString
        let safeName = name.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        body.append(bytes)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let data = try await perform(path: "/api/cloud-codex/agent/\(scope)/files", method: "POST", bodyData: body, contentType: "multipart/form-data; boundary=\(boundary)")
        return try Self.decodeEnvelope(RemoteTaskFile.self, data: data)
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

    func sendNotificationEvent(_ body: RemoteNotificationEventBody) async throws {
        let data = try await perform(
            path: "/api/cloud-codex/agent/events",
            method: "POST",
            bodyData: JSONEncoder().encode(body)
        )
        let envelope = try JSONDecoder().decode(RemoteStatusEnvelope.self, from: data)
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
        bodyData: Data?,
        contentType: String = "application/json"
    ) async throws -> Data {
        let cleanPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let endpoint = baseURL.appendingPathComponent(cleanPath)
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = contentType == "application/json" ? 15 : 120
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
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

/// Never forward a device credential to an HTTP redirect destination.
final class RemoteRelayRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct RemoteFavoriteChange: Codable, Equatable {
    let id: String
    let deviceId: String
    let threadId: String
    let workspace: String
    let favorited: Bool
    var expiresAt: String? = nil

    func isExpired(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return true }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: expiresAt) { return date <= now }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: expiresAt).map { $0 <= now } ?? true
    }
}

struct CloudCodexWatchLink: Codable {
    let controlToken: String?
    let deviceId: String
    let token: String
    let expiresAt: Double
}
extension RemoteControlAPI {
    func createWatchLink() async throws -> CloudCodexWatchLink {
        try await request(path: "/api/cloud-codex/agent/app-link", method: "POST", bodyData: nil)
    }
    func createHardwareLink() async throws -> CloudCodexWatchLink {
        try await request(path: "/api/cloud-codex/agent/hardware-control-link", method: "POST", bodyData: nil)
    }
    func revokeHardwareLink() async throws {
        let data = try await perform(path: "/api/cloud-codex/agent/hardware-link", method: "DELETE", bodyData: nil)
        let envelope = try JSONDecoder().decode(RemoteStatusEnvelope.self, from: data)
        guard envelope.status == 0 else { throw RemoteControlError.server(envelope.msg) }
    }
    func revokeWatchLink() async throws {
        let data = try await perform(path: "/api/cloud-codex/agent/watch-link", method: "DELETE", bodyData: nil)
        let envelope = try JSONDecoder().decode(RemoteStatusEnvelope.self, from: data)
        guard envelope.status == 0 else { throw RemoteControlError.server(envelope.msg) }
    }
}

struct RemoteVoiceDraft: Decodable {
    let id: String
    let workspace: String
    let threadId: String
}
extension RemoteControlAPI {
    func nextVoiceDraft() async throws -> RemoteVoiceDraft? {
        try await request(path: "/api/cloud-codex/agent/voice/next", method: "GET", bodyData: nil)
    }
    func voiceAudio(_ id: String) async throws -> Data {
        guard UUID(uuidString: id) != nil else { throw RemoteControlError.invalidServerResponse }
        let audio = try await perform(path: "/api/cloud-codex/agent/voice/\(id)/audio", method: "GET", bodyData: nil)
        guard audio.count <= 960044 else { throw RemoteControlError.invalidServerResponse }
        return audio
    }
    func finishVoice(_ id: String, transcript: String, error: String) async throws {
        guard UUID(uuidString: id) != nil else { throw RemoteControlError.invalidServerResponse }
        let data = try await perform(path: "/api/cloud-codex/agent/voice/\(id)", method: "POST",
            bodyData: JSONSerialization.data(withJSONObject: ["transcript": transcript, "error": error]))
        let response = try JSONDecoder().decode(RemoteStatusEnvelope.self, from: data)
        guard response.status == 0 else { throw RemoteControlError.server(response.msg) }
    }
}
