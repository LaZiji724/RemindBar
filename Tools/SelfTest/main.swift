import Foundation
import RemindCore

let arguments = Array(CommandLine.arguments.dropFirst())

/// `remind-selftest --parse "文字" ["文字"…] [--now "2026-10-26 21:05"]` prints how the parser reads each text.
func printParse(_ texts: [String], now: Date) {
    let ctx = ParseContext(now: now, calendar: Fixture.calendar)
    for text in texts {
        print("「\(text)」")
        for e in NLParser.parse(text, context: ctx) {
            var flags: [String] = []
            let names: [(ParseFlags, String)] = [
                (.ampmInferred, "ampm推断"), (.defaultTime, "默认时间"), (.periodDefaultTime, "时段默认"),
                (.rolledForward, "顺延"), (.past, "已过"), (.weekGeneric, "泛指周"), (.dateInherited, "继承日期"),
                (.recurrenceMentioned, "循环"), (.emptyTitle, "无标题"), (.leftoverDateWords, "残留日期词"),
                (.conflict, "冲突"), (.noDateTime, "无时间")
            ]
            for (f, n) in names where e.flags.contains(f) { flags.append(n) }
            let alt = e.alternative.flatMap { Fixture.format($0) }.map { " 备选=\($0)" } ?? ""
            print("   事件=\(e.title) | 时间=\(Fixture.format(e.due) ?? "—") | \(e.isDeadline ? "截止" : "提醒") | \(e.confidence) | \(flags.joined(separator: ","))\(alt)")
        }
    }
}

if let i = arguments.firstIndex(of: "--parse") {
    var texts = Array(arguments[(i + 1)...])
    var now = Fixture.now
    if let n = texts.firstIndex(of: "--now"), n + 1 < texts.count {
        now = Fixture.date(texts[n + 1])
        texts.removeSubrange(n...(n + 1))
    }
    printParse(texts, now: now)
    exit(0)
}

let harness = Harness()
ParserTests.run(harness)
CoreTests.run(harness)
DisplayTests.run(harness)
await VoiceTests.run(harness)
await AITests.run(harness)
await SourceTests.run(harness)
await KetangpaiTests.run(harness)
ShapeTests.run(harness)
RedactorTests.run(harness)
CompletionRuleTests.run(harness)
IgnoreTests.run(harness)
await AppleSyncTests.run(harness)
await WebWatchTests.run(harness)
if arguments.contains("--live") { await LiveTests.run(harness) }
exit(harness.report())
