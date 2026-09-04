import Foundation

struct CodexThread: Identifiable, Hashable {
    let id: String
    var name: String?
    var preview: String
    var cwd: String
    var model: String?
    var reasoningEffort: String?
    var updatedAt: Date
    var status: String

    var displayName: String {
        let title = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty { return title }
        let firstLine = preview.components(separatedBy: .newlines).first ?? ""
        return firstLine.isEmpty ? "未命名会话" : firstLine
    }

    var folderName: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let cwd = json["cwd"] as? String else { return nil }
        self.id = id
        self.name = json["name"] as? String
        self.preview = json["preview"] as? String ?? ""
        self.cwd = cwd
        self.model = json["model"] as? String
        self.reasoningEffort = json["reasoningEffort"] as? String
        let timestamp = (json["recencyAt"] as? NSNumber)?.doubleValue
            ?? (json["updatedAt"] as? NSNumber)?.doubleValue
            ?? 0
        self.updatedAt = Date(timeIntervalSince1970: timestamp)
        if let status = json["status"] as? [String: Any] {
            self.status = status["type"] as? String ?? "unknown"
        } else {
            self.status = json["status"] as? String ?? "unknown"
        }
    }
}

struct WorkspaceFolder: Identifiable, Hashable {
    let path: String
    var threadCount: Int?
    let latestUpdate: Date

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct WorkspaceCategory: Identifiable, Codable, Hashable {
    let id: String
    var name: String

    init(id: String = UUID().uuidString, name: String) {
        self.id = id
        self.name = name
    }
}

struct WorkspaceOrganization: Codable, Equatable {
    var categories: [WorkspaceCategory] = []
    var folderAssignments: [String: String] = [:]

    @discardableResult
    mutating func addCategory(named rawName: String) -> WorkspaceCategory? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !containsCategory(named: name) else { return nil }
        let category = WorkspaceCategory(name: name)
        categories.append(category)
        return category
    }

    mutating func renameCategory(id: String, to rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !categories.contains(where: { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }),
              let index = categories.firstIndex(where: { $0.id == id }) else { return false }
        categories[index].name = name
        return true
    }

    mutating func deleteCategory(id: String) {
        categories.removeAll { $0.id == id }
        folderAssignments = folderAssignments.filter { $0.value != id }
    }

    mutating func moveCategory(id: String, offset: Int) {
        guard let source = categories.firstIndex(where: { $0.id == id }) else { return }
        let destination = source + offset
        guard categories.indices.contains(destination) else { return }
        categories.swapAt(source, destination)
    }

    mutating func assignFolders(_ paths: [String], to categoryID: String?) {
        let validCategoryID = categoryID.flatMap { candidate in
            categories.contains(where: { $0.id == candidate }) ? candidate : nil
        }
        for path in paths where !path.isEmpty {
            if let validCategoryID {
                folderAssignments[path] = validCategoryID
            } else {
                folderAssignments.removeValue(forKey: path)
            }
        }
    }

    func categoryID(forFolder path: String) -> String? {
        guard let id = folderAssignments[path], categories.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private func containsCategory(named name: String) -> Bool {
        categories.contains { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }
}

struct ThreadPage {
    let threads: [CodexThread]
    let hasMore: Bool
}

struct CodexModelOption: Identifiable, Hashable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let defaultEffort: String
    let supportedEfforts: [String]

    var compactName: String {
        displayName
            .replacingOccurrences(of: "GPT-", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "Sol", with: "Sol")
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let model = json["model"] as? String,
              let displayName = json["displayName"] as? String,
              let defaultEffort = json["defaultReasoningEffort"] as? String else { return nil }
        self.id = id
        self.model = model
        self.displayName = displayName
        self.description = json["description"] as? String ?? ""
        self.defaultEffort = defaultEffort
        let efforts = json["supportedReasoningEfforts"] as? [[String: Any]] ?? []
        self.supportedEfforts = efforts.compactMap { $0["reasoningEffort"] as? String }
    }
}

struct PermissionProfileOption: Identifiable, Hashable {
    let id: String
    let isAllowed: Bool
    let description: String?

    var displayName: String {
        switch id {
        case ":read-only": return "只读"
        case ":workspace": return "工作区"
        case ":danger-full-access": return "完全访问"
        default: return id
        }
    }

    var iconName: String {
        switch id {
        case ":read-only": return "eye"
        case ":workspace": return "folder.badge.gearshape"
        case ":danger-full-access": return "exclamationmark.shield"
        default: return "shield"
        }
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let allowed = json["allowed"] as? Bool else { return nil }
        self.id = id
        self.isAllowed = allowed
        self.description = json["description"] as? String
    }
}

struct ComposerAttachment: Identifiable, Hashable {
    let id = UUID()
    let url: URL

    var isImage: Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]
            .contains(url.pathExtension.lowercased())
    }

    var userInput: [String: Any] {
        if isImage {
            return ["type": "localImage", "path": url.path]
        }
        return ["type": "mention", "name": url.lastPathComponent, "path": url.path]
    }
}

struct ChatMessage: Identifiable, Hashable {
    enum Role: String { case user, assistant, activity }

    enum ActivityKind: String, Hashable {
        case status, reasoning, plan, command, file, tool, web, collaboration, warning

        var iconName: String {
            switch self {
            case .status: return "sparkles"
            case .reasoning: return "brain.head.profile"
            case .plan: return "list.bullet.clipboard"
            case .command: return "terminal"
            case .file: return "doc.badge.gearshape"
            case .tool: return "wrench.and.screwdriver"
            case .web: return "globe"
            case .collaboration: return "person.2"
            case .warning: return "exclamationmark.triangle"
            }
        }
    }

    let id: String
    let role: Role
    var text: String
    var isStreaming: Bool = false
    var activityKind: ActivityKind? = nil
    var activityTitle: String? = nil
    var activityStatus: String? = nil
    var startedAt: Date? = nil
    var completedAt: Date? = nil
}

enum CodexClientError: LocalizedError {
    case binaryNotFound
    case notRunning
    case invalidResponse
    case server(String)
    case process(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "找不到 Codex。请先安装 Codex 桌面版或命令行工具。"
        case .notRunning:
            return "Codex 本地服务尚未连接。"
        case .invalidResponse:
            return "Codex 返回了无法识别的数据。"
        case .server(let message), .process(let message):
            return message
        }
    }
}
