import Foundation
import RemindCore

@MainActor
private final class PageSession: WebSessionFetching {
    var pages: [Result<String, SourceError>] = []
    private(set) var requests = 0
    func fetch(script: String, baseURL: URL) async throws -> WebFetchResult { WebFetchResult(status: 200, body: "") }
    func pageText(url: URL) async throws -> String {
        requests += 1
        guard !pages.isEmpty else { return "" }
        return try pages.removeFirst().get()
    }
}

enum WebWatchTests {
    @MainActor
    static func run(_ h: Harness) async {
        textHelpers(h)
        validator(h)
        await source(h)
    }

    // MARK: text helpers

    private static func textHelpers(_ h: Harness) {
        h.suite = "pagetext"
        let raw = "课程通知\n  5分钟前  \n实验四 截止 11月3日 23:59\n共 12 条\n浏览 345 次\n实验四 截止 11月3日 23:59\nx\n"
        let lines = PageText.lines(from: raw)
        h.equal(lines, ["课程通知", "实验四 截止 11月3日 23:59"], "volatile text, counters, one-character lines and repeats are dropped")
        h.equal(PageText.fingerprint(lines), PageText.fingerprint(PageText.lines(from: raw)), "the fingerprint is stable")
        h.check(PageText.fingerprint(lines) != PageText.fingerprint(lines + ["新公告"]), "the fingerprint changes with the content")
        h.equal(PageText.lines(from: "更新于 3分钟前\n通知A"), ["更新于", "通知A"], "relative times do not change the page")
        h.equal(PageText.addedLines(old: ["a1", "b2"], new: ["a1", "b2", "c3"]), ["c3"], "only new lines are reported")
        h.equal(PageText.addedLines(old: nil, new: ["a1", "b2"]), ["a1", "b2"], "the first visit reports everything")

        let page = ["首页", "课程列表", "数据库原理", "实验四", "截止 11月3日 23:59", "今天天气不错", "联系我们"]
        h.equal(PageText.candidates(page), ["实验四", "截止 11月3日 23:59", "今天天气不错"],
                "homework-ish and dated lines plus the neighbours of dated lines are kept")
        let long = (1...400).map { "作业\($0) 截止 11月3日 23:59 \(String(repeating: "字", count: 20))" }
        h.check(PageText.candidates(long).joined(separator: "\n").count <= AIPolicy.maxInputCharacters, "candidates respect the size cap")

        let ctx = Fixture.context
        let local = PageExtractor.localItems(from: ["实验四 截止 11月3日 23:59", "第五章作业", "今天天气不错"], watcherID: "w1", context: ctx)
        h.equal(local.items.map(\.title), ["实验四"], "a line with a title and a date is read locally")
        h.equal(Fixture.format(local.items.first?.due), "2026-11-03 23:59", "deadline time read locally")
        h.equal(local.remaining, ["第五章作业"], "a homework line without a date is left for the AI")
        let again = PageExtractor.localItems(from: ["实验四 截止 11月3日 23:59"], watcherID: "w1", context: ctx)
        h.equal(again.items.first?.key, local.items.first?.key, "item keys are stable between visits")
        let other = PageExtractor.localItems(from: ["实验四 截止 11月3日 23:59"], watcherID: "w2", context: ctx)
        h.check(other.items.first?.key != local.items.first?.key, "keys differ between watchers")
    }

    // MARK: assignment answers from the AI

    private static func validator(_ h: Harness) {
        h.suite = "extract"
        let ctx = Fixture.context
        func parse(_ json: String) -> [AIAssignment] {
            if case .success(let v) = ResultValidator.parseAssignments(json, now: ctx.now, calendar: ctx.calendar) { return v }
            return []
        }
        let ok = parse(#"{"items":[{"title":"实验五","course":"数据库原理","due":"2026-11-10 23:59"}]}"#)
        h.equal(ok.first?.title, "实验五", "valid assignment")
        h.equal(ok.first?.course, "数据库原理", "course kept")
        h.equal(Fixture.format(ok.first?.due), "2026-11-10 23:59", "due time parsed")
        h.equal(parse(#"{"items":[{"title":"x","course":null,"due":null}]}"#).count, 0, "undated items are dropped")
        h.equal(parse(#"{"items":[{"title":"x","due":"2026-11-10"}]}"#).count, 0, "due must include the time")
        h.equal(parse(#"{"items":[{"title":"x","due":"2026-13-10 10:00"}]}"#).count, 0, "impossible dates are dropped")
        h.equal(parse(#"{"items":[{"title":"x","due":"2024-01-01 10:00"}]}"#).count, 0, "dates long past are dropped")
        h.equal(parse(#"{"items":[{"title":"x","due":"2031-01-01 10:00"}]}"#).count, 0, "dates far ahead are dropped")
        h.equal(parse(#"{"items":[{"title":"x","course":"null","due":"2026-11-10 10:00"}]}"#).first?.course, nil, "the string null is not a course")
        let nine = (1...9).map { #"{"title":"t\#($0)","due":"2026-11-10 10:00"}"# }.joined(separator: ",")
        h.equal(parse(#"{"items":[\#(nine)]}"#).count, 8, "at most 8 items")
        h.check({ if case .failure = ResultValidator.parseAssignments("[]", now: ctx.now, calendar: ctx.calendar) { return true }; return false }(), "wrong shape rejected")
        h.check(Prompts.extractSystem.contains("json"), "the extraction prompt mentions json")
        let user = Prompts.extractUser(lines: ["a", "b"], hint: String(repeating: "要", count: 500), now: ctx.now, calendar: ctx.calendar)
        h.check(user.hasPrefix("现在：2026-10-26 周一 21:05"), "the clock leads the user message")
        h.check(user.count < 400, "the hint is clipped", "\(user.count)")
    }

    // MARK: the whole check, and what it costs

    private static let pageA = "数据库原理\n实验四 截止 11月3日 23:59\n关于课程的通知"
    private static let pageB = "数据库原理\n实验五\n截止：11月10日 23:59\n关于课程的通知"
    private static let answer = #"{"items":[{"title":"实验五","course":"数据库原理","due":"2026-11-10 23:59"}]}"#

    @MainActor
    private static func source(_ h: Harness) async {
        h.suite = "webwatch"
        let ctx = Fixture.context
        var watcher = WatcherConfig(id: "w-web", kind: .web, name: "示例课程站", url: "https://course.example.edu/home", hint: "只关注作业")

        func apply(_ r: WebPageSource.Result, to w: inout WatcherConfig) {
            if r.advanceSnapshot { w.pageHash = r.fingerprint; w.pageLines = r.lines }
            w.aiEmptyStreak = r.aiEmptyStreak
            w.aiPausedUntil = r.aiPausedUntil
        }

        // A page the local parser can read costs nothing, and neither does visiting it again.
        do {
            let session = PageSession(); session.pages = [.success(pageA), .success(pageA)]
            let transport = FakeTransport()
            let src = WebPageSource(session: session, ai: AIService(gate: makeTestGate(transport)), context: { ctx })
            let first = try? await src.check(watcher)
            h.equal(first?.items.map(\.title), ["实验四"], "the local parser finds the dated line")
            h.equal(first?.items.first?.url, "https://course.example.edu/home", "the page link is kept")
            h.equal(transport.requests.count, 0, "nothing needed the AI → no request")
            h.equal(first?.aiAttempted, false, "no AI attempt")
            if let first { apply(first, to: &watcher) }
            let second = try? await src.check(watcher)
            h.equal(second?.changed, false, "an unchanged page is recognised")
            h.equal(second?.items.count, 0, "…and yields nothing")
            h.equal(transport.requests.count, 0, "page unchanged → 0 AI calls")
        }

        // Title and deadline on separate lines → one AI call, and only for the lines that need it.
        do {
            var w = WatcherConfig(id: "w-ai", kind: .web, name: "站", url: "https://course.example.edu/home", hint: "只关注作业")
            let session = PageSession(); session.pages = [.success(pageB), .success(pageB)]
            let transport = FakeTransport(); transport.steps = [.reply(200, chatJSON(answer))]
            let src = WebPageSource(session: session, ai: AIService(gate: makeTestGate(transport)), context: { ctx })
            let r = try? await src.check(w)
            h.equal(r?.items.map(\.title), ["实验五"], "the AI reads the split title/deadline")
            h.equal(Fixture.format(r?.items.first?.due), "2026-11-10 23:59", "AI deadline")
            h.equal(transport.requests.count, 1, "exactly one AI call")
            if let body = transport.requests.first?.httpBody, let text = String(data: body, encoding: .utf8) {
                h.check(!text.contains("关于课程的通知"), "lines without homework words are never sent")
                h.check(text.contains("实验五") && text.contains("只关注作业"), "the relevant lines and the user's request are sent")
            }
            if let r { apply(r, to: &w) }
            _ = try? await src.check(w)
            h.equal(transport.requests.count, 1, "visiting the same page again costs nothing")
        }

        // Pages that cannot be read, and sessions that expired.
        do {
            let session = PageSession(); session.pages = [.failure(.notLoggedIn), .success("")]
            let src = WebPageSource(session: session, ai: nil, context: { ctx })
            do { _ = try await src.check(watcher); h.check(false, "an expired session throws") }
            catch { h.equal(error as? SourceError, .notLoggedIn, "a bounce to the login page means logged out") }
            do { _ = try await src.check(watcher); h.check(false, "an empty page throws") }
            catch { h.check(error is SourceError, "an empty page is reported, not silently accepted") }
        }

        // A changed page with nothing about homework costs nothing.
        do {
            let session = PageSession(); session.pages = [.success("天气预报\n明天多云转晴\n服务条款")]
            let transport = FakeTransport()
            let src = WebPageSource(session: session, ai: AIService(gate: makeTestGate(transport)), context: { ctx })
            let r = try? await src.check(WatcherConfig(kind: .web, name: "x", url: "https://a.example/"))
            h.equal(r?.items.count, 0, "nothing to find")
            h.equal(transport.requests.count, 0, "no homework words → no AI")
            h.equal(r?.advanceSnapshot, true, "the page is remembered")
        }

        // The AI cannot run: the lines are kept for later instead of being forgotten.
        do {
            let session = PageSession(); session.pages = [.success(pageB)]
            let src = WebPageSource(session: session, ai: nil, context: { ctx })
            let r = try? await src.check(WatcherConfig(kind: .web, name: "x", url: "https://a.example/"))
            h.equal(r?.advanceSnapshot, false, "without a key the snapshot does not move")
            h.check(r?.note.contains("DeepSeek") == true, "the note says why", r?.note ?? "")
            let session2 = PageSession(); session2.pages = [.success(pageB)]
            let transport = FakeTransport(); transport.steps = [.reply(500, "{}"), .reply(500, "{}")]
            let src2 = WebPageSource(session: session2, ai: AIService(gate: makeTestGate(transport)), context: { ctx })
            let r2 = try? await src2.check(WatcherConfig(kind: .web, name: "x", url: "https://a.example/"))
            h.equal(r2?.advanceSnapshot, false, "a failed AI call keeps the lines for the next visit")
        }

        // Three reads in a row that find nothing new pause the AI for this site for a day.
        do {
            var w = WatcherConfig(id: "w-quiet", kind: .web, name: "站", url: "https://a.example/")
            let session = PageSession()
            session.pages = (1...4).map { .success("作业说明 第\($0)版\n请按时完成实验") }
            let transport = FakeTransport(); transport.steps = Array(repeating: .reply(200, chatJSON(#"{"items":[]}"#)), count: 4)
            let src = WebPageSource(session: session, ai: AIService(gate: makeTestGate(transport, config: AIConfig(perSourceDailyCap: 20))), context: { ctx })
            for _ in 1...3 {
                if let r = try? await src.check(w) { apply(r, to: &w) }
            }
            h.equal(transport.requests.count, 3, "three AI reads happened")
            h.check(w.aiPausedUntil != nil, "then the AI is paused for this site")
            let r4 = try? await src.check(w)
            h.equal(transport.requests.count, 3, "no further AI calls while paused")
            h.check(r4?.note.contains("暂停") == true, "the note explains the pause", r4?.note ?? "")
        }
    }
}
