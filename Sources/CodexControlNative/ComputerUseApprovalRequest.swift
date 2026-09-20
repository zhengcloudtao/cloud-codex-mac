import Foundation

struct ComputerUseApprovalRequest: Identifiable, Equatable {
    enum Decision: Equatable { case allowSession, allowAlways, decline, cancel }

    let requestID: AppServerRequestID
    let threadID: String
    let turnID: String?
    let serverName: String
    let message: String
    let applicationName: String
    let bundleIdentifier: String?
    let toolName: String?
    let warning: String?
    let allowsAlways: Bool
    let expiresAt: Date
    var isSubmitting = false
    var error: String?

    var id: String { requestID.stableID }

    init?(requestID: AppServerRequestID, params: [String: Any], receivedAt: Date = Date(), timeout: TimeInterval = 60) {
        guard let threadID = params["threadId"] as? String,
              let serverName = params["serverName"] as? String,
              let mode = params["mode"] as? String,
              ["form", "openai/form", "openaiForm"].contains(mode),
              let message = params["message"] as? String else { return nil }
        let metadata = (params["_meta"] as? [String: Any]) ?? (params["meta"] as? [String: Any]) ?? [:]
        let connectorID = metadata["connector_id"] as? String
        let normalizedServer = serverName.lowercased()
        guard connectorID == "computer-use" || normalizedServer == "cua_repl" || normalizedServer.contains("computer-use") else { return nil }

        let displayRows = metadata["tool_params_display"] as? [[String: Any]] ?? []
        let displayedApp = displayRows.first(where: { ($0["name"] as? String) == "app" })?["value"] as? String
        let toolParams = metadata["tool_params"] as? [String: Any] ?? [:]
        let bundleIdentifier = toolParams["app"] as? String

        self.requestID = requestID
        self.threadID = threadID
        self.turnID = params["turnId"] as? String
        self.serverName = serverName
        self.message = message
        self.applicationName = displayedApp ?? Self.applicationName(from: message) ?? bundleIdentifier ?? "目标应用"
        self.bundleIdentifier = bundleIdentifier
        self.toolName = metadata["tool_name"] as? String
        self.warning = metadata["subtitle"] as? String
        self.allowsAlways = (metadata["persist"] as? [String] ?? []).contains("always")
        self.expiresAt = receivedAt.addingTimeInterval(max(0, timeout))
    }

    func responsePayload(for decision: Decision) -> [String: Any] {
        switch decision {
        case .allowSession:
            return ["action": "accept", "content": NSNull(), "_meta": ["persist": "session"]]
        case .allowAlways:
            return ["action": "accept", "content": NSNull(), "_meta": ["persist": "always"]]
        case .decline:
            return ["action": "decline", "content": NSNull(), "_meta": NSNull()]
        case .cancel:
            return ["action": "cancel", "content": NSNull(), "_meta": NSNull()]
        }
    }

    private static func applicationName(from message: String) -> String? {
        guard let firstQuote = message.firstIndex(of: "\"") else { return nil }
        let remainder = message[message.index(after: firstQuote)...]
        guard let secondQuote = remainder.firstIndex(of: "\"") else { return nil }
        let name = String(remainder[..<secondQuote]).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}
