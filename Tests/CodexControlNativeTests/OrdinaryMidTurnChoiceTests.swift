import AppKit
import SwiftUI
import XCTest
@testable import CloudCodex

@MainActor
final class OrdinaryMidTurnChoiceTests: XCTestCase {
    private func withFixture(_ test: (AppModel, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OrdinaryChoice-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("codex-fixture")
        let source = #"""
        #!/usr/bin/python3
        import json, pathlib, sys
        root = pathlib.Path(__file__).parent
        for line in sys.stdin:
            request = json.loads(line)
            if "id" not in request: continue
            with (root / "requests.jsonl").open("a") as log: log.write(json.dumps(request) + "\n")
            method = request["method"]
            result = {}
            if method == "initialize": result = {"platformOs": "macos"}
            elif method in ["thread/resume", "thread/read"]:
                result = {"thread": {"id": "thread-1", "cwd": str(root), "preview": "fixture", "modelProvider": "openai", "status": {"type": "idle"}}}
            elif method == "turn/start": result = {"turn": {"id": "next-turn"}}
            if method == "turn/steer" and (root / "fail").exists():
                response = {"id": request["id"], "error": {"message": "任务已结束，回答尚未发送"}}
            else: response = {"id": request["id"], "result": result}
            print(json.dumps(response), flush=True)
        """#
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let client = AppServerClient(codexHomeOverride: root.appendingPathComponent("home"), executableOverride: script)
        let defaultsName = "OrdinaryChoice-\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        let model = AppModel(remoteDefaults: defaults, client: client)
        client.beforeTurnSubmission = {}
        defer {
            for item in model.waitingMessages { model.removeWaitingMessage(item.id) }
            client.shutdown()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        try await client.start()
        model.selectedThreadID = "thread-1"
        model.handleEvent("turn/started", ["threadId": "thread-1", "turn": ["id": "turn-1"]])
        model.messages = [ChatMessage(id: "user", role: .user, text: "迁移功能", turnID: "turn-1"),
            ChatMessage(id: "question", role: .assistant, text: "数据应该如何处理？\n\n- 共用公共数据（推荐）\n- 新增专用接口", turnID: "turn-1"),
            ChatMessage(id: "progress", role: .assistant, text: "先完成不依赖选择的界面。", turnID: "turn-1")]
        try await test(model, root)
    }

    private func requests(_ root: URL) throws -> [[String: Any]] {
        try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }

    func testAnswerSteersImmediatelyAndPreservesExistingDraftAttachmentsAndQueue() async throws {
        try await withFixture { model, root in
            model.composerText = "已排队的独立要求"
            await model.sendMessage()
            model.composerText = "正在编辑的草稿"
            let attachment = ComposerAttachment(url: URL(fileURLWithPath: "/tmp/choice-fixture.png"))
            model.attachments = [attachment]
            XCTAssertEqual(model.assistantReplyQuestion?.id, "question")
            await model.submitAssistantReplyAnswer(questionID: "question", answer: "共用公共数据（推荐）")
            let rows = try requests(root)
            let steer = try XCTUnwrap(rows.first { $0["method"] as? String == "turn/steer" }?["params"] as? [String: Any])
            XCTAssertEqual(steer["threadId"] as? String, "thread-1")
            XCTAssertEqual(steer["expectedTurnId"] as? String, "turn-1")
            let input = try XCTUnwrap(steer["input"] as? [[String: Any]])
            XCTAssertTrue((input.first?["text"] as? String ?? "").contains("共用公共数据（推荐）"))
            XCTAssertFalse(rows.contains { $0["method"] as? String == "turn/start" })
            XCTAssertEqual(model.composerText, "正在编辑的草稿")
            XCTAssertEqual(model.attachments, [attachment])
            XCTAssertEqual(model.selectedWaitingMessages.map(\.text), ["已排队的独立要求"])
            XCTAssertNil(model.assistantReplyQuestion)
            XCTAssertEqual(model.messages.last?.role, .user)
        }
    }

    func testFailedAnswerKeepsQuestionAndCanRetryWithoutDuplicateSubmission() async throws {
        try await withFixture { model, root in
            try Data().write(to: root.appendingPathComponent("fail"))
            await model.submitAssistantReplyAnswer(questionID: "question", answer: "自定义范围")
            XCTAssertEqual(model.assistantReplyQuestion?.id, "question")
            XCTAssertNotNil(model.assistantReplyErrors["thread-1:question"])
            XCTAssertFalse(model.messages.contains { $0.text.contains("我的选择：") })
            try FileManager.default.removeItem(at: root.appendingPathComponent("fail"))
            await model.submitAssistantReplyAnswer(questionID: "question", answer: "自定义范围")
            XCTAssertNil(model.assistantReplyQuestion)
            await model.submitAssistantReplyAnswer(questionID: "question", answer: "再次点击")
            XCTAssertEqual(try requests(root).filter { $0["method"] as? String == "turn/steer" }.count, 2)
        }
    }

    func testFinishedTaskSendsAnswerAsNewTurnWithoutReplacingDraft() async throws {
        try await withFixture { model, root in
            model.handleEvent("turn/completed", ["threadId": "thread-1", "turn": ["id": "turn-1", "status": "completed"]])
            model.composerText = "另一条未发送草稿"
            await model.submitAssistantReplyAnswer(questionID: "question", answer: "新增专用接口")
            let rows = try requests(root)
            XCTAssertEqual(rows.filter { $0["method"] as? String == "turn/start" }.count, 1)
            XCTAssertFalse(rows.contains { $0["method"] as? String == "turn/steer" })
            XCTAssertEqual(model.composerText, "另一条未发送草稿")
            XCTAssertNil(model.assistantReplyQuestion)
        }
    }

    func testQuestionCardRendersWhileTaskIsStillProcessing() async throws {
        try await withFixture { model, _ in
            let question = try XCTUnwrap(model.assistantReplyQuestion)
            var submitted = false
            let host = NSHostingView(rootView: AssistantReplyQuestionPanel(question: question,
                isSubmitting: false, error: nil, submit: { _ in submitted = true }, dismiss: {}).frame(width: 700))
            XCTAssertGreaterThan(host.fittingSize.height, 100)
            XCTAssertTrue(model.isSelectedThreadProcessing)
            XCTAssertFalse(submitted)
            if let path = ProcessInfo.processInfo.environment["CLOUDCODEX_CHOICE_PREVIEW"] {
                host.frame.size = host.fittingSize
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
