import AppKit
import AVFoundation
import Speech
import RemindCore

/// `RemindBar --voice-file-test <outfile>`: synthesises Chinese speech with `say`, recognises it with the real on-device
/// recognizer and checks that the parser reads the transcript like the original sentence. Needs the app bundle (Info.plist)
/// and a one-time "Speech Recognition" permission.
@MainActor
enum VoiceFileTest {
    private static let samples = [
        "明天下午三点开会",
        "提醒我今晚十点半睡觉",
        "后天上午九点交实验报告",
        "周五晚上八点去健身",
        "十月三十日晚上十一点五十九分截止提交作业",
        "半小时后提醒我关火",
        "下周三上午十点钟交高等数学作业",
        "明天早上七点起床然后晚上八点半看电影"
    ]

    static func run(outputPath: String) async {
        var lines: [String] = []
        func log(_ s: String) { lines.append(s); print(s) }
        defer { try? lines.joined(separator: "\n").write(toFile: outputPath, atomically: true, encoding: .utf8) }

        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            log("requesting speech recognition permission…")
            status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        }
        guard status == .authorized else { log("RESULT: BLOCKED authorization=\(status.rawValue)"); return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition else { log("RESULT: BLOCKED no on-device zh-CN recognizer"); return }

        let ctx = ParseContext(now: Date(), calendar: .reminder)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("voice-file-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var failures = 0
        for (index, text) in samples.enumerated() {
            let file = dir.appendingPathComponent("s\(index).aiff")
            guard synthesize(text, to: file) else { log("FAIL say could not synthesize: \(text)"); failures += 1; continue }
            guard let transcript = await transcribe(file, with: recognizer) else {
                log("FAIL no transcript for: \(text)"); failures += 1; continue
            }
            let expected = NLParser.parse(text, context: ctx)
            let actual = NLParser.parse(transcript, context: ctx)
            let sameTimes = expected.map { $0.due } == actual.map { $0.due }
            let sameTitles = expected.map { $0.title } == actual.map { $0.title }
            log("""
            \(sameTimes ? (sameTitles ? "PASS" : "WARN title differs") : "FAIL time differs")
              said:       \(text)
              recognised: \(transcript)
              expected:   \(describe(expected))
              actual:     \(describe(actual))
            """)
            if !sameTimes { failures += 1 }
        }
        log("RESULT: \(failures == 0 ? "ALL PASSED" : "\(failures) FAILED") of \(samples.count)")
    }

    private static func describe(_ events: [ParsedEvent]) -> String {
        events.map { "\($0.title) @ \($0.due.map { DisplayFormat.dueLabel($0, now: Date(), calendar: .reminder) } ?? "—")" }
            .joined(separator: " | ")
    }

    private static func synthesize(_ text: String, to url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", "Tingting", "-o", url.path, text]
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path)
    }

    private static func transcribe(_ url: URL, with recognizer: SFSpeechRecognizer) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false
            request.addsPunctuation = true
            request.taskHint = .dictation
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                DispatchQueue.main.async {
                    guard !finished else { return }
                    if let result, result.isFinal {
                        finished = true
                        continuation.resume(returning: result.bestTranscription.formattedString)
                    } else if error != nil {
                        finished = true
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }
}
