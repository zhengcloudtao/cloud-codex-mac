import Foundation
import Security
import CryptoKit

struct ModelProviderConfiguration: Codable, Equatable {
    static let defaultsKey = "cloudcodex.modelProvider.v1"
    static let providerID = "cloudcodex_custom"
    static let environmentKey = "CLOUDCODEX_MODEL_API_KEY"
    var enabled = false
    var name = "第三方服务"
    var baseURL = ""
    var modelID = ""
    var reasoningEffort = "none"
    var supportedReasoningEfforts: [String]? = nil
    // Optional to preserve already-saved v1 generic configurations without silently rerouting them.
    var service: SupportedModelService? = nil
    var subscription: Bool? = nil

    var usesSubscription: Bool { subscription ?? (service != .deepseek) }
    var credentialAccount: String {
        guard let service else { return "custom-api-key" }
        let host = URLComponents(string: baseURL)?.host?.lowercased() ?? ""
        return "\(service.rawValue).\(usesSubscription ? "subscription" : "usage").\(host)"
    }

    mutating func select(_ service: SupportedModelService, subscription: Bool? = nil) {
        self.service = service
        let usesSubscription = service == .deepseek ? false : (subscription ?? true)
        self.subscription = usesSubscription
        name = service.title
        baseURL = service.defaultURL(subscription: usesSubscription)
        modelID = service.defaultModel(subscription: usesSubscription)
        supportedReasoningEfforts = nil
        reasoningEffort = service.defaultEffort
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    func validated() throws -> Self {
        var value = self
        value.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        value.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URLComponents(string: value.baseURL),
           url.user != nil || url.password != nil || url.query != nil || url.fragment != nil {
            throw ModelProviderError.message("Base URL 不能包含账号、查询参数或片段，请在单独的密钥框填写 API Key。")
        }
        guard enabled else { return value }
        let efforts = supportedReasoningEfforts ?? service?.efforts ?? ["none", "low", "medium", "high", "xhigh"]
        guard efforts.contains(value.reasoningEffort),
              !value.name.isEmpty, !value.modelID.isEmpty,
              !value.modelID.contains(where: { $0.isNewline || $0.isWhitespace }) else {
            throw ModelProviderError.message("请填写服务商名称和有效的模型 ID。")
        }
        guard let url = URLComponents(string: value.baseURL), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)) else {
            throw ModelProviderError.message("Base URL 必须是 HTTPS 地址；本机服务可用 HTTP。地址不能包含账号、查询参数或片段。")
        }
        while value.baseURL.hasSuffix("/") { value.baseURL.removeLast() }
        if let service {
            guard service.accepts(url, subscription: usesSubscription) else {
                throw ModelProviderError.message("地址与所选服务商或接入方式不匹配，请从该服务商控制台复制正确地址。")
            }
            value.name = service.title
        }
        return value
    }

    func launchArguments(catalogDirectory: URL? = nil, models: [String] = [], options: [CodexModelOption] = []) throws -> [String] {
        guard enabled, service != nil else { return arguments }
        let directory = catalogDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CloudCodex/ModelCatalogs", isDirectory: true)
        let catalog: [String: Any]
        if models.isEmpty { catalog = modelCatalog }
        else {
            catalog = ["models": models.flatMap { model -> [[String: Any]] in
                var value = self; value.modelID = model
                var entries = value.modelCatalog["models"] as? [[String: Any]] ?? []
                if let option = options.first(where: { $0.model == model }), !entries.isEmpty {
                    entries[0]["display_name"] = option.displayName
                    entries[0]["default_reasoning_level"] = option.defaultEffort
                    entries[0]["supported_reasoning_levels"] = option.supportedEfforts.map { ["effort": $0, "description": $0] }
                }
                return entries
            }]
        }
        let data = try JSONSerialization.data(withJSONObject: catalog, options: [.sortedKeys])
        let filename = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".json"
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(filename)
        try data.write(to: path, options: .atomic)
        return arguments + ["-c", "model_catalog_json=\(Self.quoted(path.path))"]
    }

    var modelCatalog: [String: Any] {
        let deepseek = service == .deepseek
        var entry: [String: Any] = [
            "slug": modelID, "display_name": modelID, "description": name,
            "default_reasoning_level": reasoningEffort,
            "supported_reasoning_levels": (service?.efforts ?? [reasoningEffort]).map { ["effort": $0, "description": $0] },
            "shell_type": deepseek ? "shell_command" : "default",
            "visibility": "list", "supported_in_api": true, "priority": 1,
            "base_instructions": "You are a coding assistant working in the user's workspace. Follow the user's instructions and applicable AGENTS.md files. Inspect relevant files before editing, preserve unrelated changes, use tools to complete authorized work, and verify changes with appropriate checks. Never expose credentials. Report results and unverified limitations clearly in the user's language.", "support_verbosity": false,
            "supports_reasoning_summaries": deepseek,
            "supports_parallel_tool_calls": false,
            "supports_image_detail_original": false,
            "input_modalities": deepseek && modelID == "deepseek-flash" ? ["text", "image"] : ["text"],
            "context_window": deepseek ? 1_048_576 : 128_000,
            "effective_context_window_percent": 95,
            "experimental_supported_tools": [], "use_responses_lite": false,
            "prefer_websockets": false,
            "truncation_policy": ["mode": "tokens", "limit": 10000]
        ]
        // Current Codex accepts only freeform patch tools. Alibaba's official catalog
        // omits this capability; its models can edit through the standard shell tool.
        if service != .aliyun { entry["apply_patch_tool_type"] = "freeform" }
        return ["models": [entry]]
    }

    // JSON basic strings are valid TOML basic strings. Values never pass through a shell.
    static func quoted(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(data: try! encoder.encode(value), encoding: .utf8)!
    }

    var arguments: [String] {
        guard enabled else { return [] }
        let fields = [
            "model_provider=\(Self.quoted(Self.providerID))",
            "model=\(Self.quoted(modelID))",
            "model_reasoning_effort=\(Self.quoted(reasoningEffort))",
            "model_reasoning_summary=\"none\"",
            "service_tier=\"default\"",
            "web_search=\"disabled\"",
            "features.multi_agent=false",
            "features.goals=false",
            "shell_environment_policy.filters.\(Self.environmentKey)=\"exclude\"",
            "model_providers.\(Self.providerID).name=\(Self.quoted(name))",
            "model_providers.\(Self.providerID).base_url=\(Self.quoted(baseURL))",
            "model_providers.\(Self.providerID).env_key=\(Self.quoted(Self.environmentKey))",
            "model_providers.\(Self.providerID).wire_api=\"responses\"",
            "model_providers.\(Self.providerID).requires_openai_auth=false"
        ]
        return fields.flatMap { ["-c", $0] }
    }

    var modelOption: CodexModelOption? {
        CodexModelOption(json: ["id": modelID, "model": modelID, "displayName": modelID,
            "description": name, "isDefault": true, "defaultReasoningEffort": reasoningEffort,
            "supportedReasoningEfforts": [["reasoningEffort": reasoningEffort]]])
    }
}

enum ModelProviderError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}

// Keys are stored separately from non-sensitive preferences and process arguments.
enum ModelProviderKeychain {
    private static func identity(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "CloudCodex.model-provider",
         kSecAttrAccount as String: account]
    }
    static func load(account: String = "custom-api-key") async throws -> String? {
        try await Task.detached {
            var query = identity(account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data,
                  let key = String(data: data, encoding: .utf8) else {
                throw ModelProviderError.message("无法读取模型服务商密钥，请检查钥匙串授权。")
            }
            return key
        }.value
    }
    static func save(_ key: String, account: String = "custom-api-key") async throws {
        try await Task.detached {
            let attributes = [kSecValueData as String: Data(key.utf8)]
            var status = SecItemUpdate(identity(account: account) as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var query = identity(account: account)
                query[kSecValueData as String] = Data(key.utf8)
                query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                status = SecItemAdd(query as CFDictionary, nil)
            }
            guard status == errSecSuccess else {
                throw ModelProviderError.message("无法保存模型服务商密钥，请检查钥匙串授权。")
            }
        }.value
    }
}

struct ModelProviderConnectionProbe {
    static func check(_ configuration: ModelProviderConfiguration, key: String,
                      session: URLSession? = nil) async throws -> String {
        let configuration = try configuration.validated()
        guard configuration.enabled, !key.isEmpty,
              let url = URL(string: configuration.baseURL + "/models") else {
            throw ModelProviderError.message("请启用第三方服务并填写 API Key。")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let ownedSession = session ?? URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        defer { if session == nil { ownedSession.invalidateAndCancel() } }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await ownedSession.data(for: request) }
        catch { throw ModelProviderError.message("连接失败，请检查地址、网络和证书。") }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw ModelProviderError.message("模型列表请求失败（HTTP \(code)）。请检查地址、密钥和服务商是否提供 /models。")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["data"] as? [[String: Any]] else {
            throw ModelProviderError.message("服务未返回兼容的模型列表。")
        }
        let found = models.contains { $0["id"] as? String == configuration.modelID }
        return found ? "连接成功，模型 ID 已找到。尚未验证 Responses 生成和工具调用。"
                     : "连接成功，但列表中没有该模型 ID，请向服务商核实。尚未验证 Responses 生成和工具调用。"
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
