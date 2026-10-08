import XCTest
@testable import CloudCodex

final class AccountRefreshIntervalTests: XCTestCase {
    func testMissingAndInvalidPreferencesFallBackToOneMinute() throws {
        let suite = "AccountRefreshIntervalTests.defaults.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(AccountRefreshInterval.load(from: defaults), .oneMinute)
        for value in [-1, 0, 7, 61, 3_600] {
            defaults.set(value, forKey: AccountRefreshInterval.storageKey)
            XCTAssertEqual(AccountRefreshInterval.load(from: defaults), .oneMinute)
        }
        defaults.set("invalid", forKey: AccountRefreshInterval.storageKey)
        XCTAssertEqual(AccountRefreshInterval.load(from: defaults), .oneMinute)

        for interval in AccountRefreshInterval.allCases {
            defaults.set(interval.rawValue, forKey: AccountRefreshInterval.storageKey)
            XCTAssertEqual(AccountRefreshInterval.load(from: defaults), interval)
        }
    }

    @MainActor
    func testPreferencePersistsAndRestoresTheSamePollingInterval() throws {
        let suite = "AccountRefreshIntervalTests.model.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let model = AppModel(remoteDefaults: defaults)
        XCTAssertEqual(model.accountRefreshInterval, .oneMinute)
        XCTAssertEqual(model.connectionHealth.refreshInterval, .oneMinute)

        model.setAccountRefreshInterval(.fiveMinutes)
        XCTAssertEqual(model.accountRefreshInterval, .fiveMinutes)
        XCTAssertEqual(model.connectionHealth.refreshInterval, .fiveMinutes)
        XCTAssertEqual(defaults.integer(forKey: AccountRefreshInterval.storageKey), 300)

        let restored = AppModel(remoteDefaults: defaults)
        XCTAssertEqual(restored.accountRefreshInterval, .fiveMinutes)
        XCTAssertEqual(restored.connectionHealth.refreshInterval, .fiveMinutes)

        defaults.set(17, forKey: AccountRefreshInterval.storageKey)
        let invalidPreference = AppModel(remoteDefaults: defaults)
        XCTAssertEqual(invalidPreference.accountRefreshInterval, .oneMinute)
        XCTAssertEqual(invalidPreference.connectionHealth.refreshInterval, .oneMinute)
    }

    @MainActor
    func testChangingIntervalBeforeStartDoesNotStartPolling() async {
        let unexpectedSleep = expectation(description: "No polling before start")
        unexpectedSleep.isInverted = true
        let health = ConnectionHealth(sleep: { _ in
            unexpectedSleep.fulfill()
            throw CancellationError()
        })

        health.setRefreshInterval(.twoMinutes)
        XCTAssertEqual(health.refreshInterval, .twoMinutes)
        await fulfillment(of: [unexpectedSleep], timeout: 0.05)
    }

    @MainActor
    func testChangingIntervalRestartsPollingAndCancelsTheOldWait() async {
        let initialSleep = expectation(description: "Initial polling wait")
        let changedSleep = expectation(description: "Polling wait uses changed interval")
        let oldSleepCancelled = expectation(description: "Previous polling wait cancelled")
        let unexpectedRestart = expectation(description: "Same interval does not restart polling")
        unexpectedRestart.isInverted = true
        var requestedIntervals: [TimeInterval] = []
        var health: ConnectionHealth? = ConnectionHealth(sleep: { seconds in
            let index = requestedIntervals.count
            requestedIntervals.append(seconds)
            switch index {
            case 0: initialSleep.fulfill()
            case 1: changedSleep.fulfill()
            default: unexpectedRestart.fulfill()
            }
            do {
                // The test cancels this wait; it never waits for a real refresh interval.
                try await Task.sleep(nanoseconds: 60_000_000_000)
            } catch {
                if index == 0 { oldSleepCancelled.fulfill() }
                throw error
            }
        })
        defer { health = nil }

        health?.setRefreshInterval(.twoMinutes)
        // An empty probe avoids any account request, including on network updates.
        health?.start(probe: {})
        await fulfillment(of: [initialSleep], timeout: 1)
        XCTAssertEqual(requestedIntervals, [120])

        health?.setRefreshInterval(.tenSeconds)
        await fulfillment(of: [changedSleep, oldSleepCancelled], timeout: 1)
        XCTAssertEqual(requestedIntervals, [120, 10])
        XCTAssertEqual(health?.refreshInterval, .tenSeconds)

        health?.setRefreshInterval(.tenSeconds)
        await fulfillment(of: [unexpectedRestart], timeout: 0.05)
        XCTAssertEqual(requestedIntervals, [120, 10])
    }
}
