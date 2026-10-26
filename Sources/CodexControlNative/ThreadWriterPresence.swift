import Foundation

/// Inspect existing kernel lock holders without resuming threads or acquiring a lock.
enum ThreadWriterPresence {
    static func read(home: URL, ownPID: Int32) -> Set<String>? {
        let folder = home.appendingPathComponent("thread-writer-locks").standardizedFileURL
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-n", "-P", "-F", "pfnk", "+d", folder.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // lsof returns 1 when the directory contains no open files.
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else { return nil }
        return parse(String(decoding: bytes, as: UTF8.self), folder: folder, ownPID: ownPID)
    }

    static func parse(_ text: String, folder: URL, ownPID: Int32) -> Set<String> {
        var pid: Int32?
        var locked = false
        var result: Set<String> = []
        for line in text.split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": pid = Int32(value); locked = false
            case "f": locked = false
            case "k": locked = !value.trimmingCharacters(in: .whitespaces).isEmpty
            case "n":
                guard let pid, pid > 0, pid != ownPID, locked else { continue }
                let url = URL(fileURLWithPath: value).standardizedFileURL
                guard url.deletingLastPathComponent().path == folder.standardizedFileURL.path,
                      url.pathExtension == "lock" else { continue }
                let id = url.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: id) != nil else { continue }
                result.insert(id)
            default: break
            }
        }
        return result
    }
}
