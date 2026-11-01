import XCTest
@testable import CloudCodex

final class RemoteModelSettingsTests: XCTestCase {
    @MainActor func testVerifiedModelOnlyUpdatesItsOwnTurn() {
        let model = AppModel()
        model.selectedThreadID = "thread"
        model.messages = [
            ChatMessage(id: "old", role: .user, text: "same prompt", turnID: "old-turn", model: "gpt-5.6-sol", reasoningEffort: "low"),
            ChatMessage(id: "new", role: .user, text: "same prompt", turnID: "new-turn", model: "gpt-5.6-sol", reasoningEffort: "low")
        ]
        let update = RemoteTaskStatusBody(status: "running", threadId: "thread", turnId: "new-turn", result: "", error: "",
                                         actualModel: "gpt-6-astra", actualEffort: "xhigh")
        model.applyVerifiedRemoteSettings(update)
        XCTAssertEqual(model.messages[0].model, "gpt-5.6-sol")
        XCTAssertEqual(model.messages[0].reasoningEffort, "low")
        XCTAssertEqual(model.messages[1].model, "gpt-6-astra")
        XCTAssertEqual(model.messages[1].reasoningEffort, "xhigh")
    }

    @MainActor func testExternalTurnDoesNotBorrowVisibleComposerModel() {
        let model = AppModel()
        model.selectedThreadID = "thread"
        model.selectedEffort = "low"
        model.handleEvent("turn/started", ["threadId": "thread", "turn": ["id": "external-turn"]])
        model.handleEvent("item/completed", ["threadId": "thread", "turnId": "external-turn",
            "item": ["type": "agentMessage", "id": "answer", "text": "answer"]])
        XCTAssertNil(model.messages.first { $0.id == "answer" }?.model)
        XCTAssertNil(model.messages.first { $0.id == "answer" }?.reasoningEffort)
    }

    func testActualSettingsAreOptionalAndNeverInferred() throws {
        let old = Data(#"{"status":"running","threadId":"thread","turnId":"turn","result":"","error":""}"#.utf8)
        let body = try JSONDecoder().decode(RemoteTaskStatusBody.self, from: old)
        XCTAssertNil(body.actualModel)
        XCTAssertNil(body.withActualSettings(nil).actualEffort)
        let actual = body.withActualSettings(TurnModelMetadata(model: "gpt-6-astra", reasoningEffort: "xhigh"))
        XCTAssertEqual(actual.actualModel, "gpt-6-astra")
        XCTAssertEqual(actual.actualEffort, "xhigh")
        XCTAssertEqual(try JSONDecoder().decode(RemoteTaskStatusBody.self, from: JSONEncoder().encode(actual)), actual)
        let queued = RemoteTaskStatusBody(status: "queued", threadId: "thread", turnId: "", result: "", error: "")
        XCTAssertNil(queued.withActualSettings(TurnModelMetadata(model: "wrong", reasoningEffort: "low")).actualModel)
    }

    @MainActor func testHeartbeatPublishesDefaultsAndFrozenRequestIgnoresLaterSelection() throws {
        let model = AppModel()
        model.modelOptions = ["gpt-6-astra", "gpt-5.6-sol"].compactMap { id in
            let displayName = id == "gpt-6-astra" ? "GPT-6-Astra" : "GPT-5.6-Sol"
            return CodexModelOption(json: ["id": id, "model": id, "displayName": displayName, "defaultReasoningEffort": "low",
                "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "xhigh"]]])
        }
        model.selectModel("gpt-6-astra", preferredEffort: "xhigh")
        let snapshot = model.makeRemoteHeartbeat(ready: true)
        XCTAssertEqual(snapshot.defaultModel, "gpt-6-astra")
        XCTAssertEqual(snapshot.defaultEffort, "xhigh")
        XCTAssertEqual(snapshot.defaultSpeed, model.isFastModeEnabled ? "fast" : "standard")
        let encoded = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(RemoteHeartbeatBody.self, from: encoded).defaultSpeed, snapshot.defaultSpeed)
        XCTAssertEqual(snapshot.models.map(\.model), ["gpt-6-astra", "gpt-5.6-sol"])
        XCTAssertEqual(snapshot.models.first?.name, "GPT-6 Astra")
        XCTAssertEqual(snapshot.models.first?.supportedEfforts, ["low", "xhigh"])
        model.selectModel("gpt-5.6-sol", preferredEffort: "low")
        let params = AppServerClient.turnStartParameters(threadID: "thread", text: "test", attachments: [],
            model: snapshot.defaultModel, effort: snapshot.defaultEffort, permissions: nil, serviceTier: nil)
        XCTAssertEqual(params["model"] as? String, "gpt-6-astra")
        XCTAssertEqual(params["effort"] as? String, "xhigh")
    }
}
