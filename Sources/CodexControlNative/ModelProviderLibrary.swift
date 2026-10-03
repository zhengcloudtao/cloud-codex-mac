import Foundation

struct AdditionalOpenAIModel: Codable, Equatable, Identifiable {
    var id = UUID()
    var modelID = ""
    var displayName: String? = nil
    var effortsText = "low,medium,high"
    var defaultEffort = "medium"
    var efforts: [String] {
        effortsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    var option: CodexModelOption? {
        guard !modelID.isEmpty else { return nil }
        return CodexModelOption(json: ["id": ModelProviderProfile.optionID(provider: "openai", model: modelID),
            "model": modelID, "displayName": displayName?.isEmpty == false ? displayName! : modelID, "description": "OpenAI · 手动配置",
            "defaultReasoningEffort": defaultEffort,
            "supportedReasoningEfforts": efforts.map { ["reasoningEffort": $0] }])
    }
    func validated() throws -> Self {
        var result = self
        result.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed: Set<String> = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra", "persistent"]
        guard !result.modelID.isEmpty, !result.modelID.contains(where: { $0.isWhitespace }),
              !efforts.isEmpty, Set(efforts).count == efforts.count,
              efforts.allSatisfy({ allowed.contains($0) }), efforts.contains(defaultEffort) else {
            throw ModelProviderError.message("OpenAI：请填写有效模型 ID、支持的推理档位和其中一个默认档位。")
        }
        result.effortsText = efforts.joined(separator: ",")
        return result
    }
}

/// Optional per-model metadata keeps existing v2 model lists and Keychain identities compatible.
struct ProviderModelDetails: Codable, Equatable {
    var displayName = ""
    var effortsText = ""
    var defaultEffort = ""

    var efforts: [String] {
        effortsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func validated() throws -> Self {
        var result = self
        result.displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        result.defaultEffort = defaultEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed: Set<String> = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra", "persistent"]
        guard !efforts.isEmpty, Set(efforts).count == efforts.count,
              efforts.allSatisfy({ allowed.contains($0) }), efforts.contains(result.defaultEffort) else {
            throw ModelProviderError.message("请为每个模型填写支持的推理档位（英文逗号分隔），默认档位必须在其中。")
        }
        result.effortsText = efforts.joined(separator: ",")
        return result
    }
}

struct ModelProviderProfile: Codable, Equatable, Identifiable {
    var id: String
    var configuration: ModelProviderConfiguration
    var modelIDs: [String]
    var modelDetails: [String: ProviderModelDetails]? = nil

    func details(for modelID: String) -> ProviderModelDetails {
        modelDetails?[modelID] ?? ProviderModelDetails(
            effortsText: (configuration.service?.efforts ?? [configuration.reasoningEffort]).joined(separator: ","),
            defaultEffort: configuration.supportedReasoningEfforts == nil ? configuration.reasoningEffort : (configuration.service?.defaultEffort ?? configuration.reasoningEffort))
    }

    init(service: SupportedModelService) {
        id = service.rawValue
        configuration = ModelProviderConfiguration()
        configuration.select(service)
        modelIDs = configuration.modelID.isEmpty ? [] : [configuration.modelID]
    }

    var options: [CodexModelOption] {
        guard configuration.enabled else { return [] }
        return modelIDs.compactMap { modelID in
            let detail = details(for: modelID)
            return CodexModelOption(json: ["id": Self.optionID(provider: id, model: modelID),
                "model": modelID, "displayName": "\(configuration.name) · \(detail.displayName.isEmpty ? modelID : detail.displayName)",
                "description": configuration.name, "isDefault": modelID == configuration.modelID,
                "defaultReasoningEffort": detail.defaultEffort,
                "supportedReasoningEfforts": detail.efforts
                    .map { ["reasoningEffort": $0] }])
        }
    }

    static func optionID(provider: String, model: String) -> String { "provider:\(provider):\(model)" }

    func validated() throws -> Self {
        var result = self
        result.modelIDs = modelIDs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !configuration.enabled { result.configuration = try configuration.validated() }
        guard configuration.enabled else { return result }
        guard !result.modelIDs.isEmpty, Set(result.modelIDs).count == result.modelIDs.count,
              result.modelIDs.allSatisfy({ !$0.isEmpty && !$0.contains(where: { $0.isWhitespace }) }) else {
            throw ModelProviderError.message("\(configuration.name)：请填写至少一个模型 ID，不能留空或重复。")
        }
        if !result.modelIDs.contains(result.configuration.modelID) { result.configuration.modelID = result.modelIDs[0] }
        if let metadata = modelDetails {
            var normalized: [String: ProviderModelDetails] = [:]
            for (key, detail) in metadata {
                let modelID = key.trimmingCharacters(in: .whitespacesAndNewlines)
                guard result.modelIDs.contains(modelID) else { continue }
                guard normalized[modelID] == nil else { throw ModelProviderError.message("模型配置重复，请检查模型 ID。") }
                normalized[modelID] = try detail.validated()
            }
            result.modelDetails = normalized
        }
        if let detail = result.modelDetails?[result.configuration.modelID] {
            result.configuration.reasoningEffort = detail.defaultEffort
            result.configuration.supportedReasoningEfforts = detail.efforts
        } else {
            if result.configuration.supportedReasoningEfforts != nil {
                result.configuration.reasoningEffort = result.configuration.service?.defaultEffort ?? result.configuration.reasoningEffort
            }
            result.configuration.supportedReasoningEfforts = nil
        }
        result.configuration = try result.configuration.validated()
        return result
    }
}

struct ModelProviderLibrary: Codable, Equatable {
    static let defaultsKey = "cloudcodex.modelProviders.v2"
    static let openAI = "openai"
    var defaultProviderID = Self.openAI
    var profiles = SupportedModelService.allCases.map(ModelProviderProfile.init)
    var additionalOpenAIModels: [AdditionalOpenAIModel]? = nil
    var openAIDefaultModelID: String? = nil

    static func load(from defaults: UserDefaults = .standard) -> Self {
        if let data = defaults.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(Self.self, from: data) { return saved }
        let old = ModelProviderConfiguration.load(from: defaults)
        var result = Self()
        if !old.baseURL.isEmpty {
            let id = old.service?.rawValue ?? "legacy"
            var profile = ModelProviderProfile(service: old.service ?? .deepseek)
            profile.id = id; profile.configuration = old; profile.modelIDs = old.modelID.isEmpty ? [] : [old.modelID]
            if let index = result.profiles.firstIndex(where: { $0.id == id }) { result.profiles[index] = profile }
            else { result.profiles.append(profile) }
            if old.enabled { result.defaultProviderID = id }
        }
        return result
    }

    func providerIDAfterSaving(current: String) -> String {
        if current == Self.openAI || profiles.contains(where: { $0.id == current && $0.configuration.enabled }) {
            return current
        }
        return defaultProviderID
    }

    var activeConfiguration: ModelProviderConfiguration {
        profiles.first { $0.id == defaultProviderID && $0.configuration.enabled }?.configuration ?? ModelProviderConfiguration()
    }

    func profile(for optionID: String?) -> ModelProviderProfile? {
        guard let optionID else { return nil }
        return profiles.first { profile in profile.options.contains { $0.id == optionID } }
    }

    func validated() throws -> Self {
        var result = self
        result.profiles = try profiles.map { try $0.validated() }
        if let models = additionalOpenAIModels {
            result.additionalOpenAIModels = try models.map { try $0.validated() }
            guard Set(result.additionalOpenAIModels!.map(\.modelID)).count == models.count else {
                throw ModelProviderError.message("OpenAI：补充模型 ID 不能重复。")
            }
        }
        guard defaultProviderID == Self.openAI || result.profiles.contains(where: {
            $0.id == defaultProviderID && $0.configuration.enabled
        }) else { throw ModelProviderError.message("请启用默认使用的厂商，或选择 OpenAI。") }
        return result
    }

    func composerOptions(openAI: [CodexModelOption]) -> [CodexModelOption] {
        let known = Set(openAI.map(\.model))
        let extra = (additionalOpenAIModels ?? []).filter { !known.contains($0.modelID) }.compactMap(\.option)
        return openAI + extra + profiles.flatMap(\.options)
    }
}
