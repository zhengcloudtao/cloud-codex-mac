import AppKit
import CryptoKit
import Foundation
import SwiftUI

struct CloudCodexReleaseConfig: Decodable, Equatable {
    let updateEnabled: Bool
    let latestVersion: String
    let minimumVersion: String
    let updateMessage: String
    let downloadUrl: String?
    let downloadSha256: String?
}

struct CloudCodexUpdatePackage: Equatable, Sendable {
    let url: URL
    let sha256: String
    let version: String
    let fileExtension: String

    init?(url rawURL: String?, sha256 rawSHA256: String?, version: String) {
        guard let rawURL,
              let url = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil else { return nil }
        let fileExtension = url.pathExtension.lowercased()
        guard ["zip", "dmg", "pkg"].contains(fileExtension) else { return nil }
        let sha256 = (rawSHA256 ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { return nil }
        self.url = url
        self.sha256 = sha256
        self.version = version
        self.fileExtension = fileExtension
    }

    func matches(fileAt url: URL) throws -> Bool {
        try Self.sha256(of: url) == sha256
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

struct CloudCodexUpdateNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let currentVersion: String
    let latestVersion: String
    let minimumVersion: String
    let isRequired: Bool
    let package: CloudCodexUpdatePackage?
}

struct CloudCodexUpdateCheckResult: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
}

enum CloudCodexUpdateDecision: Equatable {
    case none
    case optional
    case required

    static func evaluate(currentVersion: String, config: CloudCodexReleaseConfig) -> Self {
        guard config.updateEnabled,
              let current = SemanticAppVersion(currentVersion),
              let latest = SemanticAppVersion(config.latestVersion),
              let minimum = SemanticAppVersion(config.minimumVersion) else { return .none }
        if current < minimum { return .required }
        if current < latest { return .optional }
        return .none
    }
}

struct SemanticAppVersion: Comparable, Equatable {
    let major: Int
    let minor: Int
    let patch: Int

    init?(_ value: String) {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), major >= 0,
              let minor = Int(parts[1]), minor >= 0,
              let patch = Int(parts[2]), patch >= 0 else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

enum CloudCodexUpdateDownloadState: Equatable {
    case idle
    case downloading
    case downloaded(URL)
    case failed(String)

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

private enum CloudCodexUpdateDownloadError: LocalizedError {
    case invalidPackage
    case invalidResponse
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .invalidPackage:
            return "当前版本配置缺少有效的 HTTPS 安装包地址或 SHA-256。"
        case .invalidResponse:
            return "安装包下载失败，请稍后重试。"
        case .checksumMismatch:
            return "安装包完整性校验失败，文件已丢弃，请联系管理员检查发布配置。"
        }
    }
}

@MainActor
final class CloudCodexUpdateController: ObservableObject {
    @Published var notice: CloudCodexUpdateNotice?
    @Published var checkResult: CloudCodexUpdateCheckResult?
    @Published private(set) var downloadState: CloudCodexUpdateDownloadState = .idle
    @Published private(set) var isChecking = false

    private let session: URLSession
    private let endpoint: URL
    private let currentVersion: String
    private var hasChecked = false

    init(
        session: URLSession = .shared,
        endpoint: URL = RemoteControlAPI.defaultBaseURL.appendingPathComponent("api/public/cloud-codex/release"),
        currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    ) {
        self.session = session
        self.endpoint = endpoint
        self.currentVersion = currentVersion
    }

    func check(force: Bool = false, reportsResult: Bool = false) async {
        guard force || !hasChecked else { return }
        guard !isChecking else { return }
        hasChecked = true
        isChecking = true
        defer { isChecking = false }
        if reportsResult { checkResult = nil }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let envelope = try JSONDecoder().decode(ReleaseEnvelope.self, from: data)
            guard envelope.status == 0, let config = envelope.data else {
                throw URLError(.cannotParseResponse)
            }
            let decision = CloudCodexUpdateDecision.evaluate(currentVersion: currentVersion, config: config)
            guard decision != .none else {
                if reportsResult {
                    checkResult = CloudCodexUpdateCheckResult(
                        title: "已是最新版本",
                        message: "当前版本为 \(currentVersion)，暂无可用更新。"
                    )
                }
                return
            }
            let required = decision == .required
            downloadState = .idle
            notice = CloudCodexUpdateNotice(
                title: required ? "当前版本过低" : "发现新版本",
                message: config.updateMessage.trimmingCharacters(in: .whitespacesAndNewlines),
                currentVersion: currentVersion,
                latestVersion: config.latestVersion,
                minimumVersion: config.minimumVersion,
                isRequired: required,
                package: CloudCodexUpdatePackage(
                    url: config.downloadUrl,
                    sha256: config.downloadSha256,
                    version: config.latestVersion
                )
            )
        } catch {
            // 版本服务不可用或返回异常时不阻塞 CloudCodex 本地启动。
            if reportsResult {
                checkResult = CloudCodexUpdateCheckResult(
                    title: "无法检查更新",
                    message: "暂时无法连接更新服务，请稍后重试。"
                )
            }
        }
    }

    func download(_ notice: CloudCodexUpdateNotice) async {
        guard !downloadState.isDownloading else { return }
        guard let package = notice.package else {
            downloadState = .failed(CloudCodexUpdateDownloadError.invalidPackage.localizedDescription)
            return
        }
        downloadState = .downloading
        do {
            var request = URLRequest(url: package.url)
            request.timeoutInterval = 600
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (temporaryURL, response) = try await session.download(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  http.url?.scheme?.lowercased() == "https" else {
                throw CloudCodexUpdateDownloadError.invalidResponse
            }
            let matches = try await Task.detached(priority: .utility) {
                try package.matches(fileAt: temporaryURL)
            }.value
            guard matches else { throw CloudCodexUpdateDownloadError.checksumMismatch }
            let destination = try uniqueDownloadDestination(for: package)
            try FileManager.default.copyItem(at: temporaryURL, to: destination)
            downloadState = .downloaded(destination)
            _ = NSWorkspace.shared.open(destination)
        } catch {
            downloadState = .failed(error.localizedDescription)
        }
    }

    func openDownloadedUpdate(_ url: URL) {
        _ = NSWorkspace.shared.open(url)
    }

    func revealDownloadedUpdate(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func uniqueDownloadDestination(for package: CloudCodexUpdatePackage) throws -> URL {
        let downloads = try FileManager.default.url(
            for: .downloadsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let baseName = "CloudCodex-\(package.version)"
        for suffix in 0..<100 {
            let name = suffix == 0 ? baseName : "\(baseName) (\(suffix))"
            let candidate = downloads
                .appendingPathComponent(name)
                .appendingPathExtension(package.fileExtension)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return downloads
            .appendingPathComponent("\(baseName)-\(UUID().uuidString)")
            .appendingPathExtension(package.fileExtension)
    }

    private struct ReleaseEnvelope: Decodable {
        let status: Int
        let data: CloudCodexReleaseConfig?
    }
}

struct CloudCodexUpdateSheet: View {
    let notice: CloudCodexUpdateNotice
    @ObservedObject var controller: CloudCodexUpdateController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: notice.isRequired ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.down.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(notice.isRequired ? .orange : .blue)
                VStack(alignment: .leading, spacing: 5) {
                    Text(notice.title).font(.title2.bold())
                    Text(notice.message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                GridRow { Text("当前版本").foregroundStyle(.secondary); Text(notice.currentVersion) }
                GridRow { Text("最新版本").foregroundStyle(.secondary); Text(notice.latestVersion).fontWeight(.semibold) }
                GridRow { Text("最低版本").foregroundStyle(.secondary); Text(notice.minimumVersion) }
            }
            .font(.callout)

            downloadStatus

            HStack {
                if case let .downloaded(url) = controller.downloadState {
                    Button("在 Finder 中显示") { controller.revealDownloadedUpdate(url) }
                    Spacer()
                    Button("重新打开安装包") { controller.openDownloadedUpdate(url) }
                    Button("完成") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(notice.isRequired ? "暂不更新" : "稍后提醒") { dismiss() }
                        .disabled(controller.downloadState.isDownloading)
                    Spacer()
                    Button(downloadButtonTitle) {
                        Task { await controller.download(notice) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(controller.downloadState.isDownloading || notice.package == nil)
                }
            }
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled(controller.downloadState.isDownloading)
    }

    @ViewBuilder
    private var downloadStatus: some View {
        switch controller.downloadState {
        case .idle:
            if notice.package == nil {
                Label("当前更新尚未配置可下载的安装包，请联系管理员。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Label("安装包将在应用内下载，SHA-256 校验通过后自动打开。", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
            }
        case .downloading:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在应用内下载并校验安装包…")
            }
        case let .downloaded(url):
            Label("下载和校验完成，已打开 \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var downloadButtonTitle: String {
        if case .failed = controller.downloadState { return "重新下载" }
        return "立即下载更新"
    }
}
