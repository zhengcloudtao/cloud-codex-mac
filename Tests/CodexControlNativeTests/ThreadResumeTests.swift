import Foundation
import XCTest
@testable import CloudCodex

/// A local stdio fixture exercises the actual request/decoder/deadline path.
/// It never connects to an account or reads or resumes a user's conversation.
@MainActor
final class ThreadResumeTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let client: AppServerClient
        let defaults: UserDefaults
        let defaultsName: String
        @MainActor func stop() {
            client.terminateUnresponsiveServer()
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
        }
        func requests() throws -> [[String: Any]] {
            try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
                .split(separator: "\n").map {
                    try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
                }
        }
    }

    private func fixture(delay: Double = 0.2, failures: [String] = [], timeout: UInt64 = 60) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudCodexResumeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("codex-fixture")
        let settings = try JSONSerialization.data(withJSONObject: ["delay": delay, "failures": failures])
        try settings.write(to: root.appendingPathComponent("settings.json"))
        let source = #"""
        #!/usr/bin/python3
        import json, pathlib, sys, threading, time
        root = pathlib.Path(__file__).parent
        settings = json.loads((root / "settings.json").read_text())
        lock = threading.Lock()
        resume_count = 0
        def reply(request, result=None, error=None):
            response = {"id": request["id"]}
            response["error" if error else "result"] = {"message": error} if error else result
            with lock:
                print(json.dumps(response), flush=True)
        def metadata(thread_id):
            return {"id": thread_id, "cwd": str(root), "preview": thread_id,
                    "modelProvider": "openai", "status": {"type": "idle"}}
        def resume(request, number):
            time.sleep(settings["delay"])
            failures = settings["failures"]
            if number < len(failures):
                reply(request, error=failures[number])
            else:
                reply(request, {"thread": metadata(request["params"]["threadId"]), "serviceTier": "default"})
        for line in sys.stdin:
            request = json.loads(line)
            if "id" not in request:
                continue
            with (root / "requests.jsonl").open("a") as log:
                log.write(json.dumps(request) + "\n")
            method = request["method"]
            params = request.get("params", {})
            if method == "initialize":
                reply(request, {"platformOs": "macos"})
            elif method == "thread/resume":
                threading.Thread(target=resume, args=(request, resume_count), daemon=True).start()
                resume_count += 1
            elif method == "thread/read":
                reply(request, {"thread": metadata(params["threadId"])})
            elif method == "thread/turns/list":
                reply(request, {"data": [{"id": "turn-" + params["threadId"], "status": "completed", "items": [
                    {"id": "answer-" + params["threadId"], "type": "agentMessage", "text": "历史内容-" + params["threadId"]}
                ]}]})
            elif method == "thread/unsubscribe":
                time.sleep(0.1)
                reply(request, {})
            else:
                reply(request, {"data": []})
        """#
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = AppServerClient(codexHomeOverride: root.appendingPathComponent("home"), executableOverride: executable, resumeTimeoutSeconds: timeout)
        try await client.start()
        let defaultsName = "CloudCodexResumeTests-\(UUID().uuidString)"
        return Fixture(root: root, client: client, defaults: UserDefaults(suiteName: defaultsName)!, defaultsName: defaultsName)
    }

    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "Expected state did not arrive")
    }

    func testSlowResumeExceedsOrdinaryDeadlineAndConcurrentCallersShareRequest() async throws {
        let fixture = try await fixture(delay: 13)
        defer { fixture.stop() }
        async let first = fixture.client.resumeThread("long-history")
        async let second = fixture.client.resumeThread("long-history")
        let tiers = try await [first, second]
        XCTAssertEqual(tiers, ["default", "default"])
        let resumes = try fixture.requests().filter { $0["method"] as? String == "thread/resume" }
        XCTAssertEqual(resumes.count, 1)
        XCTAssertEqual((resumes.first?["params"] as? [String: Any])?["excludeTurns"] as? Bool, true)
    }

    func testHistoryLoadsBeforeWriterIsReadyAndRepeatedRetryDoesNotDuplicateResume() async throws {
        let fixture = try await fixture(delay: 0.6)
        defer { fixture.stop() }
        let model = AppModel(remoteDefaults: fixture.defaults, client: fixture.client)
        model.composerText = "保留草稿"
        model.selectThread("history")
        try await waitUntil { model.messages.contains { $0.text == "历史内容-history" } && !model.isConversationLoading }
        XCTAssertEqual(model.threadInputAvailability, .checking)
        XCTAssertFalse(model.canSend)
        await model.retrySelectedThreadOwnership()
        try await waitUntil { model.threadInputAvailability == .available }
        XCTAssertEqual(model.composerText, "保留草稿")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(try fixture.requests().filter { $0["method"] as? String == "thread/resume" }.count, 1)
        model.selectThread(nil)
    }

    func testTimeoutKeepsHistoryAndDraftOffersRetryAndDoesNotEnableSending() async throws {
        let fixture = try await fixture(delay: 1.2, timeout: 1)
        defer { fixture.stop() }
        let model = AppModel(remoteDefaults: fixture.defaults, client: fixture.client)
        model.composerText = "保留草稿"
        model.selectThread("timeout")
        try await waitUntil { model.threadInputAvailability == .unavailable }
        XCTAssertEqual(model.messages.last?.text, "历史内容-timeout")
        XCTAssertEqual(model.composerText, "保留草稿")
        XCTAssertFalse(model.canSend)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.threadOwnershipNotice?.contains("thread/resume") == true)
        model.selectThread(nil)
    }

    func testFailedResumeCanBeRetriedAndActiveWriterStillBlocksInput() async throws {
        let fixture = try await fixture(failures: ["Thread is held by an ACTIVE WRITER"])
        defer { fixture.stop() }
        let model = AppModel(remoteDefaults: fixture.defaults, client: fixture.client)
        model.selectThread("occupied")
        try await waitUntil { model.threadInputAvailability == .occupied }
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.canSend)
        await model.retrySelectedThreadOwnership()
        XCTAssertEqual(model.threadInputAvailability, .available)
        XCTAssertNil(model.threadOwnershipNotice)
        XCTAssertEqual(try fixture.requests().filter { $0["method"] as? String == "thread/resume" }.count, 2)
        model.selectThread(nil)
    }

    func testSwitchingAwayReleasesPendingWriterAndReselectionWaitsForRelease() async throws {
        let fixture = try await fixture(delay: 0.2)
        defer { fixture.stop() }
        let first = Task { try await fixture.client.resumeThread("switch") }
        try await waitUntil { (try? fixture.requests().contains { $0["method"] as? String == "thread/resume" }) == true }
        let release = Task { try await fixture.client.unsubscribeThread("switch") }
        try await Task.sleep(nanoseconds: 20_000_000)
        let reselected = Task { try await fixture.client.resumeThread("switch") }
        _ = try await first.value
        try await release.value
        _ = try await reselected.value
        let methods = try fixture.requests().compactMap { $0["method"] as? String }.filter { $0 == "thread/resume" || $0 == "thread/unsubscribe" }
        XCTAssertEqual(methods, ["thread/resume", "thread/unsubscribe", "thread/resume"])
    }

}
