import XCTest
import SwiftUI
@testable import CloudCodex

@MainActor
final class CodexAccountsTests: XCTestCase {
    func testSharedAvailabilityKeepsLocalLoginAndHistoryAndRecoversAfterRecheck() async throws {
        let f = try fixture()
        defer { f.stop() }
        let id = UUID().uuidString
        try f.store.addSharedAccount(id: id, access: .init(accessToken: "synthetic", chatgptAccountId: "fixture", chatgptPlanType: "plus", email: "fixture@example.invalid", expiresAt: Date().timeIntervalSince1970 + 1800))
        let home = try XCTUnwrap(f.store.home(for: f.store.library.accounts.last!))
        let history = home.appendingPathComponent("history-fixture.txt")
        try Data("keep history".utf8).write(to: history)
        f.store.checkSharedAccess = { _ in throw URLError(.timedOut) }
        await f.store.reconcileSharedAccounts()
        XCTAssertNil(f.store.library.accounts.last?.sharedUnavailable)
        f.store.checkSharedAccess = { _ in false }
        await f.store.reconcileSharedAccounts()
        XCTAssertEqual(f.store.library.accounts.last?.sharedUnavailable, true)
        XCTAssertEqual(f.store.active.id, "local")
        XCTAssertNil(f.store.busyID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.path))
        let reloaded = CodexAccountStore(defaults: f.defaults, root: f.store.root)
        XCTAssertEqual(reloaded.library.accounts.last?.sharedUnavailable, true)
        f.store.activate(id)
        await f.store.reconcileSharedAccounts()
        XCTAssertEqual(f.store.active.id, id, "Status checks must not switch or stop the active account")
        f.store.checkSharedAccess = { _ in true }
        await f.store.reconcileSharedAccounts()
        XCTAssertEqual(f.store.library.accounts.last?.sharedUnavailable, false)
        XCTAssertNil(f.store.issues[id])
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let executable: URL
        let localHome: URL
        let defaults: UserDefaults
        let suite: String
        let store: CodexAccountStore
        func stop() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        func client() -> AppServerClient { AppServerClient(codexHomeOverride: localHome, executableOverride: executable) }
    }

    private func fixture(mode: String = "success") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexAccountsTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("server.py")
        let source = #"""
        #!/usr/bin/python3
        import json, os, pathlib, sys
        root = pathlib.Path(__file__).parent
        home = pathlib.Path(os.environ["CODEX_HOME"])
        mode = (root / "mode").read_text()
        def reply(req, result):
            print(json.dumps({"id": req["id"], "result": result}), flush=True)
        for line in sys.stdin:
            req = json.loads(line)
            if "id" not in req: continue
            if "method" not in req:
                if req.get("id") == "share-refresh":
                    (root / "renewed").write_text("ok" if req.get("result", {}).get("chatgptAccountId") == "fixture-account" else "failed")
                continue
            method = req["method"]
            # Metadata only, no request params or credentials are logged.
            with (root / "calls.jsonl").open("a") as f:
                f.write(json.dumps({"home": str(home), "method": method, "args": sys.argv[1:], "threadId": req.get("params", {}).get("threadId")}) + "\n")
            if method == "initialize": reply(req, {"platformOs": "macos"})
            elif method == "account/read":
                if (home / "invalid").exists(): reply(req, {"account": None})
                else: reply(req, {"account": {"type": "chatgpt", "email": "test@example.invalid", "planType": "plus"}})
            elif method == "account/login/start":
                if mode == "shared":
                    reply(req, {})
                    print(json.dumps({"id": "share-refresh", "method": "account/chatgptAuthTokens/refresh", "params": {"accountId": "fixture-account"}}), flush=True)
                    continue
                if mode == "success":
                    # Deliberately complete BEFORE the login response.
                    print(json.dumps({"method": "account/login/completed", "params": {"loginId": "test-login", "success": True}}), flush=True)
                reply(req, {"loginId": "test-login", "authUrl": "https://example.invalid/login"})
                if mode == "crash": sys.exit(1)
            elif method == "account/login/cancel":
                reply(req, {})
                print(json.dumps({"method": "account/login/completed", "params": {"loginId": "test-login", "success": True}}), flush=True)
            elif method == "account/rateLimits/read":
                reply(req, {"rateLimits": {"planType": "plus", "primary": {"usedPercent": 25, "windowDurationMins": 300}}})
            elif method == "thread/list":
                reply(req, {"data": [{"id": "shared-thread", "cwd": str(root), "status": {"type": "idle"}}], "nextCursor": None})
            elif method == "thread/read":
                reply(req, {"thread": {"id": req["params"]["threadId"], "cwd": str(root), "status": {"type": "idle"}, "modelProvider": "openai", "turns": []}})
            elif method == "turn/start": reply(req, {"turn": {"id": "continued-turn"}})
            else: reply(req, {"data": []})
        """#
        try source.write(to: executable, atomically: true, encoding: .utf8)
        try mode.write(to: root.appendingPathComponent("mode"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let suite = "CodexAccountsTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let localHome = root.appendingPathComponent("local")
        let store = CodexAccountStore(defaults: defaults, root: root.appendingPathComponent("accounts"),
            makeClient: { home, managed in
                AppServerClient(codexHomeOverride: home ?? localHome, executableOverride: executable, usesManagedAccount: managed)
            }, openURL: { _ in true })
        return .init(root: root, executable: executable, localHome: localHome, defaults: defaults, suite: suite, store: store)
    }

    private func settle(_ store: CodexAccountStore) async throws {
        for _ in 0..<150 {
            if store.busyID == nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Account operation did not finish")
    }

    func testLoginCompletionBeforeResponsePersistsOnlyMetadataAndUsesPrivateKeyringHome() async throws {
        let f = try fixture(); defer { f.stop() }
        await f.store.addAccount()
        try await settle(f.store)
        let account = try XCTUnwrap(f.store.library.accounts.last)
        XCTAssertEqual(account.identity?.email, "test@example.invalid")
        XCTAssertEqual(f.store.library.activeID, "local", "Adding must not switch the running account")
        XCTAssertNotNil(f.store.overviews[account.id])
        let home = try XCTUnwrap(f.store.home(for: account))
        let permissions = try FileManager.default.attributesOfItem(atPath: home.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o700)
        let stored = try XCTUnwrap(f.defaults.data(forKey: CodexAccountStore.defaultsKey))
        let json = String(decoding: stored, as: UTF8.self)
        XCTAssertFalse(json.contains("access_token")); XCTAssertFalse(json.contains("refresh_token"))
        let calls = try String(contentsOf: f.root.appendingPathComponent("calls.jsonl"))
        XCTAssertTrue(calls.contains("cli_auth_credentials_store"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
        let reload = CodexAccountStore(defaults: f.defaults, root: f.store.root)
        XCTAssertEqual(reload.library.accounts, f.store.library.accounts)
    }

    func testLoginProcessFailureStopsWaitingImmediately() async throws {
        let f = try fixture(mode: "crash"); defer { f.stop() }
        await f.store.addAccount()
        try await settle(f.store)
        let id = try XCTUnwrap(f.store.library.accounts.last?.id)
        XCTAssertNotNil(f.store.issues[id])
        XCTAssertNil(f.store.loginURL)
        XCTAssertNil(f.store.library.accounts.last?.identity)
    }

    func testCancelIgnoresLateSuccessAndRetainsDraftForRetry() async throws {
        let f = try fixture(mode: "waiting"); defer { f.stop() }
        await f.store.addAccount()
        XCTAssertNotNil(f.store.loginURL)
        await f.store.cancelLogin()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(f.store.busyID); XCTAssertNil(f.store.loginURL)
        XCTAssertNil(f.store.library.accounts.last?.identity)
        XCTAssertEqual(f.store.library.activeID, "local")
    }

    func testSwitchRetainsSelectedHistoryAndSharedPreferencesOnReturn() async throws {
        let f = try fixture(); defer { f.stop() }
        await f.store.addAccount(); try await settle(f.store)
        let target = try XCTUnwrap(f.store.library.accounts.last)
        var unread = UnreadCompletions()
        unread.complete(threadID: "original", turnID: "turn", viewed: false)
        f.defaults.set(try JSONEncoder().encode(unread), forKey: "cloudcodex.unreadCompletions.v1")
        let client = f.client(); defer { client.shutdown() }
        try await client.start()
        let model = AppModel(remoteDefaults: f.defaults, client: client, accounts: f.store)
        model.selectedThreadID = "shared-thread"
        model.messages = [ChatMessage(id: "old", role: .assistant, text: "Original account history")]
        model.composerText = "Continue this task"
        XCTAssertNil(model.accountSwitchUnavailableReason)
        await model.switchAccount(to: target.id)
        XCTAssertNil(model.accountSwitchError)
        XCTAssertEqual(f.store.library.activeID, target.id)
        XCTAssertEqual(client.codexHomeOverride, f.store.home(for: target))
        XCTAssertTrue(client.usesManagedAccount)
        XCTAssertEqual(model.messages.first?.text, "Original account history")
        XCTAssertEqual(model.selectedThreadID, "shared-thread")
        XCTAssertEqual(model.composerText, "Continue this task")
        XCTAssertEqual(model.threadInputAvailability, .available)
        XCTAssertEqual(model.unreadCompletions.unread, ["original"])
        XCTAssertTrue(model.threads.contains { $0.id == "shared-thread" })
        // A mocked turn proves the next submission uses the new home and same thread.
        client.beforeTurnSubmission = nil
        let turn = try await client.startTurn(threadID: "shared-thread", text: "continue", attachments: [],
            model: nil, effort: nil, permissions: nil, serviceTier: nil)
        XCTAssertEqual(turn, "continued-turn")
        let calls = try String(contentsOf: f.root.appendingPathComponent("calls.jsonl")).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
        let continued = try XCTUnwrap(calls.last { $0["method"] as? String == "turn/start" })
        XCTAssertEqual(continued["threadId"] as? String, "shared-thread")
        XCTAssertEqual(continued["home"] as? String, f.store.home(for: target)?.path)
        XCTAssertEqual(model.accountOverview?.plan, "plus")
        await model.switchAccount(to: "local")
        XCTAssertEqual(f.store.library.activeID, "local")
        XCTAssertEqual(client.codexHomeOverride, f.localHome)
        XCTAssertFalse(client.usesManagedAccount)
        XCTAssertEqual(model.unreadCompletions.unread, ["original"])
    }

    func testInvalidTargetRollsBackConnectionAndKeepsHistoryAndSelection() async throws {
        let f = try fixture(); defer { f.stop() }
        await f.store.addAccount(); try await settle(f.store)
        let target = try XCTUnwrap(f.store.library.accounts.last)
        try Data().write(to: XCTUnwrap(f.store.home(for: target)).appendingPathComponent("invalid"))
        let client = f.client(); defer { client.shutdown() }
        try await client.start()
        let model = AppModel(remoteDefaults: f.defaults, client: client, accounts: f.store)
        model.messages = [ChatMessage(id: "old", role: .assistant, text: "Retained")]
        await model.switchAccount(to: target.id)
        XCTAssertEqual(f.store.library.activeID, "local")
        XCTAssertEqual(model.messages.first?.text, "Retained")
        XCTAssertEqual(client.codexHomeOverride, f.localHome)
        XCTAssertTrue(client.connected)
        XCTAssertNotNil(model.accountSwitchError)
        XCTAssertFalse(model.isSwitchingModelProvider)
        XCTAssertNil(f.store.busyID)
    }

    func testDraftIsPreservedAcrossAccountSwitch() async throws {
        let f = try fixture(); defer { f.stop() }
        await f.store.addAccount(); try await settle(f.store)
        let target = try XCTUnwrap(f.store.library.accounts.last)
        let client = f.client(); defer { client.shutdown() }
        let model = AppModel(remoteDefaults: f.defaults, client: client, accounts: f.store)
        model.composerText = "Unsent work"
        await model.switchAccount(to: target.id)
        XCTAssertEqual(f.store.library.activeID, target.id)
        XCTAssertNil(model.accountSwitchError)
        XCTAssertEqual(model.composerText, "Unsent work")
    }

    func testRemoteControlStaysEnabledWhenSwitchingAccountsAndRollingBack() async throws {
        let f = try fixture(); defer { f.stop() }
        await f.store.addAccount(); try await settle(f.store)
        let target = try XCTUnwrap(f.store.library.accounts.last)
        f.defaults.set(true, forKey: "CloudCodex.remoteControl.enabled.v1")
        let client = f.client(); defer { client.shutdown() }
        try await client.start()
        // No real relay or keychain access in this test.
        let model = AppModel(remoteDefaults: f.defaults,
            remoteAPILoader: { _ in throw RemoteCredentialError.authorizationRequired },
            client: client, accounts: f.store)
        XCTAssertTrue(model.remoteControlEnabled)
        XCTAssertNil(model.accountSwitchUnavailableReason)
        await model.switchAccount(to: target.id)
        XCTAssertNil(model.accountSwitchError)
        XCTAssertEqual(f.store.library.activeID, target.id)
        XCTAssertTrue(model.remoteControlEnabled)
        XCTAssertTrue(f.defaults.bool(forKey: "CloudCodex.remoteControl.enabled.v1"))
        for _ in 0..<100 where model.isLoadingRemoteCredential {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNil(model.accountSwitchUnavailableReason)
        await model.switchAccount(to: "local")
        XCTAssertEqual(f.store.library.activeID, "local")
        try Data().write(to: XCTUnwrap(f.store.home(for: target)).appendingPathComponent("invalid"))
        await model.switchAccount(to: target.id)
        XCTAssertNotNil(model.accountSwitchError)
        XCTAssertEqual(f.store.library.activeID, "local")
        XCTAssertTrue(model.remoteControlEnabled)
        XCTAssertTrue(client.connected)
        XCTAssertTrue(model.connectionText.hasPrefix("已连接"))
    }

    func testRunningTurnPreventsAccountSwitch() async throws {
        let f = try fixture(); defer { f.stop() }
        await f.store.addAccount(); try await settle(f.store)
        let target = try XCTUnwrap(f.store.library.accounts.last)
        let client = f.client(); defer { client.shutdown() }
        let model = AppModel(remoteDefaults: f.defaults, client: client, accounts: f.store)
        model.handleEvent("turn/started", ["threadId": "running", "turn": ["id": "turn"]])
        await model.switchAccount(to: target.id)
        XCTAssertEqual(f.store.library.activeID, "local")
        XCTAssertTrue(model.accountSwitchError?.contains("任务") == true)
        model.handleEvent("turn/completed", ["threadId": "running", "turn": ["id": "turn", "status": "completed"]])
    }

    func testReauthorizationRejectsDifferentIdentityAndRetainsOriginalCard() async throws {
        let f = try fixture(); defer { f.stop() }
        await f.store.addAccount(); try await settle(f.store)
        let id = try XCTUnwrap(f.store.library.accounts.last?.id)
        f.store.update(id, identity: .init(email: "original@example.invalid", plan: "pro"))
        let original = try XCTUnwrap(f.store.library.accounts.last)
        await f.store.login(original); try await settle(f.store)
        XCTAssertEqual(f.store.library.accounts.last?.identity?.email, "original@example.invalid")
        XCTAssertTrue(f.store.issues[id]?.contains("不一致") == true)
        let calls = try String(contentsOf: f.root.appendingPathComponent("calls.jsonl"))
        XCTAssertTrue(calls.contains("account/logout"))
    }

    func testSharedAccountUsesEphemeralAuthRefreshAndReturnsToNativeLogin() async throws {
        let f = try fixture(mode: "shared"); defer { f.stop() }
        let client = f.client(); defer { client.shutdown() }
        let access = SharedAccountAccess(accessToken: "synthetic-only", chatgptAccountId: "fixture-account", chatgptPlanType: "plus", email: "fixture@example.invalid", expiresAt: Date().timeIntervalSince1970 + 1800)
        var loaded = 0, refreshed = 0
        client.sharedAccountAccessProvider = { loaded += 1; return access }
        client.sharedAccountRefreshProvider = { refreshed += 1; return access }
        try await client.start()
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: f.root.appendingPathComponent("renewed").path) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(client.connected); XCTAssertEqual(loaded, 1); XCTAssertEqual(refreshed, 1)
        XCTAssertEqual(try String(contentsOf: f.root.appendingPathComponent("renewed")), "ok")
        let calls = try String(contentsOf: f.root.appendingPathComponent("calls.jsonl"))
        XCTAssertTrue(calls.contains("ephemeral")); XCTAssertFalse(calls.contains("synthetic-only"))
        client.sharedAccountAccessProvider = nil; client.sharedAccountRefreshProvider = nil
        try await client.changeAccount(home: f.localHome, managed: false)
        XCTAssertTrue(client.connected); XCTAssertEqual(loaded, 1)
    }

    func testSharedAccountStartupFailureDoesNotFallBackToNativeIdentity() async throws {
        let f = try fixture(); defer { f.stop() }
        let client = f.client(); defer { client.shutdown() }
        client.sharedAccountAccessProvider = { throw AccountShareCrypto.failure }
        do { try await client.start(); XCTFail("Missing share must fail") } catch { }
        XCTAssertFalse(client.connected)
    }

    func testOptionalAccountManagementPreview() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CLOUDCODEX_ACCOUNTS_PREVIEW_DIR"] else {
            throw XCTSkip("Set CLOUDCODEX_ACCOUNTS_PREVIEW_DIR to render the native account sheet.")
        }
        let f = try fixture(); defer { f.stop() }
        await f.store.addAccount(); try await settle(f.store)
        let client = f.client(); defer { client.shutdown() }
        let model = AppModel(remoteDefaults: f.defaults, client: client, accounts: f.store)
        let view = NSHostingView(rootView: CodexAccountsSheet(store: f.store).environmentObject(model).preferredColorScheme(.dark))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 700, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
        window.title = "CloudCodex Account Test Preview"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = view
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 600)
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("account-management.png"))
        window.contentView = nil
        await f.store.cancelLogin()
    }

    func testInvalidSavedIDsCannotEscapeAccountRoot() throws {
        let f = try fixture(); defer { f.stop() }
        let data = try JSONEncoder().encode(CodexAccountStore.Library(accounts: [.init(id: "../../elsewhere")], activeID: "../../elsewhere"))
        f.defaults.set(data, forKey: CodexAccountStore.defaultsKey)
        let store = CodexAccountStore(defaults: f.defaults, root: f.store.root)
        XCTAssertEqual(store.library.accounts.map(\.id), ["local"])
        XCTAssertTrue(store.active.isLocal)
    }

    func testRemoveLogsOutOnlyInactiveManagedAccount() async throws {
        let f = try fixture(); defer { f.stop() }
        await f.store.addAccount(); try await settle(f.store)
        let target = try XCTUnwrap(f.store.library.accounts.last)
        await f.store.remove(f.store.active)
        XCTAssertEqual(f.store.library.accounts.count, 2)
        await f.store.remove(target)
        XCTAssertEqual(f.store.library.accounts.map(\.id), ["local"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(f.store.home(for: target)).path))
        let calls = try String(contentsOf: f.root.appendingPathComponent("calls.jsonl"))
        XCTAssertTrue(calls.contains("account/logout"))
    }
}
