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
    private var sessionID: UUID?
    private var isStarting = false
    private var isFinishing = false
    private var finishTimeout: Task<Void, Never>?
    private var lastPublishedText = ""

    var onTranscript: ((String) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var currentDraft: (() -> String)?

    func toggle(currentText: String) {
        if isStarting { stop(); return }
        if isFinishing { return }
        if audioEngine.isRunning {
            finishRecording()
        } else {
            let id = UUID()
            sessionID = id
            isStarting = true
            onStatus?("正在准备麦克风…")
            Task { await authorizeAndStart(currentText: currentText, session: id) }
        }
    }

    func stop() {
        sessionID = nil
        isStarting = false
        isFinishing = false
        finishTimeout?.cancel()
        finishTimeout = nil
        stopAudio()
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        onRecordingChanged?(false)
        onStatus?("")
    }

    private func stopAudio() {
        if audioEngine.isRunning { audioEngine.stop() }
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    private func finishRecording() {
        guard let id = sessionID else { return }
        isFinishing = true
        stopAudio()
        recognitionRequest?.endAudio()
        onStatus?("正在整理最后一句…")
        finishTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.sessionID == id else { return }
            self.stop()
            self.onStatus?("已保留识别内容，请检查末句。")
        }
    }

    private func authorizeAndStart(currentText: String, session: UUID) async {
        let speechAllowed = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard sessionID == session else { return }
        guard speechAllowed else {
            stop()
            onError?("没有语音识别权限，请在系统设置的“隐私与安全性”中允许。")
            return
        }
        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard sessionID == session else { return }
        guard microphoneAllowed else {
            stop()
            onError?("没有麦克风权限，请在系统设置的“隐私与安全性”中允许。")
            return
        }
        startRecording(currentText: currentDraft?() ?? currentText, session: session)
    }

    private func startRecording(currentText: String, session: UUID) {
        isStarting = false
        guard let recognizer, recognizer.isAvailable else {
            stop()
            onError?("当前无法使用系统语音识别。")
            return
        }

        prefix = currentText
        lastPublishedText = currentText
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = ["CloudCodex", "Codex", "SwiftUI", "Git", "GitHub", "API", "Redis", "macOS", "小程序", "工作区", "会话", "待发送", "立即引导"]
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            stop()
            onError?("没有可用的麦克风输入，请检查系统声音设置与麦克风连接。")
            return
        }
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            request.append(buffer)
        }
        tapInstalled = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.sessionID == session else { return }
                if let transcript = result?.bestTranscription.formattedString {
                    if let draft = self.currentDraft?(), draft != self.lastPublishedText {
                        self.stop()
                        self.onStatus?("检测到手动编辑，已停止语音，保留你的修改。")
                        return
                    }
                    let updated = Self.appendingTranscript(transcript, to: self.prefix)
                    if updated != self.lastPublishedText {
                        self.lastPublishedText = updated
                        self.onTranscript?(updated)
                    }
                }
                if result?.isFinal == true {
                    self.stop()
                    self.onStatus?("转写完成，请确认后发送。")
                } else if let error {
                    self.stop()
                    self.onStatus?("识别已停止，已保留现有文字。")
                    self.onError?("语音识别中断：\(error.localizedDescription)。已保留现有文字，可再次点击麦克风继续。")
                }
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            onRecordingChanged?(true)
            onStatus?("正在听写普通话 · 再点麦克风结束")
        } catch {
            stop()
            onError?("无法启动麦克风：\(error.localizedDescription)")
        }
    }

    static func appendingTranscript(_ transcript: String, to prefix: String) -> String {
        guard !transcript.isEmpty else { return prefix }
        let separator = prefix.isEmpty || prefix.last?.isWhitespace == true ? "" : "\n"
        return prefix + separator + transcript
    }
}
