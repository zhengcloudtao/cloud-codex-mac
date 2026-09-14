import XCTest
@testable import CloudCodex

@MainActor
final class ThreadNamingTests: XCTestCase {
    private func thread(name: String? = nil) throws -> CodexThread {
        var json: [String: Any] = [
            "id": "thread-1",
            "cwd": "/tmp/project",
            "preview": "原始问题"
        ]
        if let name { json["name"] = name }
        return try XCTUnwrap(CodexThread(json: json))
    }

    func testContextEditorStartsWithVisibleNameAndRejectsBlankValue() async throws {
        let model = AppModel()
        model.beginRenamingThread(try thread())

        XCTAssertTrue(model.showingThreadNameEditor)
        XCTAssertEqual(model.editingThreadNameID, "thread-1")
        XCTAssertEqual(model.threadNameDraft, "原始问题")

        model.threadNameDraft = "   \n"
        await model.saveThreadName()

        XCTAssertEqual(model.threadNameEditorError, "会话名称不能为空。")
        XCTAssertTrue(model.showingThreadNameEditor)
    }

    func testNameUpdateNotificationRefreshesConversationRow() throws {
        let model = AppModel()
        model.applyThreadListSnapshot([try thread(name: "旧名称")])

        model.handleEvent("thread/name/updated", [
            "threadId": "thread-1",
            "threadName": "新名称"
        ])

        XCTAssertEqual(model.threads.first?.name, "新名称")
        XCTAssertEqual(model.threads.first?.displayName, "新名称")
    }

    func testThreadNameRequestUsesInstalledProtocol() {
        let parameters = AppServerClient.threadNameParameters(
            threadID: "thread-1",
            name: "新名称"
        )

        XCTAssertEqual(parameters["threadId"] as? String, "thread-1")
        XCTAssertEqual(parameters["name"] as? String, "新名称")
    }
}
