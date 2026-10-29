import Foundation
import Speech

/// Receives only an ESP recording file. It never opens the Mac microphone or executes a task.
@MainActor
final class RemoteVoiceTranscriber {
    private var recognition: SFSpeechRecognitionTask?
    private var timeout: Task<Void, Never>?
    private var continuation: CheckedContinuation<String, Error>?

    func transcribe(_ audio: Data) async throws -> String {
        guard Self.isSupportedRecording(audio) else {
            throw RemoteControlError.server("录音格式或大小无效")
        }
        let authorization = await withCheckedContinuation { callback in
            SFSpeechRecognizer.requestAuthorization { callback.resume(returning: $0) }
        }
        try Task.checkCancellation()
        guard authorization == .authorized else {
            throw RemoteControlError.server("请在电脑允许 CloudCodex 使用语音识别")
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable else {
            throw RemoteControlError.server("电脑语音识别暂不可用，请稍后重新录音")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("recording.wav")
        defer { try? FileManager.default.removeItem(at: directory) }
        try audio.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = ["CloudCodex", "工作区", "会话", "小程序", "Git", "ESP"]
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { callback in
                continuation = callback
                recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    Task { @MainActor in
                        if let result, result.isFinal {
                            let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                            self?.finish(text.isEmpty ? .failure(RemoteControlError.server("未识别到内容，请重新录音")) : .success(text))
                        } else if error != nil {
                            self?.finish(.failure(RemoteControlError.server("语音识别失败，请重新录音")))
                        }
                    }
                }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
                    self?.finish(.failure(RemoteControlError.server("语音识别超时，请重新录音")))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }
    nonisolated static func isSupportedRecording(_ data: Data) -> Bool {
        guard data.count >= 3244, data.count <= 960044, data.count % 2 == 0 else { return false }
        let b = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i+1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i+2) << 16 }
        return String(bytes: b[0..<4], encoding: .ascii) == "RIFF"
            && u32(4) == b.count - 8
            && String(bytes: b[8..<16], encoding: .ascii) == "WAVEfmt "
            && u32(16) == 16 && u16(20) == 1 && u16(22) == 1
            && u32(24) == 16000 && u32(28) == 32000 && u16(32) == 2 && u16(34) == 16
            && String(bytes: b[36..<40], encoding: .ascii) == "data" && u32(40) == b.count - 44
    }
    private func finish(_ result: Result<String, Error>) {
        guard let callback = continuation else { return }
        continuation = nil
        timeout?.cancel(); timeout = nil
        recognition?.cancel(); recognition = nil
        callback.resume(with: result)
    }
}
