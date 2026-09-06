import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Downloads only the task's already-authorized image attachments. No account/device credentials.
enum RemoteImageLoader {
    static let maxBytes = 5 * 1024 * 1024

    static func attachments(_ values: [String], session: URLSession? = nil) async throws -> [ComposerAttachment] {
        guard values.count <= 4 else { throw RemoteControlError.server("远程任务最多支持 4 张图片。") }
        let ownedSession = session ?? makeSession()
        defer { if session == nil { ownedSession.invalidateAndCancel() } }
        var result: [ComposerAttachment] = []
        for (index, value) in values.enumerated() {
            do {
                try Task.checkCancellation()
                let url = try imageURL(value)
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                request.setValue("image/png,image/jpeg,image/webp,image/gif", forHTTPHeaderField: "Accept")
                let (bytes, response) = try await ownedSession.bytes(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw RemoteControlError.server("下载失败，图片可能已过期，请重新上传。")
                }
                guard response.expectedContentLength <= maxBytes else {
                    throw RemoteControlError.server("图片超过 5 MB，请压缩后重新上传。")
                }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < maxBytes else { throw RemoteControlError.server("图片超过 5 MB，请压缩后重新上传。") }
                    data.append(byte)
                }
                result.append(try inlineAttachment(data))
            } catch is CancellationError { throw CancellationError() }
            catch let error as RemoteControlError {
                throw RemoteControlError.server("第 \(index + 1) 张图片：\(error.localizedDescription)")
            } catch {
                // Do not echo signed URLs, remote response bodies or network credentials.
                throw RemoteControlError.server("第 \(index + 1) 张图片下载失败，请检查 Mac 网络后重新上传。")
            }
        }
        return result
    }

    static func imageURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty, url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"),
              !host.contains(":"), host.contains(where: { $0.isLetter }) else {
            throw RemoteControlError.server("图片地址无效，请重新上传。")
        }
        return url
    }

    static func inlineAttachment(_ data: Data) throws -> ComposerAttachment {
        guard !data.isEmpty, data.count <= maxBytes else {
            throw RemoteControlError.server("图片为空或超过 5 MB，请重新上传。")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let typeID = CGImageSourceGetType(source),
              let type = UTType(typeID as String),
              let mime = type.preferredMIMEType,
              ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw RemoteControlError.server("不是有效的 PNG、JPEG、GIF 或 WebP 图片，请重新上传。")
        }
        let value = "data:\(mime);base64,\(data.base64EncodedString())"
        guard let url = URL(string: value) else { throw RemoteControlError.server("图片转换失败，请重新上传。") }
        return ComposerAttachment(url: url)
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        return URLSession(configuration: config, delegate: NoImageRedirects(), delegateQueue: nil)
    }
}

private final class NoImageRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
