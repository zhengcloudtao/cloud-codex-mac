import XCTest
@testable import CloudCodex

final class RemoteTaskFilesTests: XCTestCase {
    func testExportIsLimitedToRegularWorkspaceFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture".utf8).write(to: root.appendingPathComponent("report.pdf"))
        try Data("private fixture".utf8).write(to: root.appendingPathComponent(".env"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        XCTAssertNotNil(RemoteTaskFiles.exportURL("report.pdf", workspace: root.path))
        XCTAssertNotNil(RemoteTaskFiles.exportURL("sandbox:" + root.appendingPathComponent("report.pdf").path, workspace: root.path))
        for path in [".env", "outside", "../other.txt", "/etc/hosts", "https://example.test/report.pdf", "missing.pdf", "."] {
            XCTAssertNil(RemoteTaskFiles.exportURL(path, workspace: root.path), path)
        }
    }

    func testUploadRewriteDownloadAndMention() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fixture".utf8).write(to: root.appendingPathComponent("report(1).pdf"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TaskFileFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let defaults = UserDefaults(suiteName: "RemoteFiles-" + UUID().uuidString)!
        let api = RemoteControlAPI(deviceSecret: "test-device-secret", baseURL: URL(string: "https://relay.example.test/ai")!, session: session, defaults: defaults)
        let rewritten = await api.fileExporter.rewrite("[报告](report(1).pdf)", workspace: root.path, scope: "tasks/test", api: api)
        XCTAssertEqual(rewritten, "[报告](cloudcodex-file:11111111-1111-1111-1111-111111111111)")
        let code = "```markdown\n[示例](report(1).pdf)\n```\n`[示例](report(1).pdf)`"
        let preserved = await api.fileExporter.rewrite(code, workspace: root.path, scope: "tasks/test", api: api)
        XCTAssertEqual(preserved, code)
        let file = RemoteTaskFile(id: "11111111-1111-1111-1111-111111111111", name: "report.pdf", size: 7)
        let task = RemoteTask(taskId: "test", deviceId: "device", threadId: "", workspace: root.path, prompt: "", model: "", effort: "", status: "running", files: [file])
        let attachments = try await RemoteTaskFiles.download([file], task: task, api: api, session: session)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(try Data(contentsOf: attachments[0].url), Data("fixture".utf8))
        XCTAssertEqual(attachments[0].userInput["type"] as? String, "mention")
        XCTAssertEqual(RemoteTaskFiles.historyFileID(attachments[0].url.path), file.id)
        XCTAssertNotNil(RemoteTaskFiles.exportURL(attachments[0].url.path, workspace: root.path), "edited input files can be exported as new artifacts")
        XCTAssertNil(RemoteTaskFiles.historyFileID("/tmp/unrelated/file.pdf"))
        XCTAssertTrue(attachments[0].url.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/"))
        do {
            _ = try await RemoteTaskFiles.download([RemoteTaskFile(id: file.id, name: "../escape.pdf", size: 7)], task: task, api: api, session: session)
            XCTFail("traversal accepted")
        } catch { }
        do {
            _ = try await RemoteTaskFiles.bytes(from: "https://storage.example.test/denied", session: session)
            XCTFail("HTTP failure accepted")
        } catch { XCTAssertFalse(error.localizedDescription.contains("storage.example")) }
    }
}
private final class TaskFileFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data: Data
        let isStorage = request.url?.host == "storage.example.test"
        if isStorage {
            XCTAssertNil(request.value(forHTTPHeaderField: "X-CloudCodex-Token"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            data = Data("fixture".utf8)
        } else {
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-CloudCodex-Token"), "test-device-secret")
            if request.httpMethod == "POST" {
                XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data;") == true)
                data = Data(#"{"status":0,"msg":"","data":{"id":"11111111-1111-1111-1111-111111111111","name":"report(1).pdf","size":7}}"#.utf8)
            } else {
                data = Data(#"{"status":0,"msg":"","data":{"url":"https://storage.example.test/file","name":"report.pdf","size":7}}"#.utf8)
            }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: request.url?.path == "/denied" ? 403 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
