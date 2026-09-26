import Foundation
import SwiftUI

struct CodexPersonalSkill: Identifiable, Equatable {
    let name: String
    let description: String
    let path: String
    let enabled: Bool
    let displayName: String?
    let shortDescription: String?

    var id: String { path }

    var title: String {
        let value = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? name : value
    }

    var summary: String {
        let preferred = shortDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return preferred.isEmpty ? description : preferred
    }

    var abbreviatedPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    init?(json: [String: Any], personalSkillRoots: [String] = Self.defaultPersonalSkillRoots) {
        guard json["scope"] as? String == "user",
              let name = json["name"] as? String,
              let description = json["description"] as? String,
              let path = json["path"] as? String,
              let enabled = json["enabled"] as? Bool,
              Self.isUserCreatedSkill(path: path, roots: personalSkillRoots) else { return nil }
        let interface = json["interface"] as? [String: Any]
        self.name = name
        self.description = description
        self.path = path
        self.enabled = enabled
        self.displayName = interface?["displayName"] as? String
        self.shortDescription = interface?["shortDescription"] as? String
            ?? json["shortDescription"] as? String
    }

    static func parseListResponse(
        _ response: [String: Any],
        personalSkillRoots: [String] = defaultPersonalSkillRoots
    ) -> [Self] {
        let entries = response["data"] as? [[String: Any]] ?? []
        var skillsByPath: [String: Self] = [:]
        for entry in entries {
            for row in entry["skills"] as? [[String: Any]] ?? [] {
                guard let skill = Self(json: row, personalSkillRoots: personalSkillRoots) else { continue }
                skillsByPath[skill.path] = skill
            }
        }
        return skillsByPath.values.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static var defaultPersonalSkillRoots: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent(".codex/skills").path,
            home.appendingPathComponent(".agents/skills").path
        ]
    }

    private static func isUserCreatedSkill(path: String, roots: [String]) -> Bool {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        for root in roots {
            let standardizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
            guard standardizedPath.hasPrefix(standardizedRoot + "/") else { continue }
            let relativePath = String(standardizedPath.dropFirst(standardizedRoot.count + 1))
            guard let firstComponent = relativePath.split(separator: "/").first else { continue }
            if !firstComponent.hasPrefix(".") { return true }
        }
        return false
    }
}

struct CodexPersonalSkillsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(.indigo.gradient, in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text("我的技能")
                        .font(.headline)
                    Text("当前 Codex 识别到的自建技能")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await model.refreshPersonalSkills(forceReload: true) }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoadingPersonalSkills)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(18)

            Divider()

            Group {
                if model.isLoadingPersonalSkills && model.personalSkills.isEmpty {
                    ProgressView("正在读取个人技能…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.personalSkills.isEmpty {
                    ContentUnavailableView {
                        Label("没有个人技能", systemImage: "books.vertical")
                    } description: {
                        Text(model.personalSkillsError ?? "在个人技能目录中创建技能后，它会显示在这里。")
                    } actions: {
                        Button("重新读取") {
                            Task { await model.refreshPersonalSkills(forceReload: true) }
                        }
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(model.personalSkills) { skill in
                                skillCard(skill)
                            }
                        }
                        .padding(22)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                Text("自建技能 \(model.personalSkills.count) 个")
                Spacer()
                if model.isLoadingPersonalSkills {
                    ProgressView().controlSize(.small)
                }
                Text("数据来自 Codex app-server · skills/list")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .frame(width: 760, height: 620)
        .task {
            await model.refreshPersonalSkills(forceReload: model.personalSkills.isEmpty)
        }
    }

    private func skillCard(_ skill: CodexPersonalSkill) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(skill.enabled ? Color.indigo : Color.secondary)
                .frame(width: 38, height: 38)
                .background((skill.enabled ? Color.indigo : Color.secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(skill.title)
                        .font(.headline)
                        .textSelection(.enabled)
                    Text("我创建的")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.indigo)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.indigo.opacity(0.12), in: Capsule())
                    Text(skill.enabled ? "已启用" : "已停用")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(skill.enabled ? Color.green : Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background((skill.enabled ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
                    Spacer(minLength: 0)
                    Text("$\(skill.name)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(skill.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Label(skill.abbreviatedPath, systemImage: "folder")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.28), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
    }
}
