import XCTest
@testable import CloudCodex

@MainActor
final class WeeklyQuotaProbeTests: XCTestCase {
    private func fixture() throws -> (URL, () -> AppServerClient) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudCodexQuotaProbe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake-codex")
        let source = #"""
        #!/usr/bin/env python3
        import json, os, pathlib, sys, time
        root = pathlib.Path(__file__).parent
        reset = time.time() + 3600
        for line in sys.stdin:
            request = json.loads(line)
            if "id" not in request:
                continue
            method = request["method"]
            with (root / "methods.txt").open("a") as log:
                log.write(method + "\n")
            if method == "initialize":
                result = {"platformOs": "macos"}
            elif method == "account/read":
                result = {"account": {"type": "chatgpt", "email": "synthetic@example.invalid", "planType": "plus"}}
            elif method == "account/rateLimits/read":
                result = {"rateLimits": {"planType": "plus", "primary": {"usedPercent": 10, "windowDurationMins": 10080, "resetsAt": reset}}}
            elif method == "account/usage/read":
                if (root / "delay-usage").exists():
                    time.sleep(3)
                result = {"summary": {"lifetimeTokens": 1000}}
            elif method == "turn/start":
                if request.get("params", {}).get("threadId") == "failed":
                    print(json.dumps({"id": request["id"], "error": {"code": -1, "message": "synthetic failure"}}), flush=True)
                    continue
                result = {"turn": {"id": "fixture-turn"}}
            elif method == "thread/list":
                if request.get("params", {}).get("cwd") == "busy":
                    (root / "busy").touch()
                    time.sleep(3)
                result = {"data": [], "nextCursor": None}
            else:
                raise RuntimeError("unexpected method")
            print(json.dumps({"id": request["id"], "result": result}), flush=True)
        """#
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, { AppServerClient(codexHomeOverride: root.appendingPathComponent("home"), executableOverride: executable) })
    }

    func testAcceptedTurnCapturesFastAtSubmissionAndFailureDoesNotWriteTier() async throws {
        let (root, factory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = factory()
        defer { client.shutdown() }
        try await client.start()
        _ = try await client.startTurn(threadID: "fast-thread", text: "PRIVATE_FIXTURE_PROMPT", attachments: [],
            model: "gpt-6.1-sol", effort: nil, permissions: nil, serviceTier: "priority")
        _ = try await client.startTurn(threadID: "standard-thread", text: "PRIVATE_FIXTURE_PROMPT", attachments: [],
            model: "gpt-6.1-sol", effort: nil, permissions: nil, serviceTier: "default")
        do {
            _ = try await client.startTurn(threadID: "failed", text: "PRIVATE_FIXTURE_PROMPT", attachments: [],
                model: nil, effort: nil, permissions: nil, serviceTier: "priority")
            XCTFail("Expected fixture rejection")
        } catch {}
        let home = root.appendingPathComponent("home")
        let entries = CodexUsageTierStore.load(home: home)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries["fast-thread:fixture-turn"]?.tier, "priority")
        XCTAssertEqual(entries["standard-thread:fixture-turn"]?.tier, "default")
        let stored = try String(contentsOf: CodexUsageTierStore.file(home))
        XCTAssertFalse(stored.contains("PRIVATE_FIXTURE_PROMPT"))
        XCTAssertFalse(stored.contains("gpt-6.1-sol"))
        let attributes = try FileManager.default.attributesOfItem(atPath: CodexUsageTierStore.file(home).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testBusyConversationTransportDoesNotQueueIndependentProbe() async throws {
        let (root, factory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = factory()
        defer { main.shutdown() }
        try await main.start()
        var conversationFinished = false
        let busy = Task { @MainActor in
            defer { conversationFinished = true }
            return try await main.listThreads(cwd: "busy")
        }
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("busy").path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("busy").path))
        let probe = WeeklyQuotaProbe(makeClient: factory)
        let value = try await probe.read()
        XCTAssertEqual(value.lifetimeTokens, 1000)
        XCTAssertFalse(conversationFinished, "Quota reads queued behind the conversation transport")
        _ = try await busy.value
        let methods = try String(contentsOf: root.appendingPathComponent("methods.txt"))
        XCTAssertFalse(methods.contains("turn/start"))
        XCTAssertFalse(methods.contains("thread/resume"))
    }

    func testUsageTimeoutIdentifiesSpecificEndpoint() async throws {
        let (root, factory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("delay-usage"))
        let client = factory()
        defer { client.shutdown() }
        try await client.start()
        do {
            _ = try await client.readWeeklyQuotaSnapshot(usageTimeoutSeconds: 1)
            XCTFail("Expected bounded usage timeout")
        } catch {
            XCTAssertEqual(WeeklyQuotaComparison.ReadIssue.classify(error), .usageTimeout)
        }
    }

    func testLocalTokenModeDoesNotReadStaleOrSlowAccountUsage() async throws {
        let (root, factory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("delay-usage"))
        let probe = WeeklyQuotaProbe(makeClient: factory)
        let value = try await probe.read(localTokenMode: true, knownLifetimeTokens: 1234)
        XCTAssertFalse(value.accountTokensAvailable)
        XCTAssertEqual(value.lifetimeTokens, 1234)
        let methods = try String(contentsOf: root.appendingPathComponent("methods.txt"))
        XCTAssertFalse(methods.contains("account/usage/read"))
        XCTAssertFalse(methods.contains("thread/resume"))
    }

    func testCancellingProbeDoesNotDisconnectMainClient() async throws {
        let (root, factory) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("delay-usage"))
        let main = factory()
        defer { main.shutdown() }
        try await main.start()
        let probe = WeeklyQuotaProbe(makeClient: factory)
        let reading = Task { try await probe.read() }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            let methods = (try? String(contentsOf: root.appendingPathComponent("methods.txt"))) ?? ""
            if methods.contains("account/usage/read") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        probe.cancel()
        do { _ = try await reading.value; XCTFail("Cancelled probe should end its pending read") }
        catch { /* Expected: only the telemetry process was stopped. */ }
        _ = try await main.listThreads(cwd: nil)
    }
}
