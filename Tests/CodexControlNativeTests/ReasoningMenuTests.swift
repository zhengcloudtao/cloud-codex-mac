import XCTest
@testable import CloudCodex

@MainActor
final class ReasoningMenuTests: XCTestCase {
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

    func testGodConversationSelectsAstraAndUltraRegardlessOfCatalogPosition() throws {
        let sol = option(["low", "medium", "xhigh"], id: "gpt-6-sol", displayName: "GPT-6-Sol")
        let astra = option(["low", "medium", "xhigh", "ultra"], id: "gpt-6-astra", displayName: "GPT-6-Astra")

        let preset = try XCTUnwrap(ModelSelectionPreset.godConversation(in: [sol, astra]))

        XCTAssertEqual(preset, ModelSelectionPreset(modelID: "gpt-6-astra", effort: "ultra"))
    }

    func testGodConversationFallsBackToFirstUsableModelAndHighestVisibleEffort() throws {
        let unavailable = option(["max"], defaultEffort: "max", id: "hidden-only")
        let firstUsable = option(["low", "persistent", "high", "xhigh"], id: "future-flagship")
        let later = option(["low", "ultra"], id: "later-model")

        let preset = try XCTUnwrap(ModelSelectionPreset.godConversation(in: [unavailable, firstUsable, later]))

        XCTAssertEqual(preset, ModelSelectionPreset(modelID: "future-flagship", effort: "xhigh"))
        XCTAssertNil(ModelSelectionPreset.godConversation(in: [unavailable]))
    }
}
