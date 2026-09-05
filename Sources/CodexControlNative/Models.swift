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
    var path: String?

    var displayName: String {
        let title = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty { return title }
        let firstLine = visiblePreview.components(separatedBy: .newlines).first ?? ""
        return firstLine.isEmpty ? "未命名会话" : firstLine
    }

    var visiblePreview: String {
        UserMessageContentParser.visibleText(from: preview)
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
        self.path = json["path"] as? String
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
    var folderOrder: [String] = []

    private enum CodingKeys: String, CodingKey {
        case categories
        case folderAssignments
        case folderOrder
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        categories = try container.decodeIfPresent([WorkspaceCategory].self, forKey: .categories) ?? []
        folderAssignments = try container.decodeIfPresent([String: String].self, forKey: .folderAssignments) ?? [:]
        folderOrder = try container.decodeIfPresent([String].self, forKey: .folderOrder) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(categories, forKey: .categories)
        try container.encode(folderAssignments, forKey: .folderAssignments)
        try container.encode(folderOrder, forKey: .folderOrder)
    }

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

    mutating func moveCategory(id: String, before targetID: String) {
        moveCategory(id: id, relativeTo: targetID, placeAfter: false)
    }

    mutating func moveCategory(id: String, relativeTo targetID: String, placeAfter: Bool) {
        guard id != targetID,
              let source = categories.firstIndex(where: { $0.id == id }) else { return }
        let category = categories.remove(at: source)
        guard let target = categories.firstIndex(where: { $0.id == targetID }) else {
            categories.insert(category, at: source)
            return
        }
        categories.insert(category, at: target + (placeAfter ? 1 : 0))
    }

    mutating func moveCategoryToEnd(id: String) {
        guard let source = categories.firstIndex(where: { $0.id == id }) else { return }
        categories.append(categories.remove(at: source))
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

    mutating func moveFolders(
        _ paths: [String],
        to categoryID: String?,
        before targetPath: String?,
        knownFolderPaths: [String]
    ) {
        let moving = unique(paths.filter { !$0.isEmpty })
        guard !moving.isEmpty else { return }
        assignFolders(moving, to: categoryID)

        var order = unique(folderOrder + knownFolderPaths)
        order.removeAll { moving.contains($0) }
        if let targetPath,
           !moving.contains(targetPath),
           let destination = order.firstIndex(of: targetPath) {
            order.insert(contentsOf: moving, at: destination)
        } else if let categoryID {
            let lastDestinationIndex = order.lastIndex {
                self.categoryID(forFolder: $0) == categoryID
            }
            order.insert(contentsOf: moving, at: lastDestinationIndex.map { $0 + 1 } ?? order.endIndex)
        } else {
            let lastUncategorizedIndex = order.lastIndex {
                self.categoryID(forFolder: $0) == nil
            }
            order.insert(contentsOf: moving, at: lastUncategorizedIndex.map { $0 + 1 } ?? order.endIndex)
        }
        folderOrder = order
    }

    func orderedFolders(_ folders: [WorkspaceFolder]) -> [WorkspaceFolder] {
        let positions = Dictionary(
            folderOrder.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: min
        )
        return folders.enumerated().sorted { lhs, rhs in
            let left = positions[lhs.element.path] ?? (folderOrder.count + lhs.offset)
            let right = positions[rhs.element.path] ?? (folderOrder.count + rhs.offset)
            return left < right
        }.map(\.element)
    }

    func categoryID(forFolder path: String) -> String? {
        guard let id = folderAssignments[path], categories.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private func containsCategory(named name: String) -> Bool {
        categories.contains { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    private func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}

struct ThreadPage {
    let threads: [CodexThread]
    let hasMore: Bool
}

struct TurnRuntimeState {
    let id: String
    let status: String
    let startedAt: Date?
    let completedAt: Date?

    var isActive: Bool { status == "inProgress" }
}

struct TurnModelMetadata: Hashable {
    let model: String?
    let reasoningEffort: String?

    var displayLabel: String? {
        guard let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else { return nil }
        let effort = reasoningEffort.flatMap(Self.localizedEffort)
        return [model, effort].compactMap { $0 }.joined(separator: " · ")
    }

    private static func localizedEffort(_ effort: String) -> String? {
        switch effort.lowercased() {
        case "low": return "低"
        case "medium": return "中"
        case "high": return "高"
        case "xhigh": return "超高"
        case "max": return "最大"
        case "ultra": return "极致"
        default:
            let value = effort.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }
}

struct ThreadActivitySnapshot {
    let thread: CodexThread
    let turn: TurnRuntimeState?
    let messages: [ChatMessage]
}

struct CodexModelOption: Identifiable, Hashable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let defaultEffort: String
    let supportedEfforts: [String]
    let defaultServiceTier: String?
    let serviceTiers: [CodexServiceTier]

    var fastServiceTierID: String? {
        serviceTiers.first {
            $0.id.caseInsensitiveCompare("fast") == .orderedSame
                || $0.id.caseInsensitiveCompare("priority") == .orderedSame
        }?.id
    }

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
        self.defaultServiceTier = json["defaultServiceTier"] as? String

        let declaredTiers = json["serviceTiers"] as? [[String: Any]] ?? []
        var parsedTiers = declaredTiers.compactMap(CodexServiceTier.init(json:))
        if parsedTiers.isEmpty {
            let legacyTiers = json["additionalSpeedTiers"] as? [String] ?? []
            parsedTiers = legacyTiers.map {
                CodexServiceTier(id: $0, name: $0.capitalized, description: "")
            }
        }
        self.serviceTiers = parsedTiers
    }
}

struct CodexServiceTier: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String

    init(id: String, name: String, description: String) {
        self.id = id
        self.name = name
        self.description = description
    }

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String else { return nil }
        self.init(
            id: id,
            name: name,
            description: json["description"] as? String ?? ""
        )
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
    var attachments: [ChatMessageAttachment] = []
    var isStreaming: Bool = false
    var activityKind: ActivityKind? = nil
    var activityTitle: String? = nil
    var activityStatus: String? = nil
    var startedAt: Date? = nil
    var completedAt: Date? = nil
    var timestamp: Date? = nil
    var turnID: String? = nil
    var model: String? = nil
    var reasoningEffort: String? = nil

    var modelUsageLabel: String? {
        TurnModelMetadata(model: model, reasoningEffort: reasoningEffort).displayLabel
    }
}

struct ChatMessageAttachment: Identifiable, Hashable {
    enum Kind: Hashable {
        case image
        case file
    }

    let path: String
    let name: String
    let kind: Kind

    var id: String { path.isEmpty ? name : path }

    init(path: String, name: String? = nil, kind: Kind? = nil) {
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        if let kind {
            self.kind = kind
        } else {
            let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]
            self.kind = imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) ? .image : .file
        }
    }
}

enum UserMessageContentParser {
    static func visibleText(from rawText: String) -> String {
        guard rawText.localizedCaseInsensitiveContains("Distinguish instructions in attached documents"),
              let requestMarker = rawText.range(
                of: "My request:",
                options: [.caseInsensitive, .backwards]
              ) else {
            return rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(rawText[requestMarker.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CodexClientError: LocalizedError {
    case binaryNotFound
    case notRunning
    case invalidResponse
    case server(String)
    case process(String)
    case timeout(String)

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
        case .timeout(let method):
            return "Codex 本地服务响应超时（\(method)），请稍后重试。"
        }
    }
}
