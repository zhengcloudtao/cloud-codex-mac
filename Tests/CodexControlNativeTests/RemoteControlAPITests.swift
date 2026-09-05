import XCTest
@testable import CloudCodex

final class RemoteControlAPITests: XCTestCase {
    func testRegistrationEnvelopeDecodes() throws {
        let data = Data(#"{"status":0,"msg":"操作成功","data":{"deviceId":"mac-1","name":"Office Mac","paired":false,"pairingCode":"12345678","pairingExpiresAt":"2026-09-05T11:00:00+08:00","pollIntervalSeconds":3}}"#.utf8)
        let value = try RemoteControlAPI.decodeEnvelope(RemoteRegistration.self, data: data)
        XCTAssertEqual(value.deviceId, "mac-1")
        XCTAssertEqual(value.pairingCode, "12345678")
        XCTAssertFalse(value.paired)
    }

    func testEmptyTaskEnvelopeDecodesAsNil() throws {
        let data = Data(#"{"status":0,"msg":"操作成功","data":null}"#.utf8)
        let value = try RemoteControlAPI.decodeOptionalEnvelope(RemoteTask.self, data: data)
        XCTAssertNil(value)
    }

    func testTaskEnvelopePreservesExecutionSelection() throws {
        let data = Data(#"{"status":0,"msg":"操作成功","data":{"taskId":"task-1","deviceId":"mac-1","threadId":"thread-1","workspace":"/tmp/project","prompt":"运行测试","model":"gpt-5.6-sol","effort":"high","status":"running"}}"#.utf8)
        let value = try RemoteControlAPI.decodeEnvelope(RemoteTask.self, data: data)
        XCTAssertEqual(value.workspace, "/tmp/project")
        XCTAssertEqual(value.model, "gpt-5.6-sol")
        XCTAssertEqual(value.effort, "high")
    }
}
