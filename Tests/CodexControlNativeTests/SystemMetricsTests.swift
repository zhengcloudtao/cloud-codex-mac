import XCTest
@testable import CloudCodex

final class SystemMetricsTests: XCTestCase {
    func testStoragePercentageAndUnknownValues() {
        let known = SystemMetricsSnapshot(cpuUsagePercent: 42, storageUsedBytes: 25, storageTotalBytes: 100,
                                          temperatureCelsius: 31, temperatureSource: "battery", capturedAt: 1)
        XCTAssertEqual(known.storageUsedPercent, 25)
        XCTAssertTrue(known.hasValues)

        let unknown = SystemMetricsSnapshot(cpuUsagePercent: nil, storageUsedBytes: nil, storageTotalBytes: nil,
                                            temperatureCelsius: nil, temperatureSource: nil, capturedAt: 1)
        XCTAssertNil(unknown.storageUsedPercent)
        XCTAssertFalse(unknown.hasValues)
    }

    func testRefreshIntervalChoicesAndInvalidStoredValueFallback() {
        XCTAssertEqual(SystemMetricsRefreshInterval.allCases.map(\.rawValue), [1, 2, 5, 10, 30, 60])
        XCTAssertEqual(SystemMetricsRefreshInterval.resolved(10), .tenSeconds)
        XCTAssertEqual(SystemMetricsRefreshInterval.resolved(7), .fiveSeconds)
    }

    func testAppleSiliconSensorClassificationDoesNotConfuseBatteryWithCPU() {
        XCTAssertTrue(AppleSiliconTemperatureReader.isCPUSensor("pACC MTR Temp Sensor4"))
        XCTAssertTrue(AppleSiliconTemperatureReader.isCPUSensor("PMU tdie4"))
        XCTAssertTrue(AppleSiliconTemperatureReader.isSoCSensor("PMGR SOC Die Temp Sensor0"))
        XCTAssertFalse(AppleSiliconTemperatureReader.isCPUSensor("AppleSmartBattery"))
    }

    func testChipTemperatureUsesHottestTrustedCPUOrSoCSensor() throws {
        let reading = try XCTUnwrap(AppleSiliconTemperatureReader.selectChipTemperature([
            (name: "pACC MTR Temp Sensor4", value: 68),
            (name: "SOC MTR Temp Sensor2", value: 84),
            (name: "gas gauge battery", value: 92),
            (name: "NAND CH0 temp", value: 89)
        ]))
        XCTAssertEqual(reading, .init(value: 84, source: "soc_hid"))
    }

    func testAppleSiliconSMCKeyClassificationExcludesOtherThermalDomains() {
        XCTAssertTrue(AppleSMCTemperatureReader.isAppleSiliconCPUKey("Te05"))
        XCTAssertTrue(AppleSMCTemperatureReader.isAppleSiliconCPUKey("Tp0Y"))
        XCTAssertFalse(AppleSMCTemperatureReader.isAppleSiliconCPUKey("Tg0f"))
        XCTAssertFalse(AppleSMCTemperatureReader.isAppleSiliconCPUKey("Ts0K"))
        XCTAssertFalse(AppleSMCTemperatureReader.isAppleSiliconCPUKey("TB1T"))
    }

    func testHeartbeatEncodesOptionalSystemMetricsWithoutChangingOldPayloads() throws {
        let body = RemoteHeartbeatBody(name: "Mac", permissionLabel: "full", remoteControlReady: true,
                                       workspaces: [], threads: [], systemMetrics: .init(
                                        cpuUsagePercent: 12.5, storageUsedBytes: 40, storageTotalBytes: 100,
                                        temperatureCelsius: 30.5, temperatureSource: "battery", capturedAt: 123))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        let metrics = try XCTUnwrap(object["systemMetrics"] as? [String: Any])
        XCTAssertEqual(metrics["cpuUsagePercent"] as? Double, 12.5)
        XCTAssertEqual(metrics["temperatureSource"] as? String, "battery")

        let legacy = RemoteHeartbeatBody(name: "Mac", permissionLabel: "full", remoteControlReady: true,
                                         workspaces: [], threads: [])
        let legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertNil(legacyObject["systemMetrics"])
        XCTAssertNil(legacyObject["connectionHealth"])
    }

    func testHeartbeatEncodesSanitizedConnectionHealthSnapshot() throws {
        let health = RemoteConnectionHealthSnapshot(networkState: "connected", gptState: "failed",
                                                    failureKind: "timeout", checkedAt: 120, capturedAt: 123)
        let body = RemoteHeartbeatBody(name: "Mac", permissionLabel: "full", remoteControlReady: true,
                                       workspaces: [], threads: [], connectionHealth: health)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any])
        let encoded = try XCTUnwrap(object["connectionHealth"] as? [String: Any])
        XCTAssertEqual(encoded["networkState"] as? String, "connected")
        XCTAssertEqual(encoded["gptState"] as? String, "failed")
        XCTAssertEqual(encoded["failureKind"] as? String, "timeout")
        XCTAssertNil(encoded["detail"])
    }

    func testConnectionFailureClassificationDoesNotExposeRawErrors() {
        XCTAssertEqual(RemoteConnectionHealthSnapshot.failureKind(for: "401 Unauthorized token_revoked"), "auth")
        XCTAssertEqual(RemoteConnectionHealthSnapshot.failureKind(for: "request timed out"), "timeout")
        XCTAssertEqual(RemoteConnectionHealthSnapshot.failureKind(for: "method not supported"), "unsupported")
        XCTAssertEqual(RemoteConnectionHealthSnapshot.failureKind(for: "unexpected response"), "unknown")
    }

    @MainActor
    func testLiveSamplerReadsCurrentVolumeWithoutRequiringTemperatureHardware() async {
        let monitor = SystemMetricsMonitor()
        await monitor.sample()
        XCTAssertNotNil(monitor.snapshot.storageTotalBytes)
        XCTAssertNotNil(monitor.snapshot.storageUsedBytes)
        XCTAssertGreaterThan(monitor.snapshot.storageTotalBytes ?? 0, 0)
    }

    @MainActor
    func testSlowHardwareReadLeavesMainActorResponsiveAndCoalescesRefreshes() async {
        let entered = expectation(description: "background hardware read")
        let gate = DispatchSemaphore(value: 0)
        let sampler = SystemMetricsSampler(read: {
            XCTAssertFalse(Thread.isMainThread)
            entered.fulfill()
            _ = gate.wait(timeout: .now() + 5)
            return .init(cpuUsagePercent: 42, storageUsedBytes: 25, storageTotalBytes: 100,
                         temperatureCelsius: nil, temperatureSource: nil, capturedAt: 123)
        })
        let monitor = SystemMetricsMonitor(sampler: sampler)
        let first = Task { await monitor.sample() }
        await fulfillment(of: [entered], timeout: 2)
        // This code runs on the main actor while the hardware reader is blocked.
        XCTAssertNil(monitor.snapshot.storageTotalBytes)
        await monitor.sample() // Must return without starting a duplicate read.
        gate.signal()
        await first.value
        XCTAssertEqual(monitor.snapshot.capturedAt, 123)
        XCTAssertEqual(monitor.snapshot.cpuUsagePercent, 42)
    }

    func testOptionalLiveAppleSiliconChipTemperature() throws {
        guard ProcessInfo.processInfo.environment["CLOUDCODEX_VERIFY_LIVE_TEMPERATURE"] == "1" else {
            throw XCTSkip("Opt-in live Apple Silicon temperature check")
        }
        let reading = try XCTUnwrap(AppleSiliconTemperatureReader.readChipTemperature())
        XCTAssertTrue((0..<110).contains(reading.value))
        XCTAssertTrue(["cpu_hid", "soc_hid"].contains(reading.source))
        print("CloudCodex live chip temperature: \(reading.value) C (\(reading.source))")
    }

    func testOptionalLiveAppleSMCCPUTemperature() throws {
        guard ProcessInfo.processInfo.environment["CLOUDCODEX_VERIFY_LIVE_TEMPERATURE"] == "1" else {
            throw XCTSkip("Opt-in live AppleSMC CPU temperature check")
        }
        let reading = try XCTUnwrap(AppleSMCTemperatureReader.readCPUAverage())
        XCTAssertTrue((20..<110).contains(reading.value))
        XCTAssertGreaterThan(reading.sensorCount, 0)
        print("CloudCodex live AppleSMC CPU temperature: \(reading.value) C (\(reading.sensorCount) sensors)")
    }
}
