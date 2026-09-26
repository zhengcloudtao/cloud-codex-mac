import XCTest
@testable import CloudCodex

final class CodexEventNotifierTests: XCTestCase {
    private func account(sessionUsed: Double?, weeklyUsed: Double = 50) -> AccountOverview {
        let session: [String: Any] = [
            "usedPercent": sessionUsed as Any,
            "windowDurationMins": 300
        ]
        return AccountOverview.parse([
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": session,
                    "secondary": [
                        "usedPercent": weeklyUsed,
                        "windowDurationMins": 10_080
                    ]
                ]
            ]
        ])
    }

    func testQuotaNotificationOnlyFiresOnNonFullToFullSessionEdge() {
        XCTAssertFalse(CodexEventNotifier.shouldNotifyQuotaUpdated(
            previous: nil,
            current: account(sessionUsed: 0)
        ))
        XCTAssertTrue(CodexEventNotifier.shouldNotifyQuotaUpdated(
            previous: account(sessionUsed: 25),
            current: account(sessionUsed: 0)
        ))
        XCTAssertFalse(CodexEventNotifier.shouldNotifyQuotaUpdated(
            previous: account(sessionUsed: 0),
            current: account(sessionUsed: 0)
        ))
        XCTAssertFalse(CodexEventNotifier.shouldNotifyQuotaUpdated(
            previous: account(sessionUsed: 25),
            current: account(sessionUsed: 10)
        ))
        XCTAssertFalse(CodexEventNotifier.shouldNotifyQuotaUpdated(
            previous: account(sessionUsed: nil),
            current: account(sessionUsed: 0)
        ))
    }

    func testWeeklyResetDoesNotTriggerSessionNotification() {
        XCTAssertFalse(CodexEventNotifier.shouldNotifyQuotaUpdated(
            previous: account(sessionUsed: 40, weeklyUsed: 80),
            current: account(sessionUsed: 40, weeklyUsed: 0)
        ))
    }

    func testNotificationEndpoints() {
        XCTAssertEqual(
            CodexEventNotifier.quotaUpdatedEndpoint.path,
            "/szpu/system/codexUpdateQuota"
        )
        XCTAssertEqual(
            CodexEventNotifier.conversationCompletedEndpoint.path,
            "/szpu/system/codexConversationCompleted"
        )
    }

    func testNotifierSendsGETToTheEndpointForEachEvent() async {
        NotificationFixtureProtocol.paths = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NotificationFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let notifier = CodexEventNotifier(session: session)

        await notifier.notify(.quotaUpdated)
        await notifier.notify(.conversationCompleted)

        XCTAssertEqual(NotificationFixtureProtocol.paths, [
            "/szpu/system/codexUpdateQuota",
            "/szpu/system/codexConversationCompleted"
        ])
    }
}

private final class NotificationFixtureProtocol: URLProtocol {
    nonisolated(unsafe) static var paths: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        Self.paths.append(request.url?.path ?? "")
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
