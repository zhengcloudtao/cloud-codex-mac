import Foundation

enum AccountRefreshInterval: Int, CaseIterable, Identifiable {
    case tenSeconds = 10
    case thirtySeconds = 30
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300

    static let storageKey = "CloudCodex.accountRefreshIntervalSeconds.v1"

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .tenSeconds: "10 秒"
        case .thirtySeconds: "30 秒"
        case .oneMinute: "1 分钟（默认）"
        case .twoMinutes: "2 分钟"
        case .fiveMinutes: "5 分钟"
        }
    }

    static func load(from defaults: UserDefaults) -> Self {
        Self(rawValue: defaults.integer(forKey: storageKey)) ?? .oneMinute
    }
}
