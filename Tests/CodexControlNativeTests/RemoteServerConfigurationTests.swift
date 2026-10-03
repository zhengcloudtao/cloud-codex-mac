import XCTest
@testable import CloudCodex

final class RemoteServerConfigurationTests: XCTestCase {
    func testHTTPSAddressValidationAndNormalization() throws {
        let value = RemoteServerConfiguration(mode: .custom, customAddress: "  HTTPS://Relay.Example.invalid:443/prefix/  ")
        XCTAssertEqual(try value.validatedURL().absoluteString, "https://relay.example.invalid/prefix")
        for address in ["", "relay.example.invalid", "http://relay.example.invalid", "https://user:password@relay.example.invalid",
                        "https://relay.example.invalid?token=bad", "https://relay.example.invalid/#fragment",
                        "https://relay.example.invalid/a/../b", "https://relay.example.invalid/%2e%2e", "https://relay.example.invalid:70000"] {
            XCTAssertThrowsError(try RemoteServerConfiguration(mode: .custom, customAddress: address).validatedURL(), address)
        }
    }

    func testLegacyIdentityIsPreservedAndCustomIdentitiesAreSeparated() throws {
        let suite = "RemoteServer.tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("existing-device", forKey: "CloudCodex.remoteControl.deviceID.v1")
        let original = RemoteControlAPI(deviceSecret: "fixture-only", defaults: defaults)
        XCTAssertEqual(original.deviceID, "existing-device")
        XCTAssertEqual(RemoteServerConfiguration.credentialAccount(for: RemoteControlAPI.defaultBaseURL), "remote-control-device-secret-v1")
        let a = URL(string: "https://a.example.invalid/prefix")!
        let b = URL(string: "https://b.example.invalid/prefix")!
        let first = RemoteControlAPI(deviceSecret: "fixture-a", baseURL: a, defaults: defaults)
        let second = RemoteControlAPI(deviceSecret: "fixture-b", baseURL: b, defaults: defaults)
        XCTAssertNotEqual(first.deviceID, original.deviceID)
        XCTAssertNotEqual(first.deviceID, second.deviceID)
        XCTAssertEqual(RemoteControlAPI(deviceSecret: "fixture-a", baseURL: a, defaults: defaults).deviceID, first.deviceID)
        XCTAssertNotEqual(RemoteServerConfiguration.credentialAccount(for: a), RemoteServerConfiguration.credentialAccount(for: b))
        XCTAssertNotEqual(RemoteServerConfiguration.scope(for: a), RemoteServerConfiguration.scope(for: a.appendingPathComponent("other")))
        XCTAssertEqual(RemoteServerConfiguration.scope(for: a), RemoteServerConfiguration.scope(for: URL(string: "https://A.example.invalid:443/prefix/")!))
    }

    @MainActor
    func testConfigurationPersistsAndCannotChangeWhileEnabled() async throws {
        let suite = "RemoteServer.tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppModel(remoteDefaults: defaults, remoteAPILoader: { _ in throw RemoteCredentialError.authorizationRequired })
        let custom = RemoteServerConfiguration(mode: .custom, customAddress: "https://relay.example.invalid/prefix/")
        XCTAssertTrue(app.saveRemoteServerConfiguration(custom))
        XCTAssertEqual(app.remoteServerConfiguration.customAddress, "https://relay.example.invalid/prefix")
        XCTAssertEqual(AppModel(remoteDefaults: defaults).remoteServerConfiguration, app.remoteServerConfiguration)
        app.setRemoteControlEnabled(true)
        XCTAssertFalse(app.saveRemoteServerConfiguration(.init()))
        for _ in 0..<100 where app.isLoadingRemoteCredential { try await Task.sleep(nanoseconds: 1_000_000) }
        app.setRemoteControlEnabled(false)
        XCTAssertTrue(app.saveRemoteServerConfiguration(.init()))
        XCTAssertNil(app.remoteCredentialIssue)
        XCTAssertFalse(app.remoteControlPaired)
        XCTAssertTrue(app.remotePairingCode.isEmpty)
    }

    @MainActor
    func testBrokenOrInvalidSavedConfigNeverFallsBackToBuiltIn() throws {
        let suite = "RemoteServer.tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("invalid-json".utf8), forKey: RemoteServerConfiguration.defaultsKey)
        let app = AppModel(remoteDefaults: defaults)
        XCTAssertEqual(app.remoteServerConfiguration.mode, .custom)
        app.setRemoteControlEnabled(true)
        XCTAssertFalse(app.remoteControlEnabled)
        XCTAssertNotNil(app.remoteServerConfigurationError)
        XCTAssertFalse(app.isLoadingRemoteCredential)
        XCTAssertFalse(app.saveRemoteServerConfiguration(.init(mode: .custom, customAddress: "http://bad.example.invalid")))
        XCTAssertEqual(defaults.data(forKey: RemoteServerConfiguration.defaultsKey), Data("invalid-json".utf8))
    }

    @MainActor
    func testSwitchingIsBlockedUntilAnInFlightCredentialLoadEnds() async throws {
        let suite = "RemoteServer.tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = AppModel(remoteDefaults: defaults, remoteAPILoader: { _ in
            try await Task.sleep(nanoseconds: 20_000_000)
            throw RemoteCredentialError.cancelled
        })
        app.setRemoteControlEnabled(true)
        app.setRemoteControlEnabled(false)
        let target = RemoteServerConfiguration(mode: .custom, customAddress: "https://relay.example.invalid")
        XCTAssertFalse(app.canChangeRemoteServer)
        XCTAssertFalse(app.saveRemoteServerConfiguration(target))
        for _ in 0..<100 where app.isLoadingRemoteCredential { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(app.saveRemoteServerConfiguration(target))
        XCTAssertNil(app.remoteCredentialIssue)
    }

    func testCopyableGuideContainsConfiguredPrefixAndCompleteAgentProtocol() throws {
        let config = RemoteServerConfiguration(mode: .custom, customAddress: "https://relay.example.invalid/prefix")
        let guide = try RemoteIntegrationGuide.document(configuration: config)
        XCTAssertTrue(guide.contains("服务根地址：https://relay.example.invalid/prefix"))
        XCTAssertFalse(guide.contains(RemoteControlAPI.defaultBaseURL.absoluteString))
        for path in ["register", "heartbeat", "tasks/next", "tasks/{taskId}/status", "unpair", "history/next", "history/{id}", "resets/next", "resets/{id}", "events"] {
            XCTAssertTrue(guide.contains("/api/cloud-codex/agent/" + path), path)
        }
        XCTAssertTrue(guide.contains("data=null"))
        XCTAssertTrue(guide.contains("cloudcodex://pair?v=1&code=12345678"))
        XCTAssertThrowsError(try RemoteIntegrationGuide.document(configuration: .init(mode: .custom)))
    }

    func testSelfHostedGuideNeverIncludesBuiltInRelayDomain() throws {
        let builtInHost = try XCTUnwrap(RemoteControlAPI.defaultBaseURL.host)
        let configurations = [
            RemoteServerConfiguration(),
            RemoteServerConfiguration(mode: .builtIn, customAddress: "https://ignored.example.invalid"),
            RemoteServerConfiguration(mode: .custom, customAddress: RemoteControlAPI.defaultBaseURL.absoluteString + "/"),
            RemoteServerConfiguration(mode: .custom, customAddress: "https://API.CLOUDSLOW.COM:443/ai/")
        ]
        for configuration in configurations {
            let document = try RemoteIntegrationGuide.document(configuration: configuration)
            XCTAssertTrue(document.contains("服务根地址：<填写你自己的 HTTPS 后端根地址>"))
            XCTAssertFalse(document.lowercased().contains(builtInHost))
            XCTAssertFalse(document.contains("ignored.example.invalid"))
        }
    }

    func testCustomBasePrefixAndAllAgentCallsUseSameScopedDevice() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CustomRelayFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let suite = "RemoteServer.tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let api = RemoteControlAPI(deviceSecret: "fixture-only", baseURL: URL(string: "https://relay.example.invalid/prefix")!, session: session, defaults: defaults)
        let registered = try await api.register()
        XCTAssertEqual(registered.deviceId, api.deviceID)
        let heartbeat = try await api.heartbeat(.init(name: "test", permissionLabel: "test", remoteControlReady: true, workspaces: [], threads: []))
        XCTAssertTrue(heartbeat.paired)
        let next = try await api.nextTask()
        XCTAssertNil(next)
        let history = try await api.nextHistory()
        XCTAssertNil(history)
        let reset = try await api.nextReset()
        XCTAssertNil(reset)
        try await api.updateTask("task-1", body: .init(status: "completed", threadId: "thread", turnId: "turn", result: "fixture", error: ""))
        try await api.finishHistory("read-1", body: .init(page: nil, error: "fixture"))
        try await api.finishReset("reset-1", status: "failed")
        try await api.unpair()
    }

    func testDeviceRequestsRejectRedirects() {
        let url = URL(string: "https://relay.example.invalid")!
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://other.example.invalid"])!
        RemoteRelayRedirectPolicy().urlSession(session, task: session.dataTask(with: url), willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://other.example.invalid")!)) { XCTAssertNil($0) }
    }

    @MainActor
    func testPendingReportsCannotCrossServiceAddresses() throws {
        let suite = "RemoteServer.tests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let a = RemoteControlAPI(deviceSecret: "fixture-a", baseURL: URL(string: "https://a.example.invalid")!, defaults: defaults)
        let b = RemoteControlAPI(deviceSecret: "fixture-b", baseURL: URL(string: "https://b.example.invalid")!, defaults: defaults)
        let outbox = RemoteStatusOutbox(defaults: defaults)
        let body = RemoteTaskStatusBody(status: "completed", threadId: "thread", turnId: "turn", result: "fixture", error: "")
        outbox.enqueue(deviceID: a.deviceID, taskID: "task", body: body)
        XCTAssertTrue(outbox.pending(deviceID: b.deviceID).isEmpty)
        let restoredA = RemoteControlAPI(deviceSecret: "fixture-a", baseURL: URL(string: "https://a.example.invalid")!, defaults: defaults)
        XCTAssertEqual(RemoteStatusOutbox(defaults: defaults).pending(deviceID: restoredA.deviceID)["task"], body)
    }
}

private final class CustomRelayFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.host, "relay.example.invalid")
        let path = request.url!.path
        XCTAssertTrue(path.hasPrefix("/prefix/api/cloud-codex/agent/"))
        XCTAssertEqual(request.httpMethod, path.hasSuffix("/next") ? "GET" : "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-CloudCodex-Token"), "fixture-only")
        XCTAssertFalse((request.value(forHTTPHeaderField: "X-CloudCodex-Device") ?? "").isEmpty)
        var value: [String: Any] = ["status": 0, "msg": "ok", "data": NSNull()]
        if path.hasSuffix("/register") {
            value["data"] = ["deviceId": request.value(forHTTPHeaderField: "X-CloudCodex-Device")!, "name": "fixture", "paired": false, "pairingCode": "12345678", "pairingExpiresAt": "2030-01-01T00:00:00Z", "pollIntervalSeconds": 3] as [String: Any]
        } else if path.hasSuffix("/heartbeat") { value["data"] = ["paired": true] }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: value))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
