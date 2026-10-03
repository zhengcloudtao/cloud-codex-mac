import XCTest
import SwiftUI
import AppKit
@testable import CloudCodex

final class ModelProviderLibraryTests: XCTestCase {
    func testSavingStartupDefaultPreservesCurrentRouteUnlessDisabled() {
        var library = ModelProviderLibrary()
        library.profiles[0].configuration.enabled = true
        library.defaultProviderID = "deepseek"
        XCTAssertEqual(library.providerIDAfterSaving(current: "openai"), "openai")
        library.defaultProviderID = "openai"
        XCTAssertEqual(library.providerIDAfterSaving(current: "deepseek"), "deepseek")
        library.profiles[0].configuration.enabled = false
        XCTAssertEqual(library.providerIDAfterSaving(current: "deepseek"), "openai")
    }

    func testPerModelNamesEffortsMigrationAndRuntimeCatalog() throws {
        var profile = ModelProviderProfile(service: .deepseek)
        profile.configuration.enabled = true
        profile.modelIDs = ["first", "second"]
        profile.configuration.modelID = "first"
        // A previously saved v2 profile has no optional metadata and retains provider defaults.
        let oldData = try JSONEncoder().encode(profile)
        let old = try JSONDecoder().decode(ModelProviderProfile.self, from: oldData)
        XCTAssertEqual(old.options[0].supportedEfforts, ["low", "high", "max"])
        profile.modelDetails = [
            "first": ProviderModelDetails(displayName: "日常编程", effortsText: "none, low", defaultEffort: "none"),
            "second": ProviderModelDetails(displayName: "复杂任务", effortsText: "high,max", defaultEffort: "max")
        ]
        let saved = try profile.validated()
        XCTAssertEqual(saved.configuration.reasoningEffort, "none")
        XCTAssertEqual(saved.options[0].pickerName, "DeepSeek · 日常编程")
        XCTAssertEqual(saved.options[0].composerEfforts, ["none", "low"])
        XCTAssertEqual(saved.options[1].defaultComposerEffort, "max")
        XCTAssertEqual(try JSONDecoder().decode(ModelProviderProfile.self, from: JSONEncoder().encode(saved)), saved)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let arguments = try saved.configuration.launchArguments(catalogDirectory: directory,
            models: saved.modelIDs, options: saved.options)
        XCTAssertTrue(arguments.contains { $0.hasPrefix("model_catalog_json=") })
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let models = try XCTUnwrap(catalog["models"] as? [[String: Any]])
        XCTAssertEqual(models[0]["default_reasoning_level"] as? String, "none")
        XCTAssertEqual((models[1]["supported_reasoning_levels"] as? [[String: String]])?.map { $0["effort"]! }, ["high", "max"])
        var removedDefault = saved
        removedDefault.modelIDs = ["third"]
        let fallback = try removedDefault.validated()
        XCTAssertEqual(fallback.configuration.modelID, "third")
        XCTAssertEqual(fallback.configuration.reasoningEffort, "high")
        XCTAssertNil(fallback.configuration.supportedReasoningEfforts)
        profile.modelDetails?["second"]?.defaultEffort = "low"
        XCTAssertThrowsError(try profile.validated())
        profile.modelDetails?["second"]?.defaultEffort = "max"
        profile.modelDetails?["second"]?.effortsText = "high,high"
        XCTAssertThrowsError(try profile.validated())
    }

    @MainActor
    func testConfiguredOpenAIDefaultIsAnExplicitOutgoingModel() throws {
        let suite = "OpenAIDefault-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var library = ModelProviderLibrary()
        var entry = AdditionalOpenAIModel(); entry.modelID = "manual-model"
        library.additionalOpenAIModels = [entry]; library.openAIDefaultModelID = entry.modelID
        defaults.set(try JSONEncoder().encode(library), forKey: ModelProviderLibrary.defaultsKey)
        let model = AppModel(remoteDefaults: defaults)
        model.modelOptions = library.composerOptions(openAI: [])
        model.selectModel(AppModel.recommendedModelSelectionID)
        XCTAssertEqual(model.selectedModel?.model, "manual-model")
        XCTAssertEqual(model.selectedEffort, "medium")
        XCTAssertFalse(model.customModelProvider.enabled)
    }
    func testAdditionalOpenAIModelsAreValidatedAndDoNotDuplicateLiveCatalog() throws {
        var library = ModelProviderLibrary()
        var entry = AdditionalOpenAIModel()
        entry.modelID = "manual-model"; entry.effortsText = "low, high, max"; entry.defaultEffort = "high"
        library.additionalOpenAIModels = [entry]
        let saved = try library.validated()
        let options = saved.composerOptions(openAI: [])
        XCTAssertEqual(options.first?.model, "manual-model")
        XCTAssertEqual(options.first?.composerEfforts, ["low", "high", "max"])
        XCTAssertEqual(saved.composerOptions(openAI: options).count, 1)
        entry.effortsText = "invalid"; library.additionalOpenAIModels = [entry]
        XCTAssertThrowsError(try library.validated())
    }

    @MainActor
    func testSettingsWithMultipleModelsRenderWithinPreferencePanelWidth() throws {
        let suite = "ProviderSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var library = ModelProviderLibrary()
        for index in library.profiles.indices {
            library.profiles[index].configuration.enabled = true
            library.profiles[index].modelIDs.append("second-model")
        }
        library.defaultProviderID = "deepseek"
        let model = AppModel(remoteDefaults: defaults)
        let view = NSHostingView(rootView: ModelProviderSettings(library: library).environmentObject(model)
            .preferredColorScheme(.light).padding(12))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 592, height: 2200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.contentView = nil; window.close() }
        view.frame = NSRect(x: 0, y: 0, width: 592, height: 2200)
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        view.layoutSubtreeIfNeeded()
        func descendants(_ parent: NSView) -> [NSView] { parent.subviews.flatMap { [$0] + descendants($0) } }
        let fields = descendants(view).compactMap { $0 as? NSTextField }
        XCTAssertEqual(fields.filter { $0 is NSSecureTextField }.count, 3)
        for field in fields where field.isEditable {
            let rect = field.convert(field.bounds, to: view)
            XCTAssertGreaterThanOrEqual(rect.minX, 0)
            XCTAssertLessThanOrEqual(rect.maxX, view.bounds.maxX)
        }
        if let destination = ProcessInfo.processInfo.environment["CLOUDCODEX_SETTINGS_PREVIEW"] {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: destination))
        }
    }
    func testLegacyMigrationKeepsEndpointModelsAndKeychainIdentity() throws {
        let suite = "ProviderLibrary-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var old = ModelProviderConfiguration(enabled: true)
        old.select(.deepseek); old.modelID = "deepseek-v4-pro"
        defaults.set(try JSONEncoder().encode(old), forKey: ModelProviderConfiguration.defaultsKey)
        let migrated = ModelProviderLibrary.load(from: defaults)
        XCTAssertEqual(migrated.defaultProviderID, "deepseek")
        XCTAssertEqual(migrated.activeConfiguration, old)
        XCTAssertEqual(migrated.activeConfiguration.credentialAccount, old.credentialAccount)
        XCTAssertEqual(migrated.profiles.first?.modelIDs, ["deepseek-v4-pro"])
        XCTAssertEqual(migrated.profiles.count, 3)
        XCTAssertNil(defaults.data(forKey: ModelProviderLibrary.defaultsKey))
    }

    func testProviderProfilesRoundTripAndModelIDsDoNotCollide() throws {
        var library = ModelProviderLibrary()
        for index in library.profiles.indices {
            library.profiles[index].configuration.enabled = true
            library.profiles[index].modelIDs = ["shared-model", "second-model"]
        }
        library.defaultProviderID = "deepseek"
        let saved = try library.validated()
        let decoded = try JSONDecoder().decode(ModelProviderLibrary.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded, saved)
        XCTAssertEqual(Set(decoded.profiles.flatMap(\.options).map(\.id)).count, 6)
        let option = try XCTUnwrap(decoded.profiles[0].options.first)
        XCTAssertEqual(option.model, "shared-model")
        XCTAssertEqual(option.composerEfforts, ["low", "high", "max"])
        XCTAssertEqual(decoded.profile(for: option.id)?.id, "deepseek")
        library.defaultProviderID = ModelProviderLibrary.openAI
        XCTAssertFalse(try library.validated().activeConfiguration.enabled)
        XCTAssertEqual(library.profiles[0].modelIDs, ["shared-model", "second-model"])
    }

    func testEnabledProfilesRequireDistinctNonEmptyModelsAndValidDefault() {
        var library = ModelProviderLibrary()
        library.profiles[0].configuration.enabled = true
        for models in [[], [""], ["model with spaces"], ["duplicate", "duplicate"]] {
            library.profiles[0].modelIDs = models
            XCTAssertThrowsError(try library.validated())
        }
        library.profiles[0].modelIDs = ["replacement"]
        XCTAssertEqual(try library.validated().profiles[0].configuration.modelID, "replacement")
        library.defaultProviderID = "aliyun"
        XCTAssertThrowsError(try library.validated())
    }

    func testAllModelsAndEffortsAreIncludedInRuntimeCatalog() throws {
        var configuration = ModelProviderConfiguration(enabled: true)
        configuration.select(.deepseek)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let arguments = try configuration.launchArguments(catalogDirectory: directory, models: ["deepseek-flash", "deepseek-v4-pro"])
        let assignment = try XCTUnwrap(arguments.last)
        let path = try JSONDecoder().decode(String.self, from: Data(assignment.dropFirst("model_catalog_json=".count).utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let entries = try XCTUnwrap(object["models"] as? [[String: Any]])
        XCTAssertEqual(entries.compactMap { $0["slug"] as? String }, ["deepseek-flash", "deepseek-v4-pro"])
        for entry in entries {
            XCTAssertEqual((entry["supported_reasoning_levels"] as? [[String: String]])?.compactMap { $0["effort"] }, ["low", "high", "max"])
        }
    }

    @MainActor
    func testChangingComposerModelChangesEffectiveRouteWithoutErasingOtherProfiles() throws {
        let suite = "ProviderComposer-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var library = ModelProviderLibrary()
        library.profiles[0].configuration.enabled = true
        library.profiles[0].modelIDs.append("deepseek-v4-pro")
        library.defaultProviderID = "deepseek"
        defaults.set(try JSONEncoder().encode(library), forKey: ModelProviderLibrary.defaultsKey)
        let model = AppModel(remoteDefaults: defaults)
        model.modelOptions = library.profiles.flatMap(\.options)
        model.selectModel(ModelProviderProfile.optionID(provider: "deepseek", model: "deepseek-v4-pro"), preferredEffort: "max")
        XCTAssertEqual(model.customModelProvider.modelID, "deepseek-v4-pro")
        XCTAssertEqual(model.customModelProvider.reasoningEffort, "max")
        XCTAssertEqual(model.providerLibrary, library)
        model.handleEvent("turn/started", ["threadId": "running", "turn": ["id": "turn"]])
        XCTAssertFalse(model.canChangeProviderConfiguration)
        XCTAssertTrue(model.canApplyModelSelection(model.selectedModelID))
        XCTAssertFalse(model.canApplyModelSelection("gpt-fixture"))
    }

    @MainActor
    func testRealAppServerModelEffortAndProviderRestartUseSelectedRouteAndFreshKey() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/provider-responses.py")
        func server(_ label: String, key: String) throws -> (Process, Int, URL) {
            let process = Process(); let pipe = Pipe(); let log = root.appendingPathComponent(label + ".jsonl")
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [fixture.path, log.path, key]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run()
            var data = Data()
            while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
                if byte == Data([10]) { break }; data.append(byte)
            }
            guard let port = Int(String(decoding: data, as: UTF8.self)) else { throw CodexClientError.invalidResponse }
            return (process, port, log)
        }
        let first = try server("first", key: "fixture-first")
        defer { first.0.terminate() }
        let second = try server("second", key: "fixture-second")
        defer { second.0.terminate() }
        let client = AppServerClient(codexHomeOverride: root.appendingPathComponent("codex-home"))
        var fixtureKey: String? = "fixture-first"
        client.providerKeyLoader = { _ in fixtureKey }
        func configuration(_ port: Int) -> ModelProviderConfiguration {
            ModelProviderConfiguration(enabled: true, name: "Loopback fixture", baseURL: "http://127.0.0.1:\(port)/v1", modelID: "first-model", reasoningEffort: "low")
        }
        var completions = 0
        client.onEvent = { method, _ in if method == "turn/completed" { completions += 1 } }
        try await client.changeProvider(configuration(first.1), options: [])
        let thread = try await client.createThread(cwd: root.path, model: "second-model", permissions: nil)
        let firstTurn = try await client.startTurn(threadID: thread.id, text: "fixture", attachments: [], model: "second-model", effort: "high", permissions: nil, serviceTier: nil)
        client.customModelProvider.modelID = "future-model"
        for _ in 0..<250 where completions < 1 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(client.usageProvider(threadID: thread.id, turnID: firstTurn)?.modelID, "second-model")
        fixtureKey = nil
        do {
            try await client.changeProvider(configuration(second.1), options: [])
            XCTFail("Missing credential must fail before stopping the current route")
        } catch {
            XCTAssertTrue(client.connected)
            XCTAssertEqual(client.customModelProvider.baseURL, configuration(first.1).baseURL)
        }
        fixtureKey = "fixture-second"
        try await client.changeProvider(configuration(second.1), options: [])
        try await client.resumeThread(thread.id)
        _ = try await client.startTurn(threadID: thread.id, text: "fixture", attachments: [], model: "third-model", effort: "low", permissions: nil, serviceTier: nil)
        for _ in 0..<250 where completions < 2 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(completions, 2)
        func row(_ file: URL) throws -> [String: Any] {
            let line = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").last!
            return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
        XCTAssertEqual(try row(first.2)["model"] as? String, "second-model")
        XCTAssertEqual(try row(first.2)["effort"] as? String, "high")
        XCTAssertEqual(try row(first.2)["authorized"] as? Bool, true)
        XCTAssertEqual(try row(second.2)["model"] as? String, "third-model")
        XCTAssertEqual(try row(second.2)["authorized"] as? Bool, true)
        try await client.changeProvider(ModelProviderConfiguration(), options: [])
        try await client.resumeThread(thread.id)
        XCTAssertFalse(client.customModelProvider.enabled)
    }
}
