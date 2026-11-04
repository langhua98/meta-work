import AVFoundation
import Speech
import SwiftUI

// 点一下麦克风开始说话，边说边把文字填进输入框；停顿两秒或再点一下就停，文字留在输入框里，看一眼再发。用系统的语音识别（中文）。

@MainActor
final class SpeechInput: ObservableObject {
    @Published var text = ""
    @Published var recording = false
    /// 刚停：最后一句识别结果还在路上
    @Published var finishing = false
    @Published var error = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastChange = Date()
    private var watcher: Task<Void, Never>?

    func start() {
        error = ""
        text = ""
        recording = true
        Task {
            guard await Self.authorized() else {
                fail("没有语音识别或麦克风权限，去 设置 > 小橘推送 里打开")
                return
            }
            guard recording else { return }
            do { try begin() } catch { fail("录音开不了：\(error.localizedDescription)"); return }
            watch()
        }
    }

    /// 说完停顿 2 秒自动停；一直没说话 8 秒也停；最长 60 秒
    private func watch() {
        lastChange = Date()
        let started = Date()
        watcher?.cancel()
        watcher = Task { @MainActor [weak self] in
            while let self, self.recording, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                let quiet = Date().timeIntervalSince(self.lastChange)
                if (!self.text.isEmpty && quiet > 2) || (self.text.isEmpty && quiet > 8)
                    || Date().timeIntervalSince(started) > 60 {
                    Haptics.tap()
                    self.stop()
                }
            }
        }
    }

    func stop() {
        guard recording else { return }
        recording = false
        finishing = true
        watcher?.cancel()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        // 留一点时间让最后一句识别出来，再收尾
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.finishing = false
            self?.task?.finish()
            self?.task = nil
            self?.request = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func begin() throws {
        guard let recognizer, recognizer.isAvailable else { throw PushError("语音识别现在用不了") }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        request = req
        task = recognizer.recognitionTask(with: req) { [weak self] result, _ in
            guard let result else { return }
            let s = result.bestTranscription.formattedString
            Task { @MainActor in
                if self?.text != s { self?.lastChange = Date() }
                self?.text = s
            }
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buf, _ in req?.append(buf) }
        engine.prepare()
        try engine.start()
    }

    private func fail(_ s: String) {
        recording = false
        error = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.error = "" }
    }

    private static func authorized() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
