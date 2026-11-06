import Foundation
import AVFoundation

/// Synthesizes only the bounded hardware speech request. Never opens a microphone.
@MainActor
final class RemoteVoiceSpeaker {
    private var process: Process?
    private var timeout: Task<Void, Never>?
    private var continuation: CheckedContinuation<Void, Error>?

    func synthesize(_ text: String, voiceID: String? = nil) async throws -> Data {
        let selected = (voiceID?.isEmpty == false ? voiceID : nil) ?? RemoteSpeechVoiceCatalog.defaultVoiceID
        guard RemoteSpeechVoiceCatalog.available().contains(where: { $0.id == selected }) else {
            throw RemoteControlError.server("所选音色已不可用，请重新选择")
        }
        guard !text.isEmpty, text.count <= 120 else { throw RemoteControlError.server("播报文字过长") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("text.txt"), output = folder.appendingPathComponent("speech.wav")
        try text.write(to: input, atomically: true, encoding: .utf8)
        let job = Process()
        job.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        job.arguments = ["-v", selected, "-r", selected == RemoteSpeechVoiceCatalog.defaultVoiceID ? "180" : "220", "-f", input.path, "-o", output.path, "--file-format=WAVE", "--data-format=LEI16@16000", "--channels=1"]
        job.standardOutput = FileHandle.nullDevice; job.standardError = FileHandle.nullDevice
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (callback: CheckedContinuation<Void, Error>) in
                continuation = callback; process = job
                job.terminationHandler = { [weak self] process in
                    let status = process.terminationStatus
                    Task { @MainActor in self?.finish(status == 0 ? .success(()) : .failure(RemoteControlError.server("语音合成失败，请检查所选系统声音"))) }
                }
                do { try job.run() } catch { finish(.failure(error)); return }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { return }
                    self?.finish(.failure(RemoteControlError.server("语音合成超时")))
                }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) } }
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: output, commonFormat: .pcmFormatInt16, interleaved: false)
        guard file.length >= 1600, file.length <= 480000, file.processingFormat.sampleRate == 16000,
              file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw RemoteControlError.server("播报音频格式无效或超过30秒")
        }
        try file.read(into: buffer)
        guard let samples = buffer.int16ChannelData?[0] else { throw RemoteControlError.invalidServerResponse }
        let bytes = Int(buffer.frameLength) * 2
        var wav = Data()
        func word(_ value: UInt32, _ count: Int) { for shift in 0..<count { wav.append(UInt8(truncatingIfNeeded: value >> (shift * 8))) } }
        wav.append(contentsOf: "RIFF".utf8); word(UInt32(bytes + 36), 4)
        wav.append(contentsOf: "WAVEfmt ".utf8); word(16, 4); word(1, 2); word(1, 2)
        word(16000, 4); word(32000, 4); word(2, 2); word(16, 2)
        wav.append(contentsOf: "data".utf8); word(UInt32(bytes), 4)
        wav.append(UnsafeBufferPointer(start: UnsafeRawPointer(samples).assumingMemoryBound(to: UInt8.self), count: bytes))
        return wav
    }
    private func finish(_ result: Result<Void, Error>) {
        guard let callback = continuation else { return }
        continuation = nil; timeout?.cancel(); timeout = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil; callback.resume(with: result)
    }
}
