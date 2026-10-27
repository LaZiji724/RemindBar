import Foundation
import RemindCore

@MainActor
private final class FakeRecognizer: SpeechRecognizing {
    var auth: VoiceAuthResult = .granted
    var startError: VoiceFailure?
    var starts = 0, stops = 0, cancels = 0
    var lastOptions: VoiceStartOptions?
    var emit: (@MainActor (SpeechEvent) -> Void)?

    func requestAuthorization() async -> VoiceAuthResult { auth }
    func start(_ options: VoiceStartOptions, onEvent: @escaping @MainActor (SpeechEvent) -> Void) throws {
        if let startError { throw startError }
        starts += 1
        lastOptions = options
        emit = onEvent
    }
    func stop() { stops += 1 }
    func cancel() { cancels += 1 }
}

/// Manual clock so silence/timeouts can be tested without sleeping.
@MainActor
private final class FakeClock {
    private struct Item { let id: Int; let at: TimeInterval; let block: @MainActor () -> Void }
    private var items: [Item] = []
    private var nextID = 0
    private(set) var now: TimeInterval = 0

    var scheduler: VoiceScheduler {
        { delay, block in
            let id = self.nextID
            self.nextID += 1
            self.items.append(Item(id: id, at: self.now + delay, block: block))
            return { self.items.removeAll { $0.id == id } }
        }
    }

    func advance(_ seconds: TimeInterval) {
        let target = now + seconds
        while let next = items.filter({ $0.at <= target }).min(by: { $0.at < $1.at }) {
            now = next.at
            items.removeAll { $0.id == next.id }
            next.block()
        }
        now = target
    }
}

enum VoiceTests {
    @MainActor
    static func run(_ h: Harness) async {
        h.suite = "voice"
        let opts = VoiceStartOptions(locale: "zh-CN", contextualStrings: ["课堂派", "Canvas"], allowServerRecognition: false)

        func make() -> (VoiceSession, FakeRecognizer, FakeClock, Box) {
            let rec = FakeRecognizer()
            let clock = FakeClock()
            let session = VoiceSession(recognizer: rec, scheduler: clock.scheduler)
            let box = Box()
            session.onTranscript = { text, final in box.events.append((text, final)) }
            return (session, rec, clock, box)
        }

        // Happy path: partials flow, silence ends the dictation, the recognizer delivers its final text.
        do {
            let (s, rec, clock, box) = make()
            await s.start(opts)
            h.equal(s.state, .listening, "starts listening once permitted")
            h.equal(rec.starts, 1, "recognizer started once")
            h.equal(rec.lastOptions?.contextualStrings ?? [], ["课堂派", "Canvas"], "hot words reach the recognizer")
            rec.emit?(.partial("明天"))
            rec.emit?(.partial("明天下午三点开会"))
            h.equal(s.transcript, "明天下午三点开会", "transcript follows partial results")
            clock.advance(1.0)
            h.equal(s.state, .listening, "still listening during a short pause")
            clock.advance(1.0)
            h.equal(s.state, .finishing, "silence stops the dictation")
            h.equal(rec.stops, 1, "recognizer told to stop")
            rec.emit?(.final("明天下午3点开会。"))
            h.equal(s.state, .idle, "final result returns to idle")
            h.equal(box.events.last?.0, "明天下午3点开会。", "final text delivered")
            h.equal(box.events.last?.1, true, "marked as final")
            h.equal(box.events.filter { $0.1 }.count, 1, "final delivered exactly once")
            rec.emit?(.partial("迟到的结果"))
            h.equal(s.transcript, "明天下午3点开会。", "late events after finishing are ignored")
        }

        // Permission problems.
        do {
            let (s, rec, _, _) = make()
            rec.auth = .deniedMicrophone
            await s.start(opts)
            h.equal(s.state, .failed(.microphoneDenied), "microphone denied")
            h.equal(rec.starts, 0, "recognizer never started without permission")
            rec.auth = .granted
            await s.toggle(opts)
            h.equal(s.state, .listening, "toggle retries after a failure")
        }
        do {
            let (s, rec, _, _) = make()
            rec.auth = .deniedSpeech
            await s.start(opts)
            h.equal(s.state, .failed(.speechDenied), "speech recognition denied")
        }
        do {
            let (s, rec, _, _) = make()
            rec.startError = .onDeviceUnavailable
            await s.start(opts)
            h.equal(s.state, .failed(.onDeviceUnavailable), "missing offline model is reported")
        }

        // Nobody speaks.
        do {
            let (s, _, clock, box) = make()
            await s.start(opts)
            clock.advance(7.5)
            h.equal(s.state, .listening, "waits for the first words")
            clock.advance(1.0)
            h.equal(s.state, .failed(.noSpeech), "gives up when nothing is said")
            h.check(box.events.isEmpty, "nothing delivered when nothing was said")
        }

        // Maximum length.
        do {
            let (s, rec, clock, box) = make()
            await s.start(opts)
            for i in 1...70 {
                rec.emit?(.partial("第\(i)句"))
                clock.advance(1.0)
                if s.state != .listening { break }
            }
            h.equal(s.state, .finishing, "60 s cap stops a never-ending dictation")
            rec.emit?(.final("很长的内容"))
            h.equal(box.events.last?.0, "很长的内容", "text from a capped dictation is kept")
        }

        // Manual stop, then the final result never arrives.
        do {
            let (s, rec, clock, box) = make()
            await s.start(opts)
            rec.emit?(.partial("后天早上八点起床"))
            s.stop()
            h.equal(s.state, .finishing, "manual stop")
            clock.advance(1.0)
            h.equal(s.state, .finishing, "grace period")
            clock.advance(1.0)
            h.equal(s.state, .idle, "falls back to the last partial text")
            h.equal(box.events.last?.0, "后天早上八点起床", "last partial delivered as final")
            h.equal(box.events.last?.1, true, "marked final")
        }

        // Toggle semantics and re-entrancy.
        do {
            let (s, rec, _, _) = make()
            await s.start(opts)
            await s.start(opts)
            h.equal(rec.starts, 1, "second start while listening is ignored")
            await s.toggle(opts)
            h.equal(s.state, .finishing, "toggle while listening stops")
            await s.toggle(opts)
            h.equal(s.state, .finishing, "toggle while finishing does nothing")
        }

        // Cancel drops everything.
        do {
            let (s, rec, _, box) = make()
            await s.start(opts)
            rec.emit?(.partial("要丢弃的内容"))
            s.cancel()
            h.equal(s.state, .idle, "cancel returns to idle")
            h.equal(s.transcript, "", "cancel clears the transcript")
            rec.emit?(.final("取消之后到达"))
            h.check(box.events.allSatisfy { !$0.1 }, "nothing is delivered as final after cancel")
        }

        // Recognizer error after some words still delivers them; before any words it is reported.
        do {
            let (s, rec, _, box) = make()
            await s.start(opts)
            rec.emit?(.partial("周五交作业"))
            rec.emit?(.failed(.other("connection lost")))
            h.equal(s.state, .idle, "error after partial text finishes normally")
            h.equal(box.events.last?.0, "周五交作业", "partial text survives a recognizer error")
        }
        do {
            let (s, rec, _, _) = make()
            await s.start(opts)
            rec.emit?(.failed(.noSpeech))
            h.equal(s.state, .failed(.noSpeech), "error before any words is reported")
        }

        // Levels are forwarded.
        do {
            let (s, rec, _, _) = make()
            var levels: [Float] = []
            s.onLevel = { levels.append($0) }
            await s.start(opts)
            rec.emit?(.level(0.4))
            h.equal(levels, [0.4], "level meter events are forwarded")
        }
    }

    @MainActor
    final class Box {
        var events: [(String, Bool)] = []
    }
}
