import XCTest
@testable import CloudCodex

@MainActor
final class ComposerPredictionTests: XCTestCase {
    private let suggestion = "补充验证并说明结果"

    private func setReply(_ model: AppModel, turnID: String = "turn-1") {
        model.selectedThreadID = "thread-1"
        model.messages = [ChatMessage(id: "answer", role: .assistant, text: "已完成修改。", turnID: turnID)]
    }

    private func withFixture(_ test: (AppModel, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ComposerPrediction-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex-fixture")
        let source = #"""
        #!/usr/bin/python3
        import json, pathlib, sys, time
        root = pathlib.Path(__file__).parent
        fork_count = 0
        def emit(value): print(json.dumps(value), flush=True)
        for line in sys.stdin:
            request = json.loads(line)
            if "id" not in request: continue
            with (root / "requests.jsonl").open("a") as log: log.write(json.dumps(request) + "\n")
            if request["method"] == "initialize":
                emit({"id": request["id"], "result": {"platformOs": "macos"}})
            elif request["method"] == "thread/fork":
                if request["params"].get("ephemeral") and request["params"].get("deferGoalContinuation"):
                    emit({"id": request["id"], "error": {"code": -32602, "message": "deferGoalContinuation cannot be combined with ephemeral"}})
                    continue
                fork_count += 1
                thread = {"id": "prediction-" + str(fork_count), "ephemeral": True}
                emit({"method": "thread/started", "params": {"thread": thread}})
                emit({"id": request["id"], "result": {"thread": thread}})
            elif request["method"] == "turn/start":
                params = request["params"]
                turn = params["responsesapiClientMetadata"]["prediction_source_turn_id"]
                if turn == "unsupported":
                    emit({"id": request["id"], "error": {"code": -32601, "message": "Method not found"}})
                    continue
                thread = params["threadId"]
                emit({"id": request["id"], "result": {"turn": {"id": "prediction-turn"}}})
                emit({"method": "turn/started", "params": {"threadId": thread, "turn": {"id": "prediction-turn"}}})
                if turn == "delayed": time.sleep(0.15)
                text = json.dumps({"suggestion": None if turn == "empty" else "补充验证并说明结果"})
                emit({"method": "item/completed", "params": {"threadId": thread, "item": {"id": "prediction-text", "type": "agentMessage", "text": text}}})
                emit({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": "prediction-turn", "status": "failed" if turn == "failure" else "completed"}}})
            else: emit({"id": request["id"], "result": {"data": []}})
        """#
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = AppServerClient(codexHomeOverride: root.appendingPathComponent("home"), executableOverride: executable)
        let defaultsName = "ComposerPrediction-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        let model = AppModel(remoteDefaults: defaults, client: client)
        client.beforeTurnSubmission = {} // No account/network reads in protocol fixtures.
        client.onEvent = { [weak model] method, params in model?.handleEvent(method, params) }
        defer { client.onEvent = nil; client.shutdown(); defaults.removePersistentDomain(forName: defaultsName) }
        try await client.start()
        setReply(model)
        try await test(model, root)
    }

    private func request(_ model: AppModel) async throws {
        let source = try XCTUnwrap(model.composerPredictionSource)
        await model.requestComposerPrediction(source)
        let deadline = Date().addingTimeInterval(2)
        while model.composerPredictions[source] == .pending, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotEqual(model.composerPredictions[source], .pending)
    }

    private func requests(_ root: URL) throws -> [[String: Any]] {
        try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }

    func testPredictionIsGhostTextUntilAcceptedAndIsNeverSentAutomatically() async throws {
        try await withFixture { model, root in
            try await request(model)
            XCTAssertEqual(model.composerSuggestion, suggestion)
            XCTAssertEqual(model.composerText, "")
            XCTAssertFalse(model.canSend)
            try await request(model)
            let rows = try requests(root)
            let predictions = rows.filter { $0["method"] as? String == "thread/fork" }
            XCTAssertEqual(predictions.count, 1)
            let params = try XCTUnwrap(predictions.first?["params"] as? [String: Any])
            XCTAssertEqual(params["threadId"] as? String, "thread-1")
            XCTAssertEqual(params["experimentalPredictionMode"] as? Bool, true)
            XCTAssertEqual(params["experimentalDisablePredictionMcp"] as? Bool, true)
            XCTAssertEqual(params["ephemeral"] as? Bool, true)
            XCTAssertNil(params["deferGoalContinuation"])
            let turn = try XCTUnwrap(rows.first { $0["method"] as? String == "turn/start" }?["params"] as? [String: Any])
            XCTAssertEqual(turn["threadId"] as? String, "prediction-1")
            XCTAssertEqual(turn["permissions"] as? String, ":read-only")
            XCTAssertEqual(turn["effort"] as? String, "low")
            XCTAssertEqual(turn["responsesapiClientMetadata"] as? [String: String],
                           ["prediction_source_thread_id": "thread-1", "prediction_source_turn_id": "turn-1"])
            XCTAssertTrue(model.conversationMessages(for: "prediction-1").isEmpty)
            model.acceptComposerSuggestion()
            XCTAssertEqual(model.composerText, suggestion)
            XCTAssertNil(model.composerSuggestion)
            XCTAssertEqual(model.messages.count, 1)
            model.composerText = ""
            XCTAssertNil(model.composerSuggestion, "An accepted suggestion must not reappear")
        }
    }

    func testDraftConversationAndTurnChangesCannotReuseStaleSuggestions() async throws {
        try await withFixture { model, _ in
            try await request(model)
            model.composerText = "用户自己的草稿"
            XCTAssertNil(model.composerSuggestion)
            model.acceptComposerSuggestion()
            XCTAssertEqual(model.composerText, "用户自己的草稿")
            model.composerText = ""
            model.selectedThreadID = "thread-2"
            XCTAssertNil(model.composerSuggestion)
            model.selectedThreadID = "thread-1"
            model.handleEvent("turn/started", ["threadId": "thread-1", "turn": ["id": "turn-2"]])
            XCTAssertNil(model.composerPredictionSource)
            XCTAssertTrue(model.composerPredictions.isEmpty)
        }
    }

    func testLatePredictionCannotReappearAfterNextTurnStarts() async throws {
        try await withFixture { model, root in
            setReply(model, turnID: "delayed")
            let source = try XCTUnwrap(model.composerPredictionSource)
            let task = Task { await model.requestComposerPrediction(source) }
            let deadline = Date().addingTimeInterval(2)
            while !(try requests(root)).contains(where: { $0["method"] as? String == "turn/start" }), Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            model.handleEvent("turn/started", ["threadId": "thread-1", "turn": ["id": "next-turn"]])
            await task.value
            XCTAssertNil(model.composerSuggestion)
            XCTAssertTrue(model.composerPredictions.isEmpty)
        }
    }

    func testCancelledPredictionCanBeRequestedAgain() async throws {
        try await withFixture { model, root in
            setReply(model, turnID: "delayed")
            let source = try XCTUnwrap(model.composerPredictionSource)
            let task = Task { await model.requestComposerPrediction(source) }
            let deadline = Date().addingTimeInterval(2)
            while !(try requests(root)).contains(where: { $0["method"] as? String == "turn/start" }), Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            task.cancel()
            await task.value
            XCTAssertNil(model.composerPredictions[source])
            await model.requestComposerPrediction(source)
            XCTAssertEqual(model.composerSuggestion, suggestion)
        }
    }

    func testUnavailablePredictionCanBeRetried() async throws {
        try await withFixture { model, root in
            setReply(model, turnID: "empty")
            try await request(model)
            XCTAssertEqual(model.composerPredictionState, .unavailable)
            await model.retryComposerPrediction()
            let forks = try requests(root).filter { $0["method"] as? String == "thread/fork" }
            XCTAssertEqual(forks.count, 2)
            XCTAssertEqual(model.composerPredictionState, .unavailable)
            XCTAssertTrue(model.composerText.isEmpty)
        }
    }

    func testFailedEmptyAndUnsupportedPredictionsLeaveNormalInputAvailable() async throws {
        try await withFixture { model, root in
            for turn in ["failure", "empty", "unsupported", "after-unsupported"] {
                setReply(model, turnID: turn)
                try await request(model)
                XCTAssertNil(model.composerSuggestion)
                XCTAssertNil(model.errorMessage)
            }
            let rows = try requests(root).filter { $0["method"] as? String == "thread/fork" }
            XCTAssertEqual(rows.count, 3, "Older servers must not receive repeated unsupported requests")
            model.composerText = "继续工作"
            XCTAssertTrue(model.canSend)
        }
    }

    func testNewThreadStreamingAndAttachmentsDoNotRequestPredictions() {
        let name = "ComposerPredictionEligibility-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(remoteDefaults: defaults)
        setReply(model)
        XCTAssertNotNil(model.composerPredictionSource)
        model.showingNewThread = true
        XCTAssertNil(model.composerPredictionSource)
        model.showingNewThread = false
        model.messages[0].isStreaming = true
        XCTAssertNil(model.composerPredictionSource)
        model.messages[0].isStreaming = false
        model.attachments = [ComposerAttachment(url: URL(fileURLWithPath: "/tmp/fixture.png"))]
        XCTAssertNil(model.composerPredictionSource)
        model.attachments = []
        model.messages.append(ChatMessage(id: "user", role: .user, text: "下一轮"))
        XCTAssertNil(model.composerPredictionSource)
    }
}
