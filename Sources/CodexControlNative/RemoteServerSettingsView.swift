import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RemoteServerSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = RemoteServerConfiguration()
    @State private var guide: String?
    @State private var apiDocument: String?
    @State private var feedback: String?
    @State private var presentedDocument: PresentedRemoteDocument?

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
                    if guide != nil { presentedDocument = .integration }
                }
                Button("查看 API 文档") {
                    prepareAPIDocument()
                    if apiDocument != nil { presentedDocument = .api }
                }
                Button("复制完整 AI 指引") {
                    prepareGuide()
                    if let guide {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(guide, forType: .string)
                        feedback = "已复制完整指引（含 API、状态机、数据表和验收清单）"
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
        .sheet(item: $presentedDocument) { document in
            switch document {
            case .integration:
                if let guide {
                    RemoteDocumentationSheet(
                        title: "自定义远程控制接入说明",
                        document: guide,
                        suggestedFilename: "CloudCodex-远程控制完整接入说明.md"
                    )
                }
            case .api:
                if let apiDocument {
                    RemoteDocumentationSheet(
                        title: "CloudCodex 远程控制 API 文档",
                        document: apiDocument,
                        suggestedFilename: "CloudCodex-远程控制-API.md"
                    )
                }
            }
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

    private func prepareAPIDocument() {
        do {
            apiDocument = try RemoteAPIDocumentation.document(configuration: model.remoteServerConfiguration)
            feedback = nil
        } catch {
            apiDocument = nil
            feedback = "请先保存有效服务地址，再生成 API 文档。"
        }
    }
}

private enum PresentedRemoteDocument: String, Identifiable {
    case integration, api
    var id: String { rawValue }
}

private struct RemoteDocumentationSheet: View {
    let title: String
    let document: String
    let suggestedFilename: String
    @Environment(\.dismiss) private var dismiss
    @State private var feedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("复制全文") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(document, forType: .string)
                    feedback = "已复制全文"
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
        panel.nameFieldStringValue = suggestedFilename
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try document.write(to: url, atomically: true, encoding: .utf8)
            feedback = "接入说明已保存"
        } catch { feedback = "保存失败：\(error.localizedDescription)" }
    }
}
