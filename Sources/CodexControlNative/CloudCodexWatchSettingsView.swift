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
    @State private var hardwareCode: String?
    @State private var hardwareMessage: String?
    @State private var hardwareBusy = false
    @State private var confirmHardwareRotation = false
    @State private var confirmHardwareRevoke = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
        GroupBox("硬件双屏 · 独立控制绑定") {
            VStack(alignment: .leading, spacing: 10) {
                Text("允许硬件查看工作区、会话及任务，录音交由本电脑识别，硬件确认文字后才提交任务。与 App 和手表绑定相互独立。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(model.hardwareSharingEnabled ? "重新生成硬件连接码" : "生成硬件连接码") {
                        if model.hardwareSharingEnabled { confirmHardwareRotation = true }
                        else { generateHardwareCode() }
                    }.disabled(hardwareBusy || !model.remoteControlEnabled)
                    if model.hardwareSharingEnabled {
                        Button("撤销硬件绑定", role: .destructive) { confirmHardwareRevoke = true }
                            .disabled(hardwareBusy || !model.remoteControlEnabled)
                    }
                    if hardwareBusy { ProgressView().controlSize(.small) }
                }
                if let hardwareCode {
                    Button("复制硬件连接码") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(hardwareCode, forType: .string)
                        hardwareMessage = "已复制。在硬件配网页面粘贴连接码。"
                    }
                }
                if let hardwareMessage { Text(hardwareMessage).font(.caption).textSelection(.enabled) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .alert("重新生成硬件连接码？", isPresented: $confirmHardwareRotation) {
            Button("重新生成", role: .destructive) { generateHardwareCode() }
            Button("取消", role: .cancel) { }
        } message: { Text("已有硬件连接码将失效，需要重新配网绑定；App 和手表绑定不受影响。") }
        .alert("撤销硬件绑定？", isPresented: $confirmHardwareRevoke) {
            Button("撤销绑定", role: .destructive) { revokeHardwareCode() }
            Button("取消", role: .cancel) { }
        } message: { Text("硬件将无法读取状态或提交任务；App 和手表绑定不受影响。") }
        }
        .onDisappear { hardwareCode = nil }
    }
    private func generateHardwareCode() {
        hardwareBusy = true
        Task {
            defer { hardwareBusy = false }
            do {
                hardwareCode = try await model.createHardwareConnectionCode()
                hardwareMessage = "硬件连接码已生成，有效期 90 天。复制到硬件配网页面；App 和手表绑定不受影响。"
            } catch { hardwareMessage = error.localizedDescription }
        }
    }
    private func revokeHardwareCode() {
        hardwareBusy = true
        Task {
            defer { hardwareBusy = false }
            do {
                try await model.revokeHardwareConnection()
                hardwareCode = nil
                hardwareMessage = "已撤销硬件绑定，App 和手表不受影响。"
            } catch { hardwareMessage = error.localizedDescription }
        }
    }
}
