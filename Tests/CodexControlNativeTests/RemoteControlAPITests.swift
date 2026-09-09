import XCTest
@testable import CloudCodex

final class RemoteControlAPITests: XCTestCase {
    @MainActor func testRemoteImagesAndApprovalSettingsReachTurn() throws {
        let data = Data(#"{"status":0,"msg":"ok","data":{"taskId":"t","deviceId":"d","threadId":"","workspace":"/tmp/project","prompt":"看图","model":"","effort":"","status":"queued","speed":"fast","permissionMode":"auto","imageUrls":["https://example.com/image.png"]}}"#.utf8)
        let task = try RemoteControlAPI.decodeEnvelope(RemoteTask.self, data: data)
        XCTAssertEqual(task.speed, "fast")
        XCTAssertEqual(task.permissionMode, "auto")
        XCTAssertEqual(task.imageUrls?.first, "https://example.com/image.png")
        let png = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII="))
        let attachment = try RemoteImageLoader.inlineAttachment(png)
        let params = AppServerClient.turnStartParameters(
            threadID: "thread", text: task.prompt,
            attachments: [attachment],
            model: nil, effort: nil, permissions: ":workspace",
            serviceTierForTurn: "priority", approvalPolicy: "on-request", approvalsReviewer: "auto_review"
        )
        let input = try XCTUnwrap(params["input"] as? [[String: Any]])
        XCTAssertEqual(input[1]["type"] as? String, "image")
        XCTAssertTrue((input[1]["url"] as? String ?? "").hasPrefix("data:image/png;base64,"))
        XCTAssertNil(input[1]["path"])
        XCTAssertEqual(params["serviceTierForTurn"] as? String, "priority")
        XCTAssertEqual(params["approvalPolicy"] as? String, "on-request")
        XCTAssertEqual(params["approvalsReviewer"] as? String, "auto_review")
    }

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
        XCTAssertNil(value.speed)
        XCTAssertNil(value.permissionMode)
        XCTAssertNil(value.imageUrls)
    }

    @MainActor func testActiveWriterAndRunningConversationAreDeferred() {
        XCTAssertTrue(AppModel.shouldDeferRemoteTask(RemoteControlError.server("thread abc already has an active writer")))
        XCTAssertTrue(AppModel.shouldDeferRemoteTask(RemoteControlError.server("这个会话正在 Codex 中运行，请稍后重试。")))
        XCTAssertTrue(AppModel.shouldDeferRemoteTask(RemoteControlError.server("这个会话正在执行其他任务，请稍后重试。")))
        XCTAssertFalse(AppModel.shouldDeferRemoteTask(RemoteControlError.server("会话与工作区不匹配。")))
        XCTAssertEqual(AppModel.remoteWaitReason(RemoteControlError.server("thread already has an active writer")), "writer_busy")
        XCTAssertEqual(AppModel.remoteWaitReason(RemoteControlError.server("这个会话正在执行其他任务")), "thread_busy")
    }
}
