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
                    section("它与 Codex 有什么不同", symbol: "arrow.left.arrow.right") {
                        item("Codex 是执行核心", "Codex 负责登录、模型连接、会话上下文、推理以及工具调用，是实际读取代码、修改文件和执行命令的一方。")
                        item("CloudCodex 是管理与控制界面", "CloudCodex 通过本机 Codex app-server 管理同一批真实会话，并重新组织工作区、消息、执行过程和结果；它不会替换 Codex，也不会提供另一套模型、账号或额度。")
                        item("远程能力是额外入口", "Codex 仍在这台 Mac 上执行。CloudCodex 只是把经过配对的手机请求转交给本机 Codex，再将任务状态和结果同步回小程序。")
                    }
                    section("远程控制：手机发起，Mac 执行", symbol: "antenna.radiowaves.left.and.right") {
                        item("配对后使用", "在 Mac 上主动开启“允许远程任务”，再使用限时配对码连接 AI 小程序。没有开启或没有完成配对时，CloudCodex 不会领取远程任务。")
                        item("远程发起与查看", "可在小程序中选择这台 Mac 已授权的工作区和会话，发送新任务，并查看排队状态、执行进度、完成结果、Codex 额度与设备状态。")
                        item("执行仍受本机控制", "任务由这台 Mac 上正在运行的 CloudCodex 领取，并交给本机 Codex 执行；使用的模型和权限以任务设置及本机可用能力为准。关闭远程任务后不再领取新任务，已经开始的任务会继续完成。")
                        item("不开放公网端口", "CloudCodex 主动通过 HTTPS 与远程服务同步，不在 Mac 上开放公网监听端口。设备凭据保存在 macOS 钥匙串中，远程服务只负责配对、转发和状态同步。")
                    }
                    section("CloudCodex 优化了什么", symbol: "sparkles") {
                        item("多工作区集中管理", "在一个原生窗口中浏览工作区、最近会话和收藏会话；支持搜索，并按最近一次用户发起消息的时间整理会话。")
                        item("任务过程更连续", "集中展示回复、工具调用和任务状态；任务执行时可以继续排队消息、编辑待发送内容或立即引导当前轮次。Codex 请求补充输入时会直接在会话内显示，超时后自动跳过。")
                        item("结果更容易找回", "未查看的完成会话可显示提醒和 Dock 数量；Markdown 按格式渲染，文件与图片可以在应用内预览，也可从预览中在 Finder 定位。")
                        item("运行状态更透明", "集中显示本机、网络与 GPT 连接状态，并在能够识别时展示套餐额度、系统温度、CPU 和存储状态；未知数据不会伪装成有效数值。")
                        item("手机也能掌握进度", "离开 Mac 时仍可通过配对的小程序发起任务、查看执行结果和设备状态，但代码与命令始终在已授权的 Mac 上处理。")
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
