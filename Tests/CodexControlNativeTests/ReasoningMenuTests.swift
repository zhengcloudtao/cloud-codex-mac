import XCTest
@testable import CloudCodex

@MainActor
final class ReasoningMenuTests: XCTestCase {
    private func option(_ efforts: [String], defaultEffort: String = "medium") -> CodexModelOption {
        CodexModelOption(json: [
            "id": "test-model", "model": "test-model", "displayName": "Test Model",
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
}
