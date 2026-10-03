import XCTest
@testable import CloudCodex

final class CreditUsageProtectionTests: XCTestCase {
    private func account(balance: String = "62417", used: Double = 20) -> AccountOverview {
        AccountOverview.parse(["rateLimits": [
            "limitId": "codex", "credits": ["balance": balance, "unlimited": false, "hasCredits": true],
            "primary": ["usedPercent": used, "windowDurationMins": 300]
        ]])
    }

    func testBalanceDecreaseLatchesUntilExplicitlyReset() {
        var protection = CreditUsageProtection()
        protection.observe(account(), allowsCredits: false)
        XCTAssertNil(protection.reason)
        protection.observe(account(balance: "62416.99"), allowsCredits: false)
        XCTAssertEqual(protection.reason, .balanceDecreased)
        protection.observe(account(balance: "62420"), allowsCredits: false)
        XCTAssertEqual(protection.reason, .balanceDecreased)
        protection.reset()
        protection.observe(account(balance: "62420"), allowsCredits: false)
        XCTAssertNil(protection.reason)
    }

    func testExhaustedIncludedQuotaStopsBeforeBalanceIsSpent() {
        var protection = CreditUsageProtection()
        protection.observe(account(used: 100), allowsCredits: false)
        XCTAssertEqual(protection.reason, .includedQuotaExhausted)
        XCTAssertFalse(CreditUsageProtection.hasKnownIncludedQuota(account(used: 100)))
        XCTAssertTrue(CreditUsageProtection.hasKnownIncludedQuota(account(used: 99.99)))
        XCTAssertFalse(CreditUsageProtection.hasKnownIncludedQuota(AccountOverview.parse([:])))
    }

    func testEnabledSwitchAllowsCreditUseAndDoesNotBlock() {
        var protection = CreditUsageProtection()
        protection.observe(account(), allowsCredits: false)
        protection.observe(account(balance: "1", used: 100), allowsCredits: true)
        XCTAssertNil(protection.reason)
    }

    @MainActor
    func testDefaultOffAndEveryRunningTurnIsInterruptedWithoutDeletingQueue() async throws {
        let suite = "CreditUsageProtectionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let interrupted = expectation(description: "Both turns interrupted")
        interrupted.expectedFulfillmentCount = 2
        var stopped: Set<String> = []
        let model = AppModel(remoteDefaults: defaults, creditTurnInterrupter: { threadID, turnID in
            stopped.insert("\(threadID):\(turnID)")
            interrupted.fulfill()
        })
        XCTAssertFalse(model.allowsExtraCreditUsage)
        for id in ["one", "two"] {
            model.handleEvent("turn/started", ["threadId": id, "turn": ["id": "turn-\(id)"]])
        }
        model.waitingMessages = [.init(threadID: "one", text: "keep me", attachments: [],
            model: nil, effort: nil, permissions: nil, serviceTier: nil)]
        model.observeCreditUsage(account())
        model.observeCreditUsage(account(balance: "62416"))
        XCTAssertEqual(model.creditUsagePauseReason, .balanceDecreased)
        await model.deliverWaitingMessage(model.waitingMessages[0].id, steer: false)
        await fulfillment(of: [interrupted], timeout: 2)
        XCTAssertEqual(stopped, ["one:turn-one", "two:turn-two"])
        XCTAssertEqual(model.waitingMessages.first?.text, "keep me")
        XCTAssertTrue(model.creditUsagePauseFailures.isEmpty)
        let restored = AppModel(remoteDefaults: defaults)
        XCTAssertEqual(restored.creditUsagePauseReason, .balanceDecreased)
        XCTAssertFalse(restored.allowsExtraCreditUsage)
        restored.setAllowsExtraCreditUsage(true)
        XCTAssertNil(restored.creditUsagePauseReason)
        XCTAssertTrue(AppModel(remoteDefaults: defaults).allowsExtraCreditUsage)
    }

    @MainActor
    func testUnavailableUsageAllowsSubmissionAndKnownExhaustionStillBlocks() async throws {
        let suite = "CreditUsageProtectionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var response: AccountOverview?
        let model = AppModel(remoteDefaults: defaults, creditUsageReader: {
            guard let response else { throw CodexClientError.notRunning }
            return response
        })
        try await model.checkCreditUsageBeforeSubmission()
        XCTAssertNil(model.creditUsagePauseReason)
        XCTAssertNotNil(model.accountOverviewError)
        response = AccountOverview.parse([:])
        try await model.checkCreditUsageBeforeSubmission()
        XCTAssertNil(model.creditUsagePauseReason)
        await model.recheckIncludedQuota()
        XCTAssertNil(model.creditUsagePauseReason)
        response = account(used: 100)
        await model.recheckIncludedQuota()
        XCTAssertEqual(model.creditUsagePauseReason, .includedQuotaExhausted)
        response = nil
        do {
            try await model.checkCreditUsageBeforeSubmission()
            XCTFail("Confirmed exhaustion must stay blocked even when the reader is unavailable")
        } catch { XCTAssertTrue(error is CreditUsageBlocked) }
        XCTAssertEqual(model.creditUsagePauseReason, .includedQuotaExhausted)
        response = account(used: 20)
        await model.recheckIncludedQuota()
        XCTAssertNil(model.creditUsagePauseReason)
        try await model.checkCreditUsageBeforeSubmission()
    }

    @MainActor
    func testUnavailableBackgroundRefreshDoesNotInterruptRunningTurn() async throws {
        for response in [nil, AccountOverview.parse([:])] as [AccountOverview?] {
            let suite = "CreditUsageProtectionTests.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let refreshed = expectation(description: "Background quota refresh")
            var interrupted = false
            let model = AppModel(remoteDefaults: defaults, creditUsageReader: {
                defer { refreshed.fulfill() }
                guard let response else { throw CodexClientError.notRunning }
                return response
            }, creditTurnInterrupter: { _, _ in interrupted = true })
            model.handleEvent("turn/started", ["threadId": "one", "turn": ["id": "turn-one"]])
            model.handleEvent("account/rateLimits/updated", [:])
            await fulfillment(of: [refreshed], timeout: 2)
            XCTAssertNil(model.creditUsagePauseReason)
            XCTAssertFalse(interrupted)
        }
    }

    @MainActor
    func testLegacyUnavailablePauseIsClearedOnStartup() throws {
        let suite = "CreditUsageProtectionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let previous = AppModel(remoteDefaults: defaults)
        previous.waitingMessages = [
            .init(threadID: "one", text: "keep me", attachments: [], model: nil,
                  effort: nil, permissions: nil, serviceTier: nil,
                  error: CreditUsageProtection.Reason.usageUnavailable.message)
        ]
        defaults.set("usageUnavailable", forKey: "cloudcodex.creditUsagePause.v1")
        let model = AppModel(remoteDefaults: defaults)
        XCTAssertFalse(model.allowsExtraCreditUsage)
        XCTAssertNil(model.creditUsagePauseReason)
        XCTAssertNil(defaults.string(forKey: "cloudcodex.creditUsagePause.v1"))
        XCTAssertEqual(model.waitingMessages.first?.text, "keep me")
        XCTAssertNil(model.waitingMessages.first?.error)
    }

    @MainActor
    func testSubmissionGateProtectsStartAndSteerBeforeAnyTransportRequest() async {
        let client = AppServerClient()
        var checked = 0
        client.beforeTurnSubmission = {
            checked += 1
            throw CreditUsageBlocked(reason: .includedQuotaExhausted)
        }
        do {
            _ = try await client.startTurn(threadID: "one", text: "test", attachments: [],
                model: nil, effort: nil, permissions: nil, serviceTier: nil)
            XCTFail("Must not start")
        } catch { XCTAssertTrue(error is CreditUsageBlocked) }
        do {
            try await client.steerTurn(threadID: "one", turnID: "turn-one", text: "test", attachments: [])
            XCTFail("Must not steer")
        } catch { XCTAssertTrue(error is CreditUsageBlocked) }
        XCTAssertEqual(checked, 2)
        XCTAssertTrue(AppModel.shouldDeferRemoteTask(CreditUsageBlocked(reason: .balanceDecreased)))
    }

    @MainActor
    func testInterruptionFailureRemainsVisible() async throws {
        let suite = "CreditUsageProtectionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let failed = expectation(description: "Interrupt attempted")
        let model = AppModel(remoteDefaults: defaults, creditTurnInterrupter: { _, _ in
            failed.fulfill()
            throw CodexClientError.notRunning
        })
        model.handleEvent("turn/started", ["threadId": "one", "turn": ["id": "turn-one"]])
        model.observeCreditUsage(account(used: 100))
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertNotNil(model.creditUsagePauseFailures["one"])
        XCTAssertNotNil(model.creditUsagePauseReason)
    }
}
