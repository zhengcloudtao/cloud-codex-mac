import Foundation
import CoreFoundation

/// Share tool definitions and installed resources, never account authentication/state.
enum CodexSharedTools {
    static let featureKeys = Set(["remote_plugin", "js_repl", "mcp_2026_07_28", "codex_apps_mcp_2026_07_28", "mcp_connection_sharing"])

    static func arguments(source: [String: Any], account: [String: Any]) throws -> [String] {
        var result: [String] = []
        for section in ["plugins", "mcp_servers", "skills"] {
            guard let values = source[section] as? [String: Any] else { continue }
            let local = account[section] as? [String: Any] ?? [:]
            let merged = values.merging(local) { _, accountValue in accountValue }
            // Codex CLI splits dotted override paths literally; quote keys inside
            // an inline TOML table so plugin IDs do not acquire quote characters.
            result += ["-c", "\(section)=\(try toml(merged))"]
        }
        let localFeatures = account["features"] as? [String: Any] ?? [:]
        for (key, value) in (source["features"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key })
        where featureKeys.contains(key) && localFeatures[key] == nil {
            result += ["-c", "features.\(key)=\(try toml(value))"]
        }
        return result
    }

    static func prepareResources(source: URL, account: URL) throws {
        guard source.resolvingSymlinksInPath() != account.resolvingSymlinksInPath() else { return }
        // Do not link the whole plugin root: it can contain account-specific runtime state.
        for relative in ["skills", "plugins/cache"] {
            try linkMissing(source: source.appendingPathComponent(relative), target: account.appendingPathComponent(relative))
        }
    }

    private static func linkMissing(source: URL, target: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return }
        if target.resolvingSymlinksInPath() == source.resolvingSymlinksInPath() { return }
        // An existing custom link belongs to this account, even if it is currently broken.
        if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil { return }
        var directory: ObjCBool = false
        if fm.fileExists(atPath: target.path, isDirectory: &directory) {
            guard directory.boolValue else { return }
        } else {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
        }
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            let destination = target.appendingPathComponent(item.lastPathComponent)
            if (try? fm.destinationOfSymbolicLink(atPath: destination.path)) != nil { continue }
            if !fm.fileExists(atPath: destination.path) {
                try fm.createSymbolicLink(at: destination, withDestinationURL: item)
            } else if (try item.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                try linkMissing(source: item, target: destination)
            }
        }
    }

    private static func quoted(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private static func toml(_ value: Any) throws -> String {
        if let text = value as? String { return try quoted(text) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        }
        if let array = value as? [Any] { return "[" + (try array.map(toml)).joined(separator: ", ") + "]" }
        if let object = value as? [String: Any] {
            return "{ " + (try object.keys.sorted().filter { !(object[$0] is NSNull) }.map {
                "\(try quoted($0)) = \(try toml(object[$0]!))"
            }).joined(separator: ", ") + " }"
        }
        throw ModelProviderError.message("公共工具配置包含无法识别的值，未修改账号配置。")
    }
}
