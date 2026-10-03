import Foundation

// Public defaults and their official sources are recorded in docs/model-providers.md.
enum SupportedModelService: String, Codable, CaseIterable, Identifiable {
    case deepseek, aliyun, volcengine
    var id: String { rawValue }
    var title: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .aliyun: return "阿里云百炼"
        case .volcengine: return "火山引擎方舟"
        }
    }
    var efforts: [String] {
        switch self {
        case .deepseek: return ["low", "high", "max"]
        case .aliyun: return ["low", "medium", "high", "xhigh"]
        case .volcengine: return ["low", "medium", "high"]
        }
    }
    var defaultEffort: String { self == .deepseek ? "high" : "medium" }
    var documentationURL: URL {
        switch self {
        case .deepseek: return URL(string: "https://api-docs.deepseek.com/quick_start/agent_integrations/codex/")!
        case .aliyun: return URL(string: "https://help.aliyun.com/zh/model-studio/codex")!
        case .volcengine: return URL(string: "https://docs.volcengine.com/docs/ark/coding-plan-personal-ai-codex?lang=zh")!
        }
    }
    func subscriptionTitle() -> String {
        self == .aliyun ? "Token Plan" : "Coding Plan"
    }
    func defaultURL(subscription: Bool) -> String {
        switch self {
        case .deepseek: return "https://api.deepseek.com"
        case .aliyun:
            return subscription ? "https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1" : ""
        case .volcengine:
            return subscription ? "https://ark.cn-beijing.volces.com/api/coding/v3" : "https://ark.cn-beijing.volces.com/api/v3"
        }
    }
    func defaultModel(subscription: Bool) -> String {
        switch self {
        case .deepseek: return "deepseek-flash"
        case .aliyun: return subscription ? "auto" : "qwen3.7-max"
        case .volcengine: return subscription ? "ark-code-latest" : ""
        }
    }
    func accepts(_ url: URLComponents, subscription: Bool) -> Bool {
        let host = url.host?.lowercased() ?? ""
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard url.scheme?.lowercased() == "https", url.port == nil || url.port == 443 else { return false }
        switch self {
        case .deepseek:
            return host == "api.deepseek.com" && (path.isEmpty || path == "v1")
        case .aliyun:
            // New Responses endpoints are workspace/Token Plan endpoints, not Coding Plan's chat endpoint.
            guard path == "compatible-mode/v1", host.hasSuffix(".maas.aliyuncs.com") else { return false }
            if subscription { return host.hasPrefix("token-plan.") }
            return !host.hasPrefix("token-plan.") && !host.contains("{") && !host.contains("}")
        case .volcengine:
            return host == "ark.cn-beijing.volces.com" && path == (subscription ? "api/coding/v3" : "api/v3")
        }
    }
}
