import XCTest
@testable import CloudCodex

@MainActor
final class RemoteCredentialLifecycleTests: XCTestCase {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "CloudCodex.credentials.tests.\(UUID())")! }

    func testConstructionDoesNotReadKeychainEvenWithRemoteEnabled() async {
        let prefs = defaults()
        prefs.set(true, forKey: "CloudCodex.remoteControl.enabled.v1")
        let loader = CredentialLoaderProbe()
        let model = AppModel(remoteDefaults: prefs, remoteAPILoader: { try await loader.load($0) })
        XCTAssertTrue(model.remoteControlEnabled)
        let calls = await loader.calls
        XCTAssertEqual(calls, [])
        XCTAssertFalse(model.isLoadingRemoteCredential)
    }

    func testAutomaticFailureIsLatchedAcrossRepeatedEnableAndDisable() async {
        let loader = CredentialLoaderProbe()
        let model = AppModel(remoteDefaults: defaults(), remoteAPILoader: { try await loader.load($0) })
        model.setRemoteControlEnabled(true)
        for _ in 0..<10 { model.setRemoteControlEnabled(true) }
        await waitForLoad(model)
        XCTAssertNotNil(model.remoteCredentialIssue)
        model.setRemoteControlEnabled(false)
        model.setRemoteControlEnabled(true)
        await waitForLoad(model)
        let calls = await loader.calls
        XCTAssertEqual(calls, [false])
        model.setRemoteControlEnabled(false)
    }

    func testOnlyExplicitActionRequestsInteractionAndCancelDoesNotRetry() async {
        let loader = CredentialLoaderProbe()
        let model = AppModel(remoteDefaults: defaults(), remoteAPILoader: { try await loader.load($0) })
        model.setRemoteControlEnabled(true)
        await waitForLoad(model)
        model.authorizeRemoteControl()
        model.authorizeRemoteControl()
        await waitForLoad(model)
        XCTAssertEqual(model.remoteCredentialIssue, RemoteCredentialError.cancelled.localizedDescription)
        model.setRemoteControlEnabled(true)
        let calls = await loader.calls
        XCTAssertEqual(calls, [false, true])
        model.setRemoteControlEnabled(false)
    }

    func testSwitchOffWhileLoadingDoesNotConnectWhenCredentialArrives() async {
        let loader = CredentialLoaderProbe(succeed: true)
        let model = AppModel(remoteDefaults: defaults(), remoteAPILoader: { try await loader.load($0) })
        model.setRemoteControlEnabled(true)
        model.setRemoteControlEnabled(false)
        await waitForLoad(model)
        XCTAssertEqual(model.remoteControlStatus, "远程控制已关闭")
        XCTAssertFalse(model.remoteControlEnabled)
        // Re-enabling reuses the cached client. No real network is opened as
        // this model has not connected to a local app-server.
        model.setRemoteControlEnabled(true)
        XCTAssertEqual(model.remoteControlStatus, "等待连接本机 Codex…")
        let calls = await loader.calls
        XCTAssertEqual(calls, [false])
        // Do not invoke disable here: it intentionally sends an offline heartbeat.
    }

    private func waitForLoad(_ model: AppModel) async {
        for _ in 0..<100 where model.isLoadingRemoteCredential {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertFalse(model.isLoadingRemoteCredential)
    }
}

private actor CredentialLoaderProbe {
    var calls: [Bool] = []
    let succeed: Bool
    init(succeed: Bool = false) { self.succeed = succeed }
    func load(_ interactive: Bool) throws -> RemoteControlAPI {
        calls.append(interactive)
        if !succeed { throw interactive ? RemoteCredentialError.cancelled : .authorizationRequired }
        return RemoteControlAPI(deviceSecret: "test-fixture-only",
                                baseURL: URL(string: "https://example.invalid")!,
                                defaults: UserDefaults(suiteName: "CloudCodex.credentials.tests.\(UUID())")!)
    }
}
