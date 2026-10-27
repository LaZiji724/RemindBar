import Foundation

// MARK: - Contract with the platform speech recognizer

public enum VoiceAuthResult: Equatable, Sendable {
    case granted, deniedMicrophone, deniedSpeech
}

public enum VoiceFailure: Error, Equatable, Sendable {
    case microphoneDenied
    case speechDenied
    case recognizerUnavailable
    case onDeviceUnavailable
    case noSpeech
    case audio(String)
    case other(String)

    public var message: String {
        switch self {
        case .microphoneDenied: return "没有麦克风权限。"
        case .speechDenied: return "没有语音识别权限。"
        case .recognizerUnavailable: return "语音识别暂时不可用。可以稍后再试，或按 fn 两次使用系统听写。"
        case .onDeviceUnavailable: return "本机没有这门语言的离线识别。可在“系统设置 › 键盘 › 听写”添加语言，或在提醒条设置里允许使用 Apple 服务器识别。"
        case .noSpeech: return "没听到声音，请再试一次。"
        case .audio(let detail): return "麦克风出错：\(detail)"
        case .other(let detail): return "语音识别出错：\(detail)"
        }
    }

    /// System Settings pane that fixes the problem, if there is one.
    public var settingsURL: String? {
        switch self {
        case .microphoneDenied: return "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .speechDenied: return "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
        case .onDeviceUnavailable: return "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
        default: return nil
        }
    }
}

public enum SpeechEvent: Equatable, Sendable {
    case partial(String)
    case final(String)
    case level(Float)
    case failed(VoiceFailure)
}

public struct VoiceStartOptions: Equatable, Sendable {
    public var locale: String
    /// Hot words (course names, platform names…) that bias recognition.
    public var contextualStrings: [String]
    /// Allow Apple's servers when the language has no offline model. Off by default for privacy.
    public var allowServerRecognition: Bool

    public init(locale: String = "zh-CN", contextualStrings: [String] = [], allowServerRecognition: Bool = false) {
        self.locale = locale
        self.contextualStrings = contextualStrings
        self.allowServerRecognition = allowServerRecognition
    }
}

@MainActor
public protocol SpeechRecognizing: AnyObject {
    func requestAuthorization() async -> VoiceAuthResult
    /// Starts capturing audio. Events are delivered on the main actor. Throws `VoiceFailure`.
    func start(_ options: VoiceStartOptions, onEvent: @escaping @MainActor (SpeechEvent) -> Void) throws
    /// No more audio; the recognizer should deliver a final result.
    func stop()
    /// Tear everything down without delivering anything. Must be safe to call repeatedly.
    func cancel()
}

// MARK: - Session state machine

public enum VoiceState: Equatable, Sendable {
    case idle, requestingPermission, listening, finishing
    case failed(VoiceFailure)
}

public typealias VoiceScheduler = (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

public enum DefaultVoiceScheduler {
    public static let main: VoiceScheduler = { delay, block in
        let item = DispatchWorkItem { MainActor.assumeIsolated { block() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }
}

/// One dictation at a time: permission → listening → (silence | max length | tap) → finishing → idle.
@MainActor
public final class VoiceSession {
    public private(set) var state: VoiceState = .idle {
        didSet { if state != oldValue { onChange?() } }
    }
    public private(set) var transcript = ""

    public var onChange: (() -> Void)?
    /// Called for every partial result (`final == false`) and once with the finished text (`final == true`).
    public var onTranscript: ((String, Bool) -> Void)?
    public var onLevel: ((Float) -> Void)?

    /// How long to wait for the first words before giving up.
    public var firstSpeechTimeout: TimeInterval = 8
    /// Pause after the last words that ends the dictation.
    public var silenceTimeout: TimeInterval = 1.8
    public var maxDuration: TimeInterval = 60
    /// How long to wait for the recognizer's final result after audio has stopped.
    public var finishGrace: TimeInterval = 1.5

    private let recognizer: SpeechRecognizing
    private let schedule: VoiceScheduler
    private var generation = 0
    private var cancelSilence: (() -> Void)?
    private var cancelMax: (() -> Void)?
    private var cancelFinish: (() -> Void)?

    public init(recognizer: SpeechRecognizing, scheduler: @escaping VoiceScheduler = DefaultVoiceScheduler.main) {
        self.recognizer = recognizer
        self.schedule = scheduler
    }

    public var isBusy: Bool {
        switch state {
        case .idle, .failed: return false
        default: return true
        }
    }

    public func toggle(_ options: VoiceStartOptions) async {
        switch state {
        case .idle, .failed: await start(options)
        case .listening: stop()
        case .requestingPermission, .finishing: break
        }
    }

    public func start(_ options: VoiceStartOptions) async {
        guard !isBusy else { return }
        generation += 1
        let gen = generation
        transcript = ""
        state = .requestingPermission

        let auth = await recognizer.requestAuthorization()
        guard gen == generation, state == .requestingPermission else { return }
        switch auth {
        case .granted: break
        case .deniedMicrophone: state = .failed(.microphoneDenied); return
        case .deniedSpeech: state = .failed(.speechDenied); return
        }
        do {
            try recognizer.start(options) { [weak self] event in self?.handle(event, generation: gen) }
        } catch let failure as VoiceFailure {
            state = .failed(failure)
            return
        } catch {
            state = .failed(.other(error.localizedDescription))
            return
        }
        state = .listening
        armMax()
        armSilence(firstSpeechTimeout)
    }

    /// Stops listening; the recognizer then delivers (or fails to deliver) its final text.
    public func stop() {
        guard state == .listening else { return }
        state = .finishing
        cancelSilence?()
        cancelSilence = nil
        recognizer.stop()
        let gen = generation
        cancelFinish = schedule(finishGrace) { [weak self] in
            guard let self, gen == self.generation, self.state == .finishing else { return }
            self.finish()
        }
    }

    /// Drops everything without delivering a transcript.
    public func cancel() {
        teardown()
        transcript = ""
        state = .idle
    }

    // MARK: internals

    private func handle(_ event: SpeechEvent, generation gen: Int) {
        guard gen == generation else { return }
        switch event {
        case .level(let value):
            onLevel?(value)
        case .partial(let text):
            guard state == .listening || state == .finishing else { return }
            transcript = text
            onTranscript?(text, false)
            if state == .listening { armSilence(silenceTimeout) }
        case .final(let text):
            guard state == .listening || state == .finishing else { return }
            if !text.isEmpty { transcript = text }
            finish()
        case .failed(let failure):
            guard state == .listening || state == .finishing else { return }
            if transcript.isEmpty {
                teardown()
                state = .failed(failure)
            } else {
                finish()
            }
        }
    }

    private func finish() {
        let text = transcript
        teardown()
        if text.isEmpty {
            state = .failed(.noSpeech)
        } else {
            state = .idle
            onTranscript?(text, true)
        }
    }

    private func teardown() {
        generation += 1
        cancelSilence?(); cancelSilence = nil
        cancelMax?(); cancelMax = nil
        cancelFinish?(); cancelFinish = nil
        recognizer.cancel()
    }

    private func armSilence(_ seconds: TimeInterval) {
        cancelSilence?()
        let gen = generation
        cancelSilence = schedule(seconds) { [weak self] in
            guard let self, gen == self.generation, self.state == .listening else { return }
            if self.transcript.isEmpty {
                self.teardown()
                self.state = .failed(.noSpeech)
            } else {
                self.stop()
            }
        }
    }

    private func armMax() {
        cancelMax?()
        let gen = generation
        cancelMax = schedule(maxDuration) { [weak self] in
            guard let self, gen == self.generation, self.state == .listening else { return }
            self.stop()
        }
    }
}
