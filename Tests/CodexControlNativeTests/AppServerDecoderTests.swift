import Foundation
import XCTest
@testable import CloudCodex

final class AppServerDecoderTests: XCTestCase {
    func testLargeFragmentedJSONLineIsDecodedOnlyAfterNewlineArrives() throws {
        var decoder = JSONLineDecoder()
        let payload = String(repeating: "x", count: 512_000)
        let encoded = try XCTUnwrap(
            "{\"id\":42,\"result\":{\"payload\":\"\(payload)\"}}\n".data(using: .utf8)
        )

        var decoded: [[String: Any]] = []
        for offset in stride(from: 0, to: encoded.count, by: 257) {
            let end = min(offset + 257, encoded.count)
            decoded.append(contentsOf: decoder.consume(encoded.subdata(in: offset..<end)))
        }

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?["id"] as? Int, 42)
        let result = try XCTUnwrap(decoded.first?["result"] as? [String: Any])
        XCTAssertEqual((result["payload"] as? String)?.count, payload.count)
    }

    func testMultipleAndPartialLinesPreserveOrder() {
        var decoder = JSONLineDecoder()

        XCTAssertTrue(decoder.consume(Data("{\"id\":1}\n{\"id\"".utf8)).map { $0["id"] as? Int } == [1])
        XCTAssertTrue(decoder.consume(Data(":2}\n\n{\"id\":3}\n".utf8)).map { $0["id"] as? Int } == [2, 3])
    }

    func testTurnMetadataReaderFindsModelsAndScansOnlyAppendedContent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudCodexTurnMetadataTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sessionURL = directory.appendingPathComponent("session.jsonl")
        let firstContext = """
        {"timestamp":"2026-09-05T01:00:00Z","type":"turn_context","payload":{"turn_id":"turn-1","model":"gpt-5.6-sol","effort":"xhigh"}}
        {"timestamp":"2026-09-05T01:00:01Z","type":"response_item","payload":{"type":"message"}}

        """
        try Data(firstContext.utf8).write(to: sessionURL)

        let reader = TurnMetadataReader()
        let first = await reader.metadata(filePath: sessionURL.path, turnIDs: ["turn-1"])
        XCTAssertEqual(first["turn-1"]?.displayLabel, "gpt-5.6-sol · 极高")

        let secondContext = """
        {"timestamp":"2026-09-05T02:00:00Z","type":"turn_context","payload":{"turn_id":"turn-2","model":"gpt-6-astra","effort":"high"}}

        """
        let handle = try FileHandle(forWritingTo: sessionURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(secondContext.utf8))
        try handle.close()

        let second = await reader.metadata(
            filePath: sessionURL.path,
            turnIDs: ["turn-1", "turn-2"]
        )
        XCTAssertEqual(second["turn-1"]?.model, "gpt-5.6-sol")
        XCTAssertEqual(second["turn-2"]?.displayLabel, "gpt-6-astra · 高")
    }

    @MainActor
    func testHistoricalMessagesUseMetadataFromTheirOwnTurn() {
        let turns: [[String: Any]] = [
            [
                "id": "turn-old",
                "startedAt": 1_725_520_400,
                "completedAt": 1_725_520_460,
                "items": [
                    ["id": "user-old", "type": "userMessage", "content": [["type": "text", "text": "旧问题"]]],
                    ["id": "answer-old", "type": "agentMessage", "text": "旧回答"]
                ]
            ],
            [
                "id": "turn-new",
                "startedAt": 1_725_524_000,
                "completedAt": 1_725_524_120,
                "items": [
                    ["id": "user-new", "type": "userMessage", "content": [["type": "text", "text": "新问题"]]],
                    ["id": "answer-new", "type": "agentMessage", "text": "新回答"]
                ]
            ]
        ]
        let messages = AppServerClient.parseMessages(
            from: turns,
            metadataByTurnID: [
                "turn-old": TurnModelMetadata(model: "gpt-5.6-sol", reasoningEffort: "xhigh"),
                "turn-new": TurnModelMetadata(model: "gpt-6-astra", reasoningEffort: "high")
            ]
        )

        XCTAssertEqual(messages.first { $0.id == "answer-old" }?.modelUsageLabel, "gpt-5.6-sol · 极高 · 速度未知")
        XCTAssertEqual(messages.first { $0.id == "answer-new" }?.modelUsageLabel, "gpt-6-astra · 高 · 速度未知")
        XCTAssertEqual(messages.first { $0.id == "answer-old" }?.turnID, "turn-old")
        XCTAssertEqual(messages.first { $0.id == "answer-new" }?.turnID, "turn-new")
        XCTAssertEqual(
            messages.first { $0.id == "user-old" }?.timestamp,
            Date(timeIntervalSince1970: 1_725_520_400)
        )
        XCTAssertEqual(
            messages.first { $0.id == "answer-old" }?.timestamp,
            Date(timeIntervalSince1970: 1_725_520_460)
        )
    }

    func testHistoricalCollaborationItemsPreserveEveryChildTask() {
        let turns: [[String: Any]] = [[
            "id": "turn-collab",
            "items": [
                [
                    "id": "spawn",
                    "type": "collabAgentToolCall",
                    "tool": "spawnAgent",
                    "status": "completed",
                    "senderThreadId": "parent",
                    "receiverThreadIds": ["child-xili", "child-guanlong"],
                    "agentsStates": [
                        "child-xili": ["status": "running"],
                        "child-guanlong": ["status": "completed", "message": "已完成校区优化"]
                    ]
                ],
                [
                    "id": "xili-completed",
                    "type": "subAgentActivity",
                    "agentThreadId": "child-xili",
                    "agentPath": "/root/xili",
                    "kind": "completed"
                ]
            ]
        ]]

        let messages = AppServerClient.parseMessages(from: turns)
        XCTAssertEqual(messages.count, 2)
        XCTAssertTrue(messages.allSatisfy { $0.activityKind == .collaboration })
        let group = ConversationProcessGroup(messages: messages)
        XCTAssertEqual(group.childTasks.count, 2)
        XCTAssertEqual(group.childTasks.first { $0.threadID == "child-xili" }?.name, "xili")
        XCTAssertEqual(group.childTasks.first { $0.threadID == "child-xili" }?.status, "已完成")
        XCTAssertEqual(group.childTasks.first { $0.threadID == "child-guanlong" }?.status, "已完成")
    }

    func testHistoricalActivitiesPreserveStepTiming() throws {
        let messages = AppServerClient.parseMessages(from: [[
            "id": "turn-timing",
            "items": [[
                "id": "command-timing",
                "type": "commandExecution",
                "command": "swift test",
                "status": "completed",
                "exitCode": 0,
                "started_at_ms": 1_725_520_400_250 as Int64,
                "completed_at_ms": 1_725_520_465_750 as Int64
            ]]
        ]])

        let command = try XCTUnwrap(messages.first)
        XCTAssertEqual(command.startedAt, Date(timeIntervalSince1970: 1_725_520_400.25))
        XCTAssertEqual(command.completedAt, Date(timeIntervalSince1970: 1_725_520_465.75))
        XCTAssertFalse(command.isStreaming)
    }

    func testHistoricalFileChangesKeepDiffAndLineCounts() throws {
        let turns: [[String: Any]] = [[
            "id": "turn-files",
            "items": [[
                "id": "patch-1",
                "type": "fileChange",
                "status": "completed",
                "changes": [[
                    "path": "Sources/App.swift",
                    "kind": ["type": "update"],
                    "diff": "@@ -1,2 +1,3 @@\n-old\n+new\n keep\n+added"
                ]]
            ]]
        ]]

        let message = try XCTUnwrap(AppServerClient.parseMessages(from: turns).first)
        let change = try XCTUnwrap(message.fileChanges.first)
        XCTAssertEqual(message.turnID, "turn-files")
        XCTAssertEqual(change.path, "Sources/App.swift")
        XCTAssertEqual(change.kind, .update)
        XCTAssertEqual(change.addedLines, 2)
        XCTAssertEqual(change.deletedLines, 1)
    }

}
