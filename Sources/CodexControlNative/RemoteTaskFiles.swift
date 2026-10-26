import Foundation
import CryptoKit

struct RemoteTaskFile: Codable, Equatable {
    var id: String
    var name: String
    var size: Int
}
struct RemoteFileDownload: Decodable { var url: String; var name: String; var size: Int }

enum RemoteTaskFiles {
    static let maxBytes = 20 * 1024 * 1024

    static func download(_ files: [RemoteTaskFile], task: RemoteTask, api: RemoteControlAPI, session: URLSession? = nil) async throws -> [ComposerAttachment] {
        guard files.count <= 4 else { throw RemoteControlError.server("远程任务最多支持 4 个文件。") }
        if files.isEmpty { return [] }
        let root = URL(fileURLWithPath: task.workspace, isDirectory: true).resolvingSymlinksInPath()
        let directory = root.appendingPathComponent(".cloudcodex-attachments-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var result: [ComposerAttachment] = []
        do {
            for file in files {
                guard UUID(uuidString: file.id) != nil, file.size > 0, file.size <= maxBytes,
                      file.name == URL(fileURLWithPath: file.name).lastPathComponent,
                      !file.name.contains("\\"), !file.name.hasPrefix("."), !file.name.contains("\0") else {
                    throw RemoteControlError.server("任务文件信息无效，请重新上传。")
                }
                let download = try await api.fileURL(taskID: task.taskId, fileID: file.id)
                let data = try await bytes(from: download.url, session: session)
                guard data.count == file.size else { throw RemoteControlError.server("文件大小不匹配，请重新上传。") }
                let folder = directory.appendingPathComponent(file.id, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                let target = folder.appendingPathComponent(file.name)
                try data.write(to: target, options: .atomic)
                result.append(ComposerAttachment(url: target))
            }
            return result
        } catch {
            // This newly-created UUID directory contains only this failed transfer.
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func bytes(from value: String, session supplied: URLSession? = nil) async throws -> Data {
        let url = try RemoteImageLoader.imageURL(value)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForResource = 120
        let session = supplied ?? URLSession(configuration: config, delegate: RemoteFileNoRedirects(), delegateQueue: nil)
        defer { if supplied == nil { session.invalidateAndCancel() } }
        do {
            let (stream, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.expectedContentLength <= maxBytes else { throw RemoteControlError.invalidServerResponse }
            var data = Data()
            for try await byte in stream {
                guard data.count < maxBytes else { throw RemoteControlError.invalidServerResponse }
                data.append(byte)
            }
            guard !data.isEmpty else { throw RemoteControlError.invalidServerResponse }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch { throw RemoteControlError.server("文件下载失败，请检查网络或重新上传。") }
    }

    static func historyFileID(_ path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        let directory = parent.deletingLastPathComponent().lastPathComponent
        guard directory.hasPrefix(".cloudcodex-attachments-"),
              UUID(uuidString: String(directory.dropFirst(".cloudcodex-attachments-".count))) != nil,
              UUID(uuidString: parent.lastPathComponent) != nil else { return nil }
        return parent.lastPathComponent
    }

    static func exportURL(_ value: String, workspace: String) -> URL? {
        var path = value.removingPercentEncoding ?? value
        if path.hasPrefix("sandbox:") { path = String(path.dropFirst(8)) }
        if path.hasPrefix("file://") { path = URL(string: path)?.path ?? "" }
        guard !path.isEmpty, !path.contains("://"), !path.hasPrefix("cloudcodex-file:") else { return nil }
        let root = URL(fileURLWithPath: workspace, isDirectory: true).resolvingSymlinksInPath()
        let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)).resolvingSymlinksInPath()
        let relative = url.path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init)
        let managedInput = relative.count == 3 && historyFileID(url.path) != nil
        guard url.path.hasPrefix(root.path + "/"),
              !relative.enumerated().contains(where: { $0.element.hasPrefix(".") && !(managedInput && $0.offset == 0) }),
              !["id_rsa", "id_ed25519", "credentials"].contains(url.lastPathComponent.lowercased()),
              !["pem", "key", "p12", "pfx", "keychain-db"].contains(url.pathExtension.lowercased()),
              let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              info.isRegularFile == true, let size = info.fileSize, size > 0, size <= maxBytes else { return nil }
        return url
    }
}

actor RemoteFileExporter {
    private var cache: [String: String] = [:]
    func rewrite(_ text: String, workspace: String, scope: String, cacheScope: String? = nil, api: RemoteControlAPI) async -> String {
        guard !workspace.isEmpty, let regex = try? NSRegularExpression(pattern: #"(?<!!)\[[^\]\n]+\]\(<?((?:[^\s<>()]|\([^\s()]*\))+)>?(?:\s+\"[^\"]*\")?\)"#) else { return text }
        var result = text
        let code = try? NSRegularExpression(pattern: #"(?s)```.*?(?:```|\z)|~~~.*?(?:~~~|\z)|`[^`\n]*`"#)
        let codeRanges = code?.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range) ?? []
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var count = 0
        for match in matches.reversed() {
            guard !codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  count < 8, let range = Range(match.range(at: 1), in: text),
                  let url = RemoteTaskFiles.exportURL(String(text[range]), workspace: workspace) else { continue }
            count += 1
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard !data.isEmpty, data.count <= RemoteTaskFiles.maxBytes else { continue }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let key = (cacheScope ?? scope) + ":" + url.lastPathComponent + ":" + digest
                let id: String
                if let cached = cache[key] { id = cached }
                else {
                    id = try await api.uploadFile(data, name: url.lastPathComponent, scope: scope).id
                    if cache.count >= 128 { cache.removeAll() }
                    cache[key] = id
                }
                // Reverse replacement keeps all original NSRange offsets valid.
                if let destination = Range(match.range(at: 1), in: result) {
                    result.replaceSubrange(destination, with: "cloudcodex-file:" + id)
                }
            } catch { /* Keep the original path visible; never claim a failed upload is downloadable. */ }
        }
        return result
    }
}
private final class RemoteFileNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
