import Foundation
import Sparkle
import SwiftUI

struct CloudCodexReleaseConfig: Decodable, Equatable {
    let updateEnabled: Bool
    let latestVersion: String
    let latestBuild: String?
    let minimumVersion: String
    let updateMessage: String
    let downloadUrl: String?
    let downloadSha256: String?
    let downloadLength: Int64?
    let downloadEdSignature: String?

    var isSparkleReady: Bool {
        guard let latestBuild,
              Int(latestBuild).map({ $0 > 0 }) == true,
              let rawURL = downloadUrl,
              let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https",
              url.host != nil,
              url.user == nil,
              let downloadLength,
              downloadLength > 0,
              let downloadEdSignature,
              Data(base64Encoded: downloadEdSignature)?.count == 64 else { return false }
        return ["zip", "dmg"].contains(url.pathExtension.lowercased())
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
    let isSparkleReady: Bool
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

enum CloudCodexSparkleConfiguration {
    static let feedURL = URL(string: "https://api.cloudslow.com/ai/api/public/cloud-codex/appcast.xml")!
}

@MainActor
final class CloudCodexSparkleUpdater: ObservableObject {

    private let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

@MainActor
final class CloudCodexUpdateController: ObservableObject {
    @Published var notice: CloudCodexUpdateNotice?
    @Published private(set) var latestVersion: String?
    @Published private(set) var isChecking = false

    private let session: URLSession
    private let endpoint: URL
    let currentVersion: String
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

    func check(force: Bool = false) async {
        guard force || !hasChecked else { return }
        guard !isChecking else { return }
        hasChecked = true
        isChecking = true
        defer { isChecking = false }
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
            latestVersion = config.latestVersion
            let decision = CloudCodexUpdateDecision.evaluate(currentVersion: currentVersion, config: config)
            guard decision != .none else { return }
            let required = decision == .required
            notice = CloudCodexUpdateNotice(
                title: required ? "当前版本过低" : "发现新版本",
                message: config.updateMessage.trimmingCharacters(in: .whitespacesAndNewlines),
                currentVersion: currentVersion,
                latestVersion: config.latestVersion,
                minimumVersion: config.minimumVersion,
                isRequired: required,
                isSparkleReady: config.isSparkleReady
            )
        } catch {
            // 版本服务不可用或返回异常时不阻塞 CloudCodex 本地启动。
        }
    }

    private struct ReleaseEnvelope: Decodable {
        let status: Int
        let data: CloudCodexReleaseConfig?
    }
}

struct CloudCodexUpdateSheet: View {
    let notice: CloudCodexUpdateNotice
    let installWithSparkle: () -> Void
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

            if notice.isSparkleReady {
                Label("更新将由 Sparkle 在应用内安全下载、安装，并自动重新启动 CloudCodex。", systemImage: "checkmark.shield")
                    .foregroundStyle(.secondary)
            } else {
                Label("当前版本尚未配置完整的 Sparkle 更新包，请联系管理员。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            HStack {
                Button(notice.isRequired ? "暂不更新" : "稍后提醒") { dismiss() }
                Spacer()
                Button("安装并重启") {
                    dismiss()
                    installWithSparkle()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!notice.isSparkleReady)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
