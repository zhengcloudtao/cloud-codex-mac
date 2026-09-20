import XCTest
@testable import CloudCodex

final class ComputerUseApprovalRequestTests: XCTestCase {
    private let params: [String: Any] = [
        "threadId": "thread-1", "turnId": "turn-1", "serverName": "cua_repl",
        "mode": "openai/form", "message": "Allow Computer Use to use \"DataPilot\"?",
        "_meta": [
            "connector_id": "computer-use", "persist": ["session", "always"], "tool_name": "getApp",
            "tool_params": ["app": "com.yuntao.DataPilot"],
            "tool_params_display": [["name": "app", "display_name": "App", "value": "DataPilot"]]
        ]
    ]

    func testParsesComputerUseApprovalMetadata() throws {
        let request = try XCTUnwrap(ComputerUseApprovalRequest(requestID: .number(41), params: params))
        XCTAssertEqual(request.threadID, "thread-1")
        XCTAssertEqual(request.applicationName, "DataPilot")
        XCTAssertEqual(request.bundleIdentifier, "com.yuntao.DataPilot")
        XCTAssertEqual(request.toolName, "getApp")
        XCTAssertTrue(request.allowsAlways)
    }

    func testAcceptResponseCarriesPersistenceChoice() throws {
        let request = try XCTUnwrap(ComputerUseApprovalRequest(requestID: .string("approval-1"), params: params))
        XCTAssertEqual(request.responsePayload(for: .allowSession)["action"] as? String, "accept")
        XCTAssertEqual((request.responsePayload(for: .allowSession)["_meta"] as? [String: String])?["persist"], "session")
        XCTAssertEqual((request.responsePayload(for: .allowAlways)["_meta"] as? [String: String])?["persist"], "always")
    }

    func testDeclineAndCancelHaveNoContent() throws {
        let request = try XCTUnwrap(ComputerUseApprovalRequest(requestID: .number(42), params: params))
        XCTAssertEqual(request.responsePayload(for: .decline)["action"] as? String, "decline")
        XCTAssertTrue(request.responsePayload(for: .decline)["content"] is NSNull)
        XCTAssertEqual(request.responsePayload(for: .cancel)["action"] as? String, "cancel")
    }

    func testRejectsUnrelatedElicitation() {
        var unrelated = params
        unrelated["serverName"] = "another-server"
        unrelated["_meta"] = ["connector_id": "another-connector"]
        XCTAssertNil(ComputerUseApprovalRequest(requestID: .number(43), params: unrelated))
    }

    @MainActor
    func testOnlyFullAccessAutomaticallyApprovesComputerUse() {
        XCTAssertTrue(AppModel.automaticallyApprovesComputerUse(permissionID: ":danger-full-access"))
        XCTAssertFalse(AppModel.automaticallyApprovesComputerUse(permissionID: ":workspace"))
        XCTAssertFalse(AppModel.automaticallyApprovesComputerUse(permissionID: ":read-only"))
        XCTAssertFalse(AppModel.automaticallyApprovesComputerUse(permissionID: nil))
    }

    @MainActor
    func testServerRequestAppearsOnlyInMatchingConversation() throws {
        let model = AppModel(remoteDefaults: UserDefaults(suiteName: "computer-use-approval.\(UUID())")!)
        model.selectedThreadID = "thread-1"
        model.handleServerRequest(.number(44), method: "mcpServer/elicitation/request", params: params)
        XCTAssertEqual(model.selectedComputerUseApprovalRequests.map(\.applicationName), ["DataPilot"])
        XCTAssertEqual(model.conversationMessages(for: "thread-1").last?.activityStatus, "待授权")
    }
}
