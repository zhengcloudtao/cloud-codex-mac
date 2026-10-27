import SwiftUI
import AppKit

struct WatchConnectionCode: Codable {
    let version: Int
    let server: String
    let deviceId: String
    let token: String
    let expiresAt: Double
    var controlToken: String? = nil
}
struct CloudCodexWatchSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var busy = false
    @State private var message: String?
    @State private var connectionCode: String?
    var body: some View {
        GroupBox("App 与手表 · 扫码绑定") {
            VStack(alignment: .leading, spacing: 10) {
                Text("扫码后授权 iPhone 查看会话、提交任务及操作本电脑，Apple Watch 仅可查看状态。电脑需保持运行并开启远程连接。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(model.watchSharingEnabled ? "重新生成控制绑定二维码" : "生成控制绑定二维码") {
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                let code = try await model.createWatchConnectionCode()
                                connectionCode = code
                                message = "在 iPhone 学深课表 → 个人中心 → CloudCodex → 添加设备 → 扫码绑定电脑。90 天有效，重新生成会撤销旧连接。"
                            } catch { message = error.localizedDescription }
                        }
                    }
                    .disabled(busy || !model.remoteControlEnabled)
                    if model.watchSharingEnabled {
                        Button("撤销 App 与手表绑定", role: .destructive) {
                            busy = true
                            Task {
                                defer { busy = false }
                                do { try await model.revokeWatchConnection(); connectionCode = nil; message = "已撤销，App 控制权限立即失效，手表下次刷新后清除状态。" }
                                catch { message = error.localizedDescription }
                            }
                        }.disabled(busy)
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
                if let connectionCode, let qr = RemotePairingQRCode.image(payload: connectionCode) {
                    Image(nsImage: qr).interpolation(.none).resizable().scaledToFit()
                        .frame(width: 240, height: 240).padding(16).background(.white)
                        .accessibilityLabel("iPhone 与 Apple Watch 绑定二维码")
                    Button("复制连接码") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(connectionCode, forType: .string)
                        message = "连接码已复制，也可在 iPhone 粘贴连接。"
                    }
                }
                if let message { Text(message).font(.caption).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .onDisappear { connectionCode = nil }
        .onChange(of: model.watchSharingEnabled) { _, enabled in if !enabled { connectionCode = nil } }
    }
}
