import AppKit
import SwiftUI
import XCTest
@testable import CloudCodex

/// Exercise the real stdio transport without accounts, network or model usage.
@MainActor
final class MidTurnUserInputTests: XCTestCase {
    func testBlockingQuestionArrivesAndIsAnsweredBeforeTurnCompletes() async throws {
        try await checkQuestionDuringTurn(isBlocking: true)
    }

    func testNonBlockingQuestionRemainsAnswerableWhileWorkContinues() async throws {
        try await checkQuestionDuringTurn(isBlocking: false)
    }

    private func checkQuestionDuringTurn(isBlocking: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudCodexMidTurn-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("codex-fixture")
        let source = #"""
        #!/usr/bin/python3
        import json, pathlib, sys
        root = pathlib.Path(__file__).parent
        (root / "arguments.json").write_text(json.dumps(sys.argv[1:]))
        def emit(value):
            print(json.dumps(value), flush=True)
        for line in sys.stdin:
            request = json.loads(line)
            with (root / "requests.jsonl").open("a") as log:
                log.write(json.dumps(request) + "\n")
            method = request.get("method")
            if method == "initialize":
                emit({"id": request["id"], "result": {"platformOs": "macos"}})
            elif method == "turn/start":
                emit({"id": request["id"], "result": {"turn": {"id": "turn-1"}}})
                emit({"method": "turn/started", "params": {"threadId": "thread-1", "turn": {"id": "turn-1", "status": "inProgress"}}})
                # A numeric server request may reuse the outbound turn/start id.
                if "features.default_mode_request_user_input=true" in sys.argv:
                    blocking = (root / "blocking").read_text() == "true"
                    emit({"id": 2, "method": "item/tool/requestUserInput", "params": {
                        "threadId": "thread-1", "turnId": "turn-1", "itemId": "question-1", "isBlocking": blocking,
                        "questions": [{"id": "scope", "header": "修改范围", "question": "是否同时修改后端？", "isOther": True,
                            "options": [{"label": "同时修改前后端（推荐）", "description": "完成完整功能"},
                                        {"label": "仅修改前端", "description": "先完成界面"}]}]}})
                    if not blocking:
                        emit({"method": "item/completed", "params": {"threadId": "thread-1", "turnId": "turn-1",
                            "item": {"id": "progress-1", "type": "agentMessage", "text": "等待选择期间继续检查。"}}})
            elif method is None and "result" in request:
                emit({"method": "serverRequest/resolved", "params": {"threadId": "thread-1", "requestId": request["id"]}})
                emit({"method": "item/completed", "params": {"threadId": "thread-1", "turnId": "turn-1",
                    "item": {"id": "answer-1", "type": "agentMessage", "text": "已收到选择，继续执行。"}}})
                emit({"method": "turn/completed", "params": {"threadId": "thread-1", "turn": {"id": "turn-1", "status": "completed"}}})
            elif "id" in request:
                emit({"id": request["id"], "result": {"data": []}})
        """#
        try source.write(to: script, atomically: true, encoding: .utf8)
        try (isBlocking ? "true" : "false").write(to: root.appendingPathComponent("blocking"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let client = AppServerClient(codexHomeOverride: root.appendingPathComponent("home"), executableOverride: script)
        defer {
            client.onEvent = nil
            client.onServerRequest = nil
            client.shutdown()
        }
        let defaultsName = "CloudCodexMidTurn-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(remoteDefaults: defaults, client: client)
        model.selectedThreadID = "thread-1"
        var completed = false
        client.onServerRequest = { id, method, params in model.handleServerRequest(id, method: method, params: params) }
        client.onEvent = { method, params in
            model.handleEvent(method, params)
            if method == "turn/completed" { completed = true }
        }
        try await client.start()
        let turnID = try await client.startTurn(threadID: "thread-1", text: "实现功能", attachments: [],
                                               model: nil, effort: nil, permissions: nil, serviceTier: nil)
        XCTAssertEqual(turnID, "turn-1")
        try await waitUntil { !model.selectedUserInputRequests.isEmpty }
        XCTAssertFalse(completed, "Questions must be visible before turn/completed")
        XCTAssertTrue(model.isSelectedThreadProcessing)
        let prompt = try XCTUnwrap(model.selectedUserInputRequests.first)
        XCTAssertEqual(prompt.isBlocking, isBlocking)
        XCTAssertEqual(prompt.questions.first?.options.count, 2)
        XCTAssertTrue(model.assistantReplyChoices.isEmpty, "Tool answers must bypass ordinary queued/draft replies")
        let panel = NSHostingView(rootView: UserInputRequestsPanel(requests: [prompt]) { _, _ in }.frame(width: 600))
        XCTAssertGreaterThan(panel.fittingSize.height, 100, "The input panel must render while the task is active")
        if !isBlocking {
            try await waitUntil { model.messages.contains { $0.id == "progress-1" } }
            XCTAssertEqual(model.selectedUserInputRequests.count, 1)
        }
        model.submitUserInput(requestID: prompt.id, answers: ["scope": "同时修改前后端（推荐）"])
        try await waitUntil { completed }
        XCTAssertTrue(model.selectedUserInputRequests.isEmpty)
        XCTAssertFalse(model.isSelectedThreadProcessing)
        XCTAssertTrue(model.messages.contains { $0.id == "answer-1" })
        let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(requests.filter { $0["method"] as? String == "turn/start" }.count, 1)
        let response = try XCTUnwrap(requests.first { $0["result"] != nil })
        XCTAssertEqual(response["id"] as? Int, 2)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let answers = try XCTUnwrap(result["answers"] as? [String: [String: [String]]])
        XCTAssertEqual(answers["scope"]?["answers"], ["同时修改前后端（推荐）"])
        let arguments = try JSONDecoder().decode([String].self, from: Data(contentsOf: root.appendingPathComponent("arguments.json")))
        XCTAssertTrue(arguments.contains("features.default_mode_request_user_input=true"))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "Expected protocol event did not arrive")
    }
}
