import Foundation

struct RemoteSpeechVoice: Codable, Equatable {
    let id: String
    let name: String
    let language: String
}

@MainActor
enum RemoteSpeechVoiceCatalog {
    static let defaultVoiceID = "Daniel"
    private static var saved: [RemoteSpeechVoice] = []
    private static var refreshed = Date.distantPast
    static func available() -> [RemoteSpeechVoice] {
        if Date().timeIntervalSince(refreshed) < 60 { return saved }
        let job = Process(), output = Pipe()
        job.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        job.arguments = ["-v", "?"]
        job.standardOutput = output; job.standardError = FileHandle.nullDevice
        do {
            try job.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            job.waitUntilExit()
            guard job.terminationStatus == 0, data.count < 262144 else { return saved }
            saved = parse(String(decoding: data, as: UTF8.self)); refreshed = Date()
        } catch { return saved }
        return saved
    }
    static func parse(_ text: String) -> [RemoteSpeechVoice] {
        guard let regex = try? NSRegularExpression(pattern: #"^(.*?)\s+([a-z]{2}_[A-Z]{2})\s+#"#) else { return [] }
        var seen = Set<String>(), voices: [RemoteSpeechVoice] = []
        for line in text.split(separator: "\n").map(String.init) {
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let nameRange = Range(match.range(at: 1), in: line), let languageRange = Range(match.range(at: 2), in: line) else { continue }
            let name = String(line[nameRange]).trimmingCharacters(in: .whitespaces), language = String(line[languageRange])
            // macOS may add a localized language suffix after a voice is first used.
            // These two CLI aliases remain stable across that display-name change.
            let british = language == "en_GB" && (name == "Daniel" || name.hasPrefix("Daniel ("))
            let chinese = language == "zh_CN" && (name == "Tingting" || name.hasPrefix("Tingting ("))
            let id = british ? defaultVoiceID : chinese ? "Tingting" : name
            guard (language.hasPrefix("zh_") || british), !id.isEmpty, id.utf8.count <= 120, seen.insert(id).inserted else { continue }
            voices.append(.init(id: id, name: id, language: language))
        }
        func priority(_ voice: RemoteSpeechVoice) -> String {
            (voice.id == defaultVoiceID ? "0" : voice.id == "Tingting" ? "1" : "2") + voice.id
        }
        return Array(voices.sorted { priority($0) < priority($1) }.prefix(16))
    }
}
