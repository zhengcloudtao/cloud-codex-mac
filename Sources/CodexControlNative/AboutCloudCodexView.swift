import AppKit
import SwiftUI

/// Read-only introduction: opening this window never starts or modifies a task.
struct AboutCloudCodexView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let release = info["CFBundleShortVersionString"] as? String ?? "开发版"
        guard let build = info["CFBundleVersion"] as? String else { return release }
        return "版本 \(release) · 构建 \(build)"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("CloudCodex").font(.largeTitle.bold())
                    Text("让本机 Codex 的会话、执行过程和远程任务更易管理。")
                        .foregroundStyle(.secondary)
                    Text(version).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("它是什么", symbol: "macwindow") {
                        Text("CloudCodex 是面向 macOS 的原生 Codex 管理客户端，不是一个独立的 AI 模型。它将工作区、会话、消息输入和任务进度整合到一个窗口，实际推理和工具执行由本机 Codex 及其连接的模型服务完成。")
                    }
                    section("主要功能", symbol: "square.grid.2x2") {
                        item("工作区与会话", "按文件夹与分类管理会话，搜索历史记录，打开或新建任务。")
                        item("消息与执行过程", "发送文字、图片和文件，使用语音输入；查看 Markdown 回复、命令、文件变更与工具执行记录。")
                        item("执行选项", "选择可用模型、推理强度、响应速度和权限模式；执行期间可以停止当前任务。可选项以当前 Codex 支持的能力为准。")
                        item("个性外观", "支持跟随系统、明亮和暗黑模式，并保留外观选择。")
                        item("远程控制", "主动开启并配对后，可通过 AI 小程序向这台 Mac 发送任务、查看进度和同步的额度信息。")
                    }
                    section("一条消息如何执行", symbol: "arrow.triangle.branch") {
                        item("1 · 提交指令", "你在 CloudCodex 中选择会话，输入要求并选择附件和执行设置。")
                        item("2 · 本机执行", "CloudCodex 通过本机 Codex app-server 的标准输入／输出通道交换结构化请求。Codex 根据会话上下文、模型配置及权限处理任务，调用需要的工具。")
                        item("3 · 实时展示", "执行事件持续返回，CloudCodex 将回复、工具进度和状态整理成可阅读的消息。历史记录按需加载，减少长会话一次性加载的开销。")
                    }
                    section("等待发送与立即引导", symbol: "text.badge.plus") {
                        item("等待发送", "任务执行时继续发送消息，会进入该会话的等待列表。当前任务结束后按顺序提交，切换会话不会清空队列。文字、附件和排队时选择的执行设置会保留。")
                        item("立即引导", "点击等待消息上的“立即引导”，通过 turn/steer 把补充要求发送给当前正在执行的轮次；沿用当前轮次的模型，不另外开启一轮任务。")
                        item("失败与保存", "等待消息可删除；发送失败会保留消息并显示原因。目前本地等待队列仅保留在本次应用运行期间，退出或重启应用会清空尚未发送的消息。")
                    }
                    section("连接与数据边界", symbol: "lock.shield") {
                        Text("本地使用复用 Codex 的登录和配置，无需在 CloudCodex 中另填 API Key。这不代表离线推理：请求和上下文是否发送到模型服务，取决于你的 Codex 配置。工具对文件和命令的访问由所选权限约束。")
                        Text("远程控制需要 Mac 上的 CloudCodex 保持运行、网络可用且设备已配对。远程服务负责转发任务与同步状态，任务仍交给这台 Mac 上的 Codex 执行；关闭远程控制不影响本地会话。设备密钥保存在 macOS 钥匙串中。")
                        Text("请只提交有权处理的内容，并在选择“完全访问”、执行命令或发送敏感附件前确认任务范围。")
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Text("CloudCodex · macOS 原生客户端")
                .font(.caption).foregroundStyle(.secondary)
                .padding(12)
        }
        .frame(minWidth: 540, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func section<Content: View>(_ title: String, symbol: String,
                                       @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline).foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 12, content: content)
                .font(.body)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
    }

    private func item(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.semibold)
            Text(detail).foregroundStyle(.secondary)
        }
    }
}
