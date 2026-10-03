import SwiftUI

struct ModelProviderSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var library = ModelProviderLibrary.load()
    @State private var keys: [String: String] = [:]
    @State private var message: String?
    @State private var connectionTestResult: String?
    @State private var working = false

    init(library: ModelProviderLibrary? = nil) {
        _library = State(initialValue: library ?? ModelProviderLibrary.load())
    }

    var body: some View {
        GroupBox("模型服务商") {
            VStack(alignment: .leading, spacing: 12) {
                Text("启用的厂商会出现在对话模型菜单中。启动默认仅决定下次启动使用哪个厂商；对话中的模型选择目前全局生效。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("启动默认服务商", selection: $library.defaultProviderID) {
                    Text("OpenAI（本机 Codex）").tag(ModelProviderLibrary.openAI)
                    ForEach(library.profiles) { profile in
                        Text(profile.configuration.name).tag(profile.id)
                    }
                }
                .onChange(of: library.defaultProviderID) { _, id in
                    if let index = library.profiles.firstIndex(where: { $0.id == id }) {
                        library.profiles[index].configuration.enabled = true
                    }
                }
                openAISettings
                ForEach(library.profiles.indices, id: \.self) { index in provider(index) }
                HStack {
                    Button("保存配置") { Task { await save() } }
                    if working { ProgressView().controlSize(.small) }
                }
                Text("密钥按厂商和接入方式保存在本机钥匙串，留空可保留已有密钥。切换厂商会影响所有对话的后续请求，并将继续会话所需的上下文发送给所选厂商。运行中及排队任务结束后才能跨厂商切换；保存不会仅因修改启动默认而切换当前厂商。")
                    .font(.caption).foregroundStyle(.secondary)
                if let message { Text(message).font(.caption).textSelection(.enabled) }
            }
            .disabled(working).textFieldStyle(.roundedBorder).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("连接测试结果", isPresented: Binding(
            get: { connectionTestResult != nil },
            set: { if !$0 { connectionTestResult = nil } }
        )) {
            Button("确定", role: .cancel) { connectionTestResult = nil }
        } message: {
            Text(connectionTestResult ?? "")
        }
    }

    private var openAISettings: some View {
        GroupBox("OpenAI") {
            VStack(alignment: .leading, spacing: 10) {
                Text("使用本机 Codex 登录与配置，始终可选。当前厂商与模型请在对话菜单中选择。").font(.caption).foregroundStyle(.secondary)
                Picker("默认模型", selection: $library.openAIDefaultModelID) {
                    Text("沿用本机 Codex 默认模型").tag(Optional<String>.none)
                    ForEach(library.composerOptions(openAI: model.modelOptions.filter {
                        model.providerID(for: $0.id) == ModelProviderLibrary.openAI
                    }).filter { model.providerID(for: $0.id) == ModelProviderLibrary.openAI }) { option in
                        Text(option.pickerName).tag(Optional(option.model))
                    }
                }
                Text("模型目录自动从本机 Codex 读取。可补充目录外的模型；支持的推理档位由你根据该模型填写，用英文逗号分隔。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array((library.additionalOpenAIModels ?? []).indices), id: \.self) { index in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("补充模型 ID", text: openAIField(index, \.modelID))
                            Button {
                                if library.additionalOpenAIModels?[index].modelID == library.openAIDefaultModelID {
                                    library.openAIDefaultModelID = nil
                                }
                                library.additionalOpenAIModels?.remove(at: index)
                            } label: { Image(systemName: "minus.circle") }.help("移除此补充模型")
                        }
                        TextField("显示名称（可选）", text: Binding(
                            get: { library.additionalOpenAIModels?[index].displayName ?? "" },
                            set: { value in
                                if library.additionalOpenAIModels?.indices.contains(index) == true {
                                    library.additionalOpenAIModels?[index].displayName = value
                                }
                            }))
                        HStack {
                            TextField("支持档位，例如 low,medium,high", text: openAIField(index, \.effortsText))
                            TextField("默认档位", text: openAIField(index, \.defaultEffort)).frame(width: 100)
                        }
                    }
                }
                Button("添加 OpenAI 模型") {
                    if library.additionalOpenAIModels == nil { library.additionalOpenAIModels = [] }
                    library.additionalOpenAIModels?.append(AdditionalOpenAIModel())
                }
            }.padding(6)
        }
    }

    private func openAIField(_ index: Int, _ field: WritableKeyPath<AdditionalOpenAIModel, String>) -> Binding<String> {
        Binding(get: {
            guard let models = library.additionalOpenAIModels, models.indices.contains(index) else { return "" }
            return models[index][keyPath: field]
        }, set: { value in
            guard library.additionalOpenAIModels?.indices.contains(index) == true else { return }
            library.additionalOpenAIModels?[index][keyPath: field] = value
        })
    }

    private func provider(_ index: Int) -> some View {
        let profile = library.profiles[index]
        return GroupBox(profile.configuration.name) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("在对话模型菜单中启用", isOn: $library.profiles[index].configuration.enabled)
                    .onChange(of: library.profiles[index].configuration.enabled) { _, enabled in
                        if !enabled && library.defaultProviderID == profile.id {
                            library.defaultProviderID = ModelProviderLibrary.openAI
                        }
                    }
                if let service = profile.configuration.service, service != .deepseek {
                    Picker("接入方式", selection: Binding(
                        get: { library.profiles[index].configuration.usesSubscription },
                        set: { subscription in
                            let oldModel = library.profiles[index].configuration.modelID
                            let wasPreset = library.profiles[index].modelIDs == [oldModel]
                            let enabled = library.profiles[index].configuration.enabled
                            library.profiles[index].configuration.select(service, subscription: subscription)
                            library.profiles[index].configuration.enabled = enabled
                            if wasPreset {
                                let newModel = library.profiles[index].configuration.modelID
                                library.profiles[index].modelIDs = newModel.isEmpty ? [] : [newModel]
                                library.profiles[index].modelDetails = nil
                            }
                            keys[profile.id] = ""
                        }
                    )) {
                        Text(service.subscriptionTitle()).tag(true)
                        Text("按量计费").tag(false)
                    }
                }
                TextField("Base URL", text: $library.profiles[index].configuration.baseURL)
                SecureField("API Key（留空保留此接入方式的密钥）", text: Binding(
                    get: { keys[profile.id] ?? "" }, set: { keys[profile.id] = $0 }))
                HStack {
                    Text("模型列表").font(.subheadline.bold())
                    Spacer()
                    Button("添加模型") { library.profiles[index].modelIDs.append("") }
                }
                Text("名称方便辨认；模型 ID 用于实际请求。推理档位按模型分别配置，需符合该模型的官方说明。")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(library.profiles[index].modelIDs.indices, id: \.self) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("模型 ID / 接入点 ID", text: modelIDBinding(index, row))
                            Button {
                                library.profiles[index].configuration.modelID = library.profiles[index].modelIDs[row]
                            } label: {
                                Image(systemName: profile.configuration.modelID == profile.modelIDs[row]
                                      ? "checkmark.circle.fill" : "circle")
                            }.help("设为该厂商默认模型")
                            Button {
                                let id = library.profiles[index].modelIDs.remove(at: row)
                                library.profiles[index].modelDetails?.removeValue(forKey: id)
                            } label: { Image(systemName: "minus.circle") }.help("移除此模型")
                        }
                        TextField("显示名称（可选，例如日常编程）", text: detailBinding(index, row, \.displayName))
                        HStack {
                            TextField("支持档位，例如 low,high,max", text: detailBinding(index, row, \.effortsText))
                            Picker("默认档位", selection: detailBinding(index, row, \.defaultEffort)) {
                                ForEach(profile.details(for: profile.modelIDs[row]).efforts, id: \.self) {
                                    Text($0).tag($0)
                                }
                            }.frame(width: 150)
                        }
                    }.padding(8).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                }
                HStack {
                    Button("测试连接") { Task { await probe(index) } }
                    if let service = profile.configuration.service {
                        Link("官方接入说明", destination: service.documentationURL)
                    }
                }
                if profile.configuration.service == .aliyun {
                    Text("Token Plan 与按量计费使用不同密钥；按量地址需填真实 Workspace ID。仅支持 Chat Completions 的 Coding Plan 暂不支持。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if profile.configuration.service == .volcengine {
                    Text("Coding Plan 使用套餐专属密钥；按量模式需填写已开通的模型或接入点 ID，并按量计费。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(6)
        }
    }

    private func modelIDBinding(_ index: Int, _ row: Int) -> Binding<String> {
        Binding(get: {
            guard library.profiles[index].modelIDs.indices.contains(row) else { return "" }
            return library.profiles[index].modelIDs[row]
        }, set: { value in
            guard library.profiles[index].modelIDs.indices.contains(row) else { return }
            let old = library.profiles[index].modelIDs[row]
            if let detail = library.profiles[index].modelDetails?.removeValue(forKey: old) {
                library.profiles[index].modelDetails?[value] = detail
            }
            library.profiles[index].modelIDs[row] = value
            if library.profiles[index].configuration.modelID == old {
                library.profiles[index].configuration.modelID = value
            }
        })
    }

    private func detailBinding(_ index: Int, _ row: Int,
                               _ field: WritableKeyPath<ProviderModelDetails, String>) -> Binding<String> {
        Binding(get: {
            guard library.profiles[index].modelIDs.indices.contains(row) else { return "" }
            return library.profiles[index].details(for: library.profiles[index].modelIDs[row])[keyPath: field]
        }, set: { value in
            guard library.profiles[index].modelIDs.indices.contains(row) else { return }
            let id = library.profiles[index].modelIDs[row]
            var detail = library.profiles[index].details(for: id)
            detail[keyPath: field] = value
            if field == \.effortsText && !detail.efforts.contains(detail.defaultEffort) {
                detail.defaultEffort = detail.efforts.first ?? ""
            }
            if library.profiles[index].modelDetails == nil { library.profiles[index].modelDetails = [:] }
            library.profiles[index].modelDetails?[id] = detail
        })
    }

    private func key(for profile: ModelProviderProfile) async throws -> String {
        let entered = (keys[profile.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !entered.isEmpty { return entered }
        guard let saved = try await ModelProviderKeychain.load(account: profile.configuration.credentialAccount), !saved.isEmpty else {
            throw ModelProviderError.message("\(profile.configuration.name)：请填写 API Key。")
        }
        return saved
    }

    private func save() async {
        working = true
        defer { working = false }
        do {
            guard model.canChangeProviderConfiguration else {
                throw ModelProviderError.message("请等待运行中及排队的任务结束，再保存厂商配置。")
            }
            let value = try library.validated()
            var credentials: [(ModelProviderProfile, String)] = []
            for profile in value.profiles where profile.configuration.enabled || !(keys[profile.id] ?? "").isEmpty {
                credentials.append((profile, try await key(for: profile)))
            }
            for (profile, key) in credentials {
                try await ModelProviderKeychain.save(key, account: profile.configuration.credentialAccount)
            }
            try await model.applyProviderLibrary(value)
            library = value; keys = [:]
            message = "已保存配置。启动默认下次启动生效；当前厂商保留（被停用时切换到默认厂商）。模型可在对话菜单中选择。"
        } catch { message = error.localizedDescription }
    }

    private func probe(_ index: Int) async {
        working = true
        defer { working = false }
        let selected = library.profiles[index]
        let target = "厂商：\(selected.configuration.name)\n模型：\(selected.configuration.modelID)"
        do {
            var profile = selected
            profile.configuration.enabled = true
            profile = try profile.validated()
            let target = "厂商：\(profile.configuration.name)\n模型：\(profile.configuration.modelID)"
            let result = try await ModelProviderConnectionProbe.check(profile.configuration, key: key(for: profile))
            connectionTestResult = "\(target)\n\n\(result)"
        } catch {
            connectionTestResult = "\(target)\n\n测试未完成：\(error.localizedDescription)"
        }
    }
}
