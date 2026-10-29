import Foundation

enum StartupConversationPage: String, CaseIterable, Identifiable {
    case recent
    case favorites
    case unread

    static let storageKey = "CloudCodex.startupConversationPage.v1"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recent: "最近会话"
        case .favorites: "收藏会话"
        case .unread: "红点会话"
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        defaults.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .recent
    }
}
