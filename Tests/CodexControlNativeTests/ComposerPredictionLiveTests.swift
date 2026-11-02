import AppKit
import XCTest
@testable import CloudCodex

@MainActor
final class ComposerPredictionLiveTests: XCTestCase {
    func testRealServerReturnsSuggestionAndTabAcceptsIt() async throws {
        guard ProcessInfo.processInfo.environment["CLOUDCODEX_LIVE_PREDICTION"] == "1" else {
            throw XCTSkip("Opt in to a real model request with CLOUDCODEX_LIVE_PREDICTION=1")
        }
        let client = AppServerClient()
        defer { client.shutdown() }
        try await client.start()
        let models = try await client.listModels()
        let selected = try XCTUnwrap(models.first(where: \.isDefault) ?? models.first)
        let thread = try await client.createThread(
            cwd: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().path,
            model: selected.model, permissions: ":read-only"
        )
        var completedTurn: String?
        var failed = false
        client.onEvent = { method, params in
            guard params["threadId"] as? String == thread.id else { return }
            if method == "turn/completed", let turn = params["turn"] as? [String: Any] {
                completedTurn = turn["id"] as? String
                failed = turn["status"] as? String != "completed"
            }
        }
        _ = try await client.startTurn(
            threadID: thread.id,
            text: "这是 CloudCodex 输入建议的验证会话。帮我规划一个番茄钟页面：先给出三个简短实施步骤，后面我会让你继续第二步。现在只列步骤，不执行操作，不调用工具。",
            attachments: [], model: selected.model, effort: "low", permissions: ":read-only",
            serviceTier: nil, approvalPolicy: "never"
        )
        let deadline = Date().addingTimeInterval(90)
        while completedTurn == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(failed)
        let turn = try XCTUnwrap(completedTurn, "Live parent turn did not complete")
        let suggestion: String?
        do {
            suggestion = try await client.requestComposerPrediction(threadID: thread.id, sourceTurnID: turn)
        } catch {
            // Report only known protocol words, never account identifiers or credentials.
            let message = error.localizedDescription.lowercased()
            let words = ["prediction", "permissions", "override", "sandbox", "schema", "unsupported", "invalid",
                         "loaded", "persisted", "ephemeral", "timeout", "model", "effort", "not found", "required",
                         "cannot", "profile", "read-only", "experimental", "config", "超时", "无法识别"]
            let safeWords = Set("a an the cannot can not be is are in on with without for from to of and or ephemeral thread threads fork forked forking persist persisted persistence save saved prediction mode true false unsupported invalid parameter parameters must required only when enabled use using supported start started existing new parent id source turn".split(separator: " ").map(String.init))
            let safeMessage = message.split(whereSeparator: { !$0.isLetter }).filter { safeWords.contains(String($0)) }.joined(separator: " ")
            XCTFail("Live prediction failed: " + words.filter { message.contains($0) }.joined(separator: ", ") + " / " + safeMessage)
            return
        }
        let text = try XCTUnwrap(suggestion, "Real server returned no suggestion")
        XCTAssertFalse(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let view = ComposerNSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 64))
        view.font = NSFont.preferredFont(forTextStyle: .body)
        view.suggestion = text
        var accepted = false
        view.acceptSuggestion = { accepted = true }
        XCTAssertTrue(view.showsSuggestion)
        XCTAssertTrue(view.string.isEmpty)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let tab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
            isARepeat: false, keyCode: 48))
        view.keyDown(with: tab)
        XCTAssertTrue(accepted)
        XCTAssertEqual(view.string, text)
        print("Live prediction rendered and accepted via Tab: \(text)")
    }
}
