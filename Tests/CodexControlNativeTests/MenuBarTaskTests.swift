import XCTest
@testable import CloudCodex

@MainActor
final class MenuBarTaskTests: XCTestCase {
    func testTaskListTracksBackgroundTurnsWithoutChangingSelection() {
        let model = AppModel()
        model.threads = [
            CodexThread(json: ["id": "one", "cwd": "/tmp", "name": "第一个任务", "status": "idle"])!,
            CodexThread(json: ["id": "two", "cwd": "/tmp", "name": "第二个任务", "status": "idle"])!
        ]
        model.selectedThreadID = "one"
        model.handleEvent("turn/started", ["threadId": "two", "turn": ["id": "turn-two"]])
        XCTAssertEqual(model.menuBarTasks, [.init(id: "two", title: "第二个任务")])
        XCTAssertEqual(model.selectedThreadID, "one")
        model.handleEvent("turn/completed", ["threadId": "two", "turn": ["id": "turn-two", "status": "completed"]])
        XCTAssertTrue(model.menuBarTasks.isEmpty)
    }

    func testStopTargetsBackgroundTaskAndPreservesSelectedDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudCodexMenuBarTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fixture")
        let script = #"""
        #!/usr/bin/python3
        import json, pathlib, sys
        root = pathlib.Path(__file__).parent
        for line in sys.stdin:
            request = json.loads(line)
            if "id" not in request:
                continue
            with (root / "requests.jsonl").open("a") as log:
                log.write(json.dumps(request) + "\n")
            result = {"platformOs": "macos"} if request["method"] == "initialize" else {}
            print(json.dumps({"id": request["id"], "result": result}), flush=True)
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let client = AppServerClient(codexHomeOverride: root, executableOverride: executable)
        let suite = "CloudCodexMenuBarTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            client.terminateUnresponsiveServer()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try await client.start()
        let model = AppModel(remoteDefaults: defaults, client: client)
        model.selectedThreadID = "one"
        model.composerText = "保留当前草稿"
        for id in ["one", "two"] {
            model.handleEvent("turn/started", ["threadId": id, "turn": ["id": "turn-\(id)"]])
        }
        await model.stopMenuBarTask("two")
        let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        let interrupts = requests.filter { $0["method"] as? String == "turn/interrupt" }
        XCTAssertEqual(interrupts.count, 1)
        let params = try XCTUnwrap(interrupts.first?["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, "two")
        XCTAssertEqual(params["turnId"] as? String, "turn-two")
        XCTAssertEqual(model.selectedThreadID, "one")
        XCTAssertEqual(model.composerText, "保留当前草稿")
        XCTAssertTrue(model.menuBarStoppingThreadIDs.isEmpty)
    }
}
