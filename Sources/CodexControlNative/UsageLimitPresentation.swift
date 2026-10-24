import Foundation
import SwiftUI

/// Display-only interpretation of the CLI error. Keep the original error and
/// terminal task behavior; a missing timezone must never be guessed as Beijing time.
struct UsageLimitPresentation {
    let recoveryTime: String?
    let showsUsageLink: Bool
    let showsPlanLink: Bool

    init?(_ message: String) {
        guard message.localizedCaseInsensitiveContains("you've hit your usage limit") else { return nil }
        showsUsageLink = message.contains("https://chatgpt.com/settings/usage")
        showsPlanLink = message.contains("https://chatgpt.com/explore/pro")
        recoveryTime = Self.recoveryTime(message)
    }

    private static func recoveryTime(_ text: String) -> String? {
        let pattern = #"(?i)try again at\s+([A-Za-z]{3}\s+\d{1,2}(?:st|nd|rd|th)?,\s*\d{4}\s+\d{1,2}:\d{2}\s*[AP]M)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let raw = String(text[range]).replacingOccurrences(of: #"(?<=\d)(st|nd|rd|th)"#, with: "", options: [.regularExpression, .caseInsensitive])
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.timeZone = TimeZone(secondsFromGMT: 0)
        input.dateFormat = "MMM d, yyyy h:mm a"
        guard let date = input.date(from: raw) else { return nil }
        let output = DateFormatter()
        output.locale = Locale(identifier: "zh_CN")
        output.timeZone = input.timeZone
        output.dateFormat = "yyyy年M月d日 HH:mm"
        return output.string(from: date)
    }
}

struct UsageLimitDetailView: View {
    let usageLimit: UsageLimitPresentation
    let originalError: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("当前账号的 Codex 使用额度已用尽，本次任务未能继续。")
                .font(.callout).foregroundStyle(.primary)
            if let time = usageLimit.recoveryTime {
                Label("可重试时间：" + time, systemImage: "clock")
                    .font(.callout).foregroundStyle(.primary)
                Text("服务未注明此时间的时区，请以用量页面的重置时间为准。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("请在用量页面查看重置时间，额度恢复后再重试。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                if usageLimit.showsUsageLink {
                    Link("查看用量与额度", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                }
                if usageLimit.showsPlanLink {
                    Link("查看套餐", destination: URL(string: "https://chatgpt.com/explore/pro")!)
                }
            }.font(.callout)
            DisclosureGroup("查看原始错误") {
                Text(String(originalError.prefix(8_000)))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 9)
    }
}
