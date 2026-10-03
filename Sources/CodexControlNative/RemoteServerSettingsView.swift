import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RemoteServerSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = RemoteServerConfiguration()
    @State private var guide: String?
    @State private var feedback: String?
    @State private var showingGuide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("远程服务", systemImage: "network").font(.subheadline.weight(.semibold))
            Picker("服务来源", selection: $draft.mode) {
                Text("内置服务").tag(RemoteServerConfiguration.Mode.builtIn)
                Text("自定义服务").tag(RemoteServerConfiguration.Mode.custom)
            }.pickerStyle(.segmented).disabled(!model.canChangeRemoteServer)
            if draft.mode == .custom {
                TextField("HTTPS 服务根地址（可含路径前缀）", text: $draft.customAddress)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!model.canChangeRemoteServer)
                Text("使用自己的后端和小程序，客户端会显示对应服务的设备配对二维码。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("使用 CloudCodex 内置服务和小程序。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("切换前请关闭远程任务并等待当前操作结束。新服务需配对；切回原地址会复用原设备身份。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("保存服务配置") {
                    if model.saveRemoteServerConfiguration(draft) {
                        draft = model.remoteServerConfiguration
                        feedback = "配置已保存"
                    }
                }.disabled(!model.canChangeRemoteServer)
                Spacer()
                Button("查看接入说明") {
                    prepareGuide()
                    showingGuide = guide != nil
                }
                Button("复制给 AI 的指引") {
                    prepareGuide()
                    if let guide {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(guide, forType: .string)
                        feedback = "已复制自建接入指引；未配置自建地址时使用占位符"
                    }
                }
            }
            if let error = model.remoteServerConfigurationError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(16)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        .onAppear { draft = model.remoteServerConfiguration }
        .sheet(isPresented: $showingGuide) {
            if let guide { RemoteIntegrationGuideSheet(document: guide) }
        }
    }

    private func prepareGuide() {
        do {
            guide = try RemoteIntegrationGuide.document(configuration: model.remoteServerConfiguration)
            feedback = nil
        } catch {
            guide = nil
            feedback = "请先保存有效服务地址，再生成接入指引。"
        }
    }
}

private struct RemoteIntegrationGuideSheet: View {
    let document: String
    @Environment(\.dismiss) private var dismiss
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("自定义远程控制接入说明").font(.headline)
                Spacer()
                Button("复制全文") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(document, forType: .string)
                    feedback = "已复制，可直接交给 AI 开发配套小程序和后端"
                }
                Button("保存说明…") { saveDocument() }
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(document).font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            if let feedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
        }.padding(20).frame(width: 800, height: 650)
    }

    private func saveDocument() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "CloudCodex-远程控制接入说明.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.write(to: url, atomically: true, encoding: .utf8)
            feedback = "接入说明已保存"
        } catch { feedback = "保存失败：\(error.localizedDescription)" }
    }
}
