import Foundation
import Darwin

/// Share transcripts and the Codex state database, never authentication files.
/// Existing account transcripts are merged conservatively and retained as backups.
enum CodexSharedConversations {
    static func prepare(home: URL, accountHomes: [URL]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let descriptor = open(home.appendingPathComponent("cloudcodex-shared-conversations.lock").path,
                              O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        for name in ["sessions", "archived_sessions"] {
            let destination = home.appendingPathComponent(name)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            for accountHome in accountHomes where accountHome.resolvingSymlinksInPath() != home.resolvingSymlinksInPath() {
                try fm.createDirectory(at: accountHome, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
                let source = accountHome.appendingPathComponent(name)
                if let link = try? fm.destinationOfSymbolicLink(atPath: source.path) {
                    let resolved = URL(fileURLWithPath: link, relativeTo: accountHome).standardizedFileURL.resolvingSymlinksInPath()
                    guard resolved == destination.resolvingSymlinksInPath() else {
                        throw ModelProviderError.message("会话目录已指向其他位置，未改动原目录。")
                    }
                    continue
                }
                if fm.fileExists(atPath: source.path) {
                    try merge(source, into: destination)
                    let backup = accountHome.appendingPathComponent("\(name).before-sharing-\(UUID().uuidString)")
                    try fm.moveItem(at: source, to: backup)
                    do { try fm.createSymbolicLink(at: source, withDestinationURL: destination) }
                    catch { try? fm.moveItem(at: backup, to: source); throw error }
                } else {
                    try fm.createSymbolicLink(at: source, withDestinationURL: destination)
                }
            }
        }
    }

    private static func merge(_ source: URL, into destination: URL) throws {
        let fm = FileManager.default
        for item in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw ModelProviderError.message("旧会话目录含有链接，未替换原目录。")
            }
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if values.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                try merge(item, into: target)
            } else if !fm.fileExists(atPath: target.path) {
                try fm.copyItem(at: item, to: target)
            } else {
                let incoming = try Data(contentsOf: item, options: .mappedIfSafe)
                let existing = try Data(contentsOf: target, options: .mappedIfSafe)
                // A shorter prefix is an older copy. Divergent histories must never be overwritten.
                if existing.starts(with: incoming) { continue }
                guard incoming.starts(with: existing) else {
                    throw ModelProviderError.message("发现内容冲突的同名会话，已保留两份原文件，未替换账号目录。")
                }
                let backup = target.appendingPathExtension("before-sharing-\(UUID().uuidString)")
                try fm.copyItem(at: target, to: backup)
                try incoming.write(to: target, options: .atomic)
            }
        }
    }
}
