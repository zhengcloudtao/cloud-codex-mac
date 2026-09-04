import AVFoundation
import Foundation
import Speech

@MainActor
final class SpeechInputController {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var prefix = ""

    var onTranscript: ((String) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    var onError: ((String) -> Void)?

    func toggle(currentText: String) {
        if audioEngine.isRunning {
            stop()
        } else {
            Task { await authorizeAndStart(currentText: currentText) }
        }
    }

    func stop() {
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        onRecordingChanged?(false)
    }

    private func authorizeAndStart(currentText: String) async {
        let speechAllowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechAllowed else {
            onError?("没有语音识别权限，请在系统设置的“隐私与安全性”中允许。")
            return
        }
        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard microphoneAllowed else {
            onError?("没有麦克风权限，请在系统设置的“隐私与安全性”中允许。")
            return
        }
        startRecording(currentText: currentText)
    }

    private func startRecording(currentText: String) {
        stop()
        guard let recognizer, recognizer.isAvailable else {
            onError?("当前无法使用系统语音识别。")
            return
        }

        prefix = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }
        tapInstalled = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let transcript = result?.bestTranscription.formattedString {
                    let separator = self.prefix.isEmpty ? "" : " "
                    self.onTranscript?(self.prefix + separator + transcript)
                }
                if error != nil || result?.isFinal == true { self.stop() }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            onRecordingChanged?(true)
        } catch {
            stop()
            onError?("无法启动麦克风：\(error.localizedDescription)")
        }
    }
}
