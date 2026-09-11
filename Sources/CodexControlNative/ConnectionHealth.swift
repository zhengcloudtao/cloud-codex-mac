import Foundation
import Network

struct RemoteConnectionHealthSnapshot: Codable, Equatable {
    let networkState: String
    let gptState: String
    let failureKind: String?
    let checkedAt: Double?
    let capturedAt: Double

    static func failureKind(for rawError: String) -> String {
        let error = rawError.lowercased()
        if error.contains("token_revoked")
            || error.contains("invalidated oauth token")
            || error.contains("authentication token is invalid")
            || error.contains("unauthorized") {
            return "auth"
        }
        if error.contains("timed out") || error.contains("timeout") {
            return "timeout"
        }
        if error.contains("network")
            || error.contains("connection")
            || error.contains("offline")
            || error.contains("not connected") {
            return "network"
        }
        if error.contains("not supported") || error.contains("unsupported") || error.contains("method not found") {
            return "unsupported"
        }
        return "unknown"
    }
}

@MainActor
final class ConnectionHealth: ObservableObject {
    @Published private(set) var networkAvailable: Bool?
    @Published private(set) var serviceText = "GPT 待检测"
    @Published private(set) var serviceReachable = false
    @Published private(set) var isChecking = false
    @Published private(set) var checkedAt: Date?
    @Published private(set) var detail = "通过本机 Codex 的只读账号接口检测，不发送测试提问。"
    @Published private(set) var failureKind: String?
    private var updatedAt = Date()
    private let monitor = NWPathMonitor()
    private var loop: Task<Void, Never>?
    private var probe: (() async throws -> Void)?
    private var revision = 0

    var networkText: String {
        switch networkAvailable {
        case true: return "网络已连接"
        case false: return "网络已断开"
        case nil: return "网络检测中"
        }
    }

    func start(probe: @escaping () async throws -> Void) {
        guard self.probe == nil else { return }
        self.probe = probe
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.revision += 1
                self.networkAvailable = available
                self.serviceReachable = false
                self.serviceText = available ? "GPT 待检测" : "GPT 无网络"
                self.checkedAt = nil
                self.failureKind = available ? nil : "network"
                self.updatedAt = Date()
                self.detail = available ? "等待通过当前网络检测 Codex 账号接口。" : "系统未发现可用网络路径。"
                if available { await self.check() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "cloudcodex.network-health"))
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.check()
            }
        }
    }

    func check() async {
        guard networkAvailable == true, !isChecking, let probe else { return }
        isChecking = true
        serviceText = "GPT 检测中"
        serviceReachable = false
        failureKind = nil
        updatedAt = Date()
        let revision = self.revision
        defer { isChecking = false }
        do {
            try await probe()
            guard revision == self.revision else { return }
            serviceText = "GPT 接口可访问"
            serviceReachable = true
            checkedAt = Date()
            failureKind = nil
            updatedAt = checkedAt ?? Date()
            detail = "本机 Codex 账号额度接口已响应。此结果不是模型推理测速，也不能保证每次请求成功。"
        } catch {
            guard revision == self.revision else { return }
            serviceText = "GPT 检测失败"
            serviceReachable = false
            checkedAt = Date()
            failureKind = RemoteConnectionHealthSnapshot.failureKind(for: error.localizedDescription)
            updatedAt = checkedAt ?? Date()
            detail = "账号接口检测失败，可能与登录、网络、代理或当前配置不支持该接口有关，不直接判定 GPT 宕机。\n\(error.localizedDescription)"
        }
    }

    var remoteSnapshot: RemoteConnectionHealthSnapshot {
        let networkState: String
        switch networkAvailable {
        case true: networkState = "connected"
        case false: networkState = "disconnected"
        case nil: networkState = "checking"
        }
        let gptState: String
        if isChecking {
            gptState = "checking"
        } else if serviceReachable {
            gptState = "connected"
        } else if networkAvailable == false {
            gptState = "noNetwork"
        } else if checkedAt != nil {
            gptState = "failed"
        } else {
            gptState = "pending"
        }
        return .init(
            networkState: networkState,
            gptState: gptState,
            failureKind: failureKind,
            checkedAt: checkedAt?.timeIntervalSince1970,
            capturedAt: updatedAt.timeIntervalSince1970
        )
    }

    deinit { monitor.cancel(); loop?.cancel() }
}
