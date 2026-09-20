import SwiftUI

struct ComputerUseApprovalRequestsPanel: View {
    let requests: [ComputerUseApprovalRequest]
    let submit: (String, ComputerUseApprovalRequest.Decision) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ForEach(requests) { request in
                    ComputerUseApprovalRequestCard(request: request) { submit(request.id, $0) }
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(maxHeight: 330)
        .background(Color.blue.opacity(0.035))
    }
}

private struct ComputerUseApprovalRequestCard: View {
    let request: ComputerUseApprovalRequest
    let submit: (ComputerUseApprovalRequest.Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("电脑控制需要授权", systemImage: "hand.raised.fill")
                    .font(.headline).foregroundStyle(.blue)
                Spacer()
                Text("等待确认").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
            Text("允许 CloudCodex 控制 \(request.applicationName)？")
                .font(.callout.weight(.semibold)).textSelection(.enabled)
            VStack(alignment: .leading, spacing: 4) {
                if let bundleIdentifier = request.bundleIdentifier {
                    ComputerUseDetailRow(label: "应用标识", value: bundleIdentifier)
                }
                if let toolName = request.toolName {
                    ComputerUseDetailRow(label: "调用工具", value: toolName)
                }
                if let warning = request.warning, !warning.isEmpty {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if let error = request.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack(spacing: 9) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(ceil(request.expiresAt.timeIntervalSince(context.date))))
                    Text("\(remaining) 秒后自动取消")
                        .font(.caption).foregroundStyle(remaining <= 10 ? Color.orange : Color.secondary)
                }
                Spacer()
                Button("拒绝") { submit(.decline) }.buttonStyle(.bordered).disabled(request.isSubmitting)
                if request.allowsAlways {
                    Button("始终允许") { submit(.allowAlways) }.buttonStyle(.bordered).disabled(request.isSubmitting)
                }
                Button(request.isSubmitting ? "正在提交…" : "本次会话允许") { submit(.allowSession) }
                    .buttonStyle(.borderedProminent).disabled(request.isSubmitting)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.blue.opacity(0.35)))
    }
}

private struct ComputerUseDetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
        .font(.caption)
    }
}
