import XCTest
import CoreImage
@testable import CloudCodex

final class CloudCodexWatchTests: XCTestCase {
    func testHardwareBindingUsesReadOnlyLegacyFormat() throws {
        let fixture = WatchConnectionCode(version: 1, server: "https://relay.example.invalid/prefix",
            deviceId: "fixture-computer", token: String(repeating: "x", count: 43), expiresAt: 2000000000)
        let code = "CCW1." + (try JSONEncoder().encode(fixture)).base64EncodedString()
        let decoded = try XCTUnwrap(Data(base64Encoded: String(code.dropFirst(5))))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: decoded) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["deviceId"] as? String, "fixture-computer")
        XCTAssertNil(json["controlToken"])
    }

    @MainActor func testHardwareOptInPublishesSnapshotWithoutWatch() throws {
        let suite = "CloudCodexHardwareTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(remoteDefaults: defaults)
        XCTAssertNil(model.makeRemoteHeartbeat(ready: true).watchSnapshot)
        defaults.set(true, forKey: "CloudCodex.hardwareSharing.v1.")
        XCTAssertNotNil(model.makeRemoteHeartbeat(ready: true).watchSnapshot)
        XCTAssertFalse(model.watchSharingEnabled)
    }

    func testWatchBindingQRCodeRoundTrip() throws {
        let fixture = WatchConnectionCode(version: 2, server: "https://relay.example.invalid/prefix", deviceId: "fixture-mac", token: String(repeating: "x", count: 43), expiresAt: 2000000000, controlToken: String(repeating: "c", count: 43))
        let payload = "CCA1." + (try JSONEncoder().encode(fixture)).base64EncodedString()
        let image = try XCTUnwrap(RemotePairingQRCode.image(payload: payload))
        let data = try XCTUnwrap(image.tiffRepresentation)
        let input = try XCTUnwrap(CIImage(data: data))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        let result = detector.features(in: input).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
        XCTAssertEqual(result, [payload])
    }

    @MainActor func testWatchOptInIsScopedAndSnapshotDoesNotDependOnSidebar() throws {
        let suite = "CloudCodexWatchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(remoteDefaults: defaults)
        model.folderCatalog = [WorkspaceFolder(path: "/project", latestUpdate: .now)]
        let threads = try ["active", "idle"].enumerated().map { index, status in
            try XCTUnwrap(CodexThread(json: ["id": "t\(index)", "cwd": "/project", "name": "Task \(index)", "status": status]))
        }
        model.applyRemoteSchedulingSnapshot(threads)
        XCTAssertNil(model.makeRemoteHeartbeat(ready: true).watchSnapshot)
        defaults.set(true, forKey: "CloudCodex.watchSharing.v1.")
        let snapshot = try XCTUnwrap(model.makeRemoteHeartbeat(ready: true).watchSnapshot)
        XCTAssertEqual(snapshot.runningCount, 1)
        XCTAssertEqual(snapshot.tasks.map(\.status), ["运行中", "空闲"])
        XCTAssertNil(snapshot.fiveHourRemaining)
        XCTAssertNil(snapshot.plan)
        XCTAssertTrue(snapshot.quotaIsStale(at: .now))
        model.threads = []
        model.selectedFolder = "/other"
        XCTAssertEqual(model.makeRemoteHeartbeat(ready: true).watchSnapshot?.tasks, snapshot.tasks)
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(encoded.contains("/project"))
        XCTAssertFalse(encoded.contains("workspace"))
        XCTAssertFalse(encoded.contains("token"))
        defaults.set(false, forKey: "CloudCodex.watchSharing.v1.")
        XCTAssertNil(model.makeRemoteHeartbeat(ready: true).watchSnapshot)
    }
    func testUnknownQuotaAndStaleness() throws {
        let json = #"{"version":1,"capturedAt":1000,"quotaCapturedAt":900,"plan":"Plus","fiveHourRemaining":null,"tasks":[],"runningCount":0,"waitingCount":0}"#
        let snapshot = try JSONDecoder().decode(CloudCodexWatchSnapshot.self, from: Data(json.utf8))
        XCTAssertFalse(snapshot.isStale(at: Date(timeIntervalSince1970: 1299)))
        XCTAssertTrue(snapshot.isStale(at: Date(timeIntervalSince1970: 1301)))
        XCTAssertTrue(snapshot.quotaIsStale(at: Date(timeIntervalSince1970: 1201)))
        XCTAssertEqual(CloudCodexWatchSnapshot.percent(nil), "—")
        XCTAssertEqual(CloudCodexWatchSnapshot.percent(.nan), "—")
        XCTAssertEqual(CloudCodexWatchSnapshot.percent(123), "100%")
    }
    func testAccountMetricsUseExistingMacFormattingAndWeeklyPace() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let usage = RemoteUsageSnapshot.parse([
            "rateLimits": ["planType": "prolite", "credits": ["balance": "73793.9", "unlimited": false],
                "secondary": ["usedPercent": 73.0, "windowDurationMins": 10080, "resetsAt": now.timeIntervalSince1970 + 6 * 86400] as [String: Any]],
            "rateLimitResetCredits": ["availableCount": 1]
        ], now: now)
        var snapshot = CloudCodexWatchSnapshot(version: 1, capturedAt: now.timeIntervalSince1970,
            quotaCapturedAt: nil, plan: nil, subscriptionPeriodEnd: nil, fiveHourRemaining: nil,
            weeklyRemaining: nil, fiveHourResetsAt: nil, weeklyResetsAt: nil,
            tasks: [], runningCount: 0, waitingCount: 0)
        snapshot.applyAccountMetrics(usage, now: now)
        XCTAssertEqual(snapshot.creditBalanceText, "73,793.9")
        XCTAssertEqual(snapshot.availableResetCount, 1)
        XCTAssertEqual(snapshot.weeklyPaceLabel, "已超前 58.8%")
        XCTAssertEqual(snapshot.weeklyPaceState, "ahead")
        snapshot.applyAccountMetrics(.unavailable(), now: now)
        XCTAssertNil(snapshot.creditBalanceText)
        XCTAssertNil(snapshot.availableResetCount)
        XCTAssertNil(snapshot.weeklyPaceLabel)
        XCTAssertNil(snapshot.weeklyPaceState)
    }

}
