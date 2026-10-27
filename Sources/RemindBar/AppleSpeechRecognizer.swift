import AVFoundation
import Speech
import RemindCore

/// Apple's on-device recognizer behind the `SpeechRecognizing` contract. Audio never leaves the Mac unless the user
/// explicitly allows server recognition for a language that has no offline model.
@MainActor
final class AppleSpeechRecognizer: SpeechRecognizing {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Bumped on every start/cancel so callbacks of an earlier recognition are ignored.
    private var token = 0
    private var lastLevelAt = Date.distantPast

    func requestAuthorization() async -> VoiceAuthResult {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            return .deniedMicrophone
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { return .deniedMicrophone }
        default:
            break
        }
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        return status == .authorized ? .granted : .deniedSpeech
    }

    func start(_ options: VoiceStartOptions, onEvent: @escaping @MainActor (SpeechEvent) -> Void) throws {
        cancel()
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: options.locale)), recognizer.isAvailable else {
            throw VoiceFailure.recognizerUnavailable
        }
        let onDevice = recognizer.supportsOnDeviceRecognition
        if !onDevice && !options.allowServerRecognition { throw VoiceFailure.onDeviceUnavailable }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = onDevice
        request.addsPunctuation = true
        request.taskHint = .dictation
        request.contextualStrings = Array(options.contextualStrings.prefix(100))

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceFailure.audio("没有可用的麦克风") }

        token += 1
        let current = token
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            request.append(buffer)
            let level = AppleSpeechRecognizer.level(of: buffer)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.token == current else { return }
                    let now = Date()
                    guard now.timeIntervalSince(self.lastLevelAt) > 0.06 else { return }
                    self.lastLevelAt = now
                    onEvent(.level(level))
                }
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw VoiceFailure.audio(error.localizedDescription)
        }

        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let failure = error.map { AppleSpeechRecognizer.map($0 as NSError) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.token == current else { return }
                    if let text, !text.isEmpty {
                        onEvent(isFinal ? .final(text) : .partial(text))
                    } else if isFinal {
                        onEvent(.final(""))
                    }
                    if let failure, !isFinal { onEvent(.failed(failure)) }
                }
            }
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
    }

    func cancel() {
        token += 1
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    // MARK: helpers

    /// Microphone level 0...1 (−50 dB … 0 dB).
    nonisolated private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        let rms = (sum / Float(count)).squareRoot()
        let db = 20 * log10(max(rms, 0.000_01))
        return max(0, min(1, (db + 50) / 50))
    }

    nonisolated private static func map(_ error: NSError) -> VoiceFailure {
        if error.domain == "kAFAssistantErrorDomain" {
            switch error.code {
            case 1110: return .noSpeech
            case 1101, 1107, 216: return .recognizerUnavailable
            default: break
            }
        }
        return .other(error.localizedDescription)
    }
}
