import XCTest
@testable import CloudCodex

@MainActor
final class ReasoningMenuTests: XCTestCase {
    func testUnsupportedModelUsesStandardWithoutErasingSavedAcceleration() throws {
        let suite = "CloudCodex.FastCapabilitiesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "CloudCodex.fastModeEnabled.v1")
        let model = AppModel(remoteDefaults: defaults)
        let standard = option(["medium"])
        let fast = try XCTUnwrap(CodexModelOption(json: [
            "id": "fast-model", "model": "fast-model", "displayName": "Fast Model",
            "defaultReasoningEffort": "medium",
            "supportedReasoningEfforts": [["reasoningEffort": "medium"]],
            "serviceTiers": [["id": "fast", "name": "Fast"]]
        ]))
        model.modelOptions = [standard, fast]
        model.selectModel(standard.id)
        XCTAssertTrue(model.isFastModeEnabled)
        XCTAssertEqual(model.selectedSpeedLabel, "标准")
        XCTAssertEqual(model.selectedServiceTier, "default")
        model.selectModel(fast.id)
        XCTAssertEqual(model.selectedSpeedLabel, "加速")
        XCTAssertEqual(model.selectedServiceTier, "fast")
    }

    func testUnchangedFastModeDoesNotNeedServerSync() {
        XCTAssertFalse(AppModel.fastModeNeedsSync(current: false, requested: false))
        XCTAssertFalse(AppModel.fastModeNeedsSync(current: true, requested: true))
        XCTAssertTrue(AppModel.fastModeNeedsSync(current: false, requested: true))
        XCTAssertTrue(AppModel.fastModeNeedsSync(current: true, requested: false))
    }

    func testUnsupportedLiveTurnSettingsErrorIsSilentButOtherFailuresRemainVisible() {
        XCTAssertTrue(AppModel.shouldSuppressTurnSettingsError(
            "turn settings updates require the step_model_switching feature"
        ))
        XCTAssertTrue(AppModel.shouldSuppressTurnSettingsError(
            "Turn settings updates require a supported capability"
        ))
        XCTAssertFalse(AppModel.shouldSuppressTurnSettingsError("connection lost"))
    }

    private func option(
        _ efforts: [String],
        defaultEffort: String = "medium",
        id: String = "test-model",
        displayName: String = "Test Model"
    ) -> CodexModelOption {
        CodexModelOption(json: [
            "id": id, "model": id, "displayName": displayName,
            "defaultReasoningEffort": defaultEffort,
            "supportedReasoningEfforts": efforts.map { ["reasoningEffort": $0] }
        ])!
    }

    func testActualComposerMenuHidesMaxWithoutRemovingAPISupport() {
        let model = AppModel()
        let item = option(["low", "medium", "high", "xhigh", "max", "ultra"])
        model.modelOptions = [item]
        model.selectModel(item.id)
        XCTAssertEqual(model.availableEfforts.map(ReasoningEffortLabel.name), ["轻度", "中", "高", "极高", "Ultra"])
        XCTAssertFalse(model.availableEfforts.contains("max"))
        XCTAssertTrue(item.supportedEfforts.contains("max"))
    }

    func testMenuDoesNotInventUltraForModelsWithoutSupport() {
        let item = option(["low", "medium", "high", "xhigh", "max"])
        XCTAssertEqual(item.composerEfforts, ["low", "medium", "high", "xhigh"])
    }

    func testHiddenDefaultOrPriorSelectionCannotLeakIntoComposer() {
        let model = AppModel()
        let item = option(["low", "medium", "high", "xhigh", "max", "ultra"], defaultEffort: "max")
        model.modelOptions = [item]
        model.selectedEffort = "max"
        model.selectModel(item.id, preferredEffort: "max")
        XCTAssertEqual(model.selectedEffort, "medium")
        XCTAssertNotEqual(model.selectedEffort, "ultra")
    }

    func testXHighAndUltraKeepTheirDistinctRawValues() {
        let model = AppModel()
        let item = option(["low", "medium", "high", "xhigh", "max", "ultra"])
        model.modelOptions = [item]
        model.selectModel(item.id, preferredEffort: "xhigh")
        XCTAssertEqual(model.selectedEffort, "xhigh")
        model.selectModel(item.id, preferredEffort: "ultra")
        XCTAssertEqual(model.selectedEffort, "ultra")
    }

    func testHistoricalMaxMetadataIsNotRelabeledAsUltra() {
        let metadata = TurnModelMetadata(model: "test-model", reasoningEffort: "max")
        XCTAssertEqual(metadata.reasoningEffort, "max")
        XCTAssertEqual(metadata.displayLabel, "test-model · 最高")
    }

    func testFallbackIsAlwaysVisibleOrNil() {
        XCTAssertEqual(option(["high", "xhigh", "max"], defaultEffort: "max").defaultComposerEffort, "high")
        XCTAssertNil(option(["max"], defaultEffort: "max").defaultComposerEffort)
        XCTAssertEqual(option(["none", "minimal", "medium", "persistent"]).composerEfforts, ["medium", "persistent"])
    }

    func testRecommendedSelectionUsesCatalogDefaultCapabilitiesWithoutPinningModel() {
        let model = AppModel()
        let recommended = CodexModelOption(json: [
            "id": "gpt-6-astra", "model": "gpt-6-astra", "displayName": "GPT-6-Astra",
            "isDefault": true, "defaultReasoningEffort": "medium",
            "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "medium"]]
        ])!
        model.modelOptions = [recommended]

        model.selectModel(AppModel.recommendedModelSelectionID)

        XCTAssertNil(model.selectedModel)
        XCTAssertEqual(model.selectedModelCapabilities?.id, "gpt-6-astra")
        XCTAssertEqual(model.selectedModelDisplayName, "默认")
        XCTAssertEqual(model.selectedEffort, "medium")
        XCTAssertEqual(recommended.pickerName, "GPT-6 Astra")
    }

    func testGPT61SolCatalogEntryCanBeSelectedWithItsCapabilities() throws {
        let sol = try XCTUnwrap(CodexModelOption(json: [
            "id": "gpt-6.1-sol", "model": "gpt-6.1-sol", "displayName": "GPT-6.1-Sol",
            "isDefault": true, "defaultReasoningEffort": "low",
            "supportedReasoningEfforts": ["low", "medium", "high", "xhigh", "max", "ultra"].map {
                ["reasoningEffort": $0]
            },
            "serviceTiers": [["id": "priority", "name": "Fast", "description": "2x speed, increased usage"]]
        ]))
        let model = AppModel()
        model.modelOptions = [sol]
        model.selectModel(sol.id, preferredEffort: "ultra")

        XCTAssertEqual(sol.pickerName, "GPT-6.1 Sol")
        XCTAssertEqual(model.selectedModel?.model, "gpt-6.1-sol")
        XCTAssertEqual(model.selectedEffort, "ultra")
        XCTAssertEqual(sol.fastServiceTierID, "priority")
        XCTAssertEqual(model.recommendedModel?.id, sol.id)
    }
}
