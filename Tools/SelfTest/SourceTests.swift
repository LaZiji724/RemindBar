import Foundation
import RemindCore

@MainActor
private final class FakeSession: WebSessionFetching {
    var results: [Result<WebFetchResult, SourceError>] = []
    private(set) var scripts: [String] = []

    func fetch(script: String, baseURL: URL) async throws -> WebFetchResult {
        scripts.append(script)
        guard !results.isEmpty else { return WebFetchResult(status: 200, body: "[]") }
        return try results.removeFirst().get()
    }

    var pages: [Result<String, SourceError>] = []
    private(set) var pageRequests: [URL] = []
    func pageText(url: URL) async throws -> String {
        pageRequests.append(url)
        guard !pages.isEmpty else { return "" }
        return try pages.removeFirst().get()
    }
}

enum SourceTests {
    static func fixture(_ name: String) -> Data? {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/Fixtures/\(name)")
        return try? Data(contentsOf: url)
    }

    @MainActor
    static func run(_ h: Harness) async {
        h.suite = "canvas"
        let base = URL(string: "https://canvas.tongji.edu.cn")!

        // URLs and scripts
        h.equal(CanvasAPI.base(from: "https://canvas.tongji.edu.cn/courses/1?x=1")?.absoluteString, "https://canvas.tongji.edu.cn", "base keeps scheme and host only")
        let url = CanvasAPI.plannerURL(base: base, now: Fixture.now, calendar: Fixture.calendar)
        h.equal(url.absoluteString,
                "https://canvas.tongji.edu.cn/api/v1/planner/items?start_date=2026-10-12&end_date=2027-04-24&per_page=100",
                "planner URL covers two weeks back and 180 days ahead")
        let script = CanvasAPI.pagedScript(startURL: url)
        h.check(script.contains("rel=\\\"next\\\"") || script.contains("rel=\"next\""), "script follows Link rel=next")
        h.check(script.contains("credentials: 'same-origin'"), "script uses the page's session cookies")
        h.check(script.contains(url.absoluteString), "script starts at the planner URL")
        h.check(!script.contains("POST") && !script.contains("DELETE") && !script.contains("PUT"), "the script only reads")
        h.check(script.contains("cache: 'no-store'"), "a read never answers from the browser cache")
        h.check(CanvasAPI.singleScript(url: url).contains("cache: 'no-store'"), "the login check never answers from the cache either")
        h.equal(try? CanvasAPI.decodeEnvelope(#"{"status":200,"body":"[]"}"#), WebFetchResult(status: 200, body: "[]"), "envelope decoding")
        h.check((try? CanvasAPI.decodeEnvelope("nope")) == nil, "bad envelope rejected")

        // Parsing the sample planner response
        guard let data = fixture("canvas_planner.json") else {
            h.check(false, "Tests/Fixtures/canvas_planner.json is readable from \(FileManager.default.currentDirectoryPath)")
            return
        }
        let items = (try? CanvasAPI.parsePlanner(data, base: base)) ?? []
        h.equal(items.map(\.key), ["canvas:assignment:9001", "canvas:assignment:9002", "canvas:quiz:7001",
                                    "canvas:discussion_topic:5001", "canvas:assignment:9003"],
                "only dated assignments, quizzes and discussions are read (notes, events, undated items are skipped)")
        let lab4 = items.first { $0.key == "canvas:assignment:9001" }
        h.equal(lab4?.title, "Lab 4 提交", "title")
        h.equal(lab4?.course, "数据库原理", "course name")
        h.equal(Fixture.format(lab4?.due), "2026-10-30 23:59", "UTC due time converted to local time")
        h.equal(lab4?.url, "https://canvas.tongji.edu.cn/courses/30001/assignments/9001", "relative html_url made absolute")
        h.equal(lab4?.completed, false, "not submitted yet")
        h.equal(items.first { $0.key == "canvas:assignment:9002" }?.completed, true, "submitted -> completed")
        h.equal(items.first { $0.key == "canvas:assignment:9003" }?.completed, true, "marked complete in the planner -> completed")
        h.equal(items.first { $0.key == "canvas:quiz:7001" }?.url, "https://canvas.tongji.edu.cn/courses/30002/quizzes/7001", "absolute URLs are kept")
        h.equal(items.first { $0.key == "canvas:quiz:7001" }?.completed, false, "submissions:false means nothing submitted")
        h.check((try? CanvasAPI.parsePlanner(Data("{}".utf8), base: base)) == nil, "a non-array answer is rejected")

        // The source object: login check, errors
        let session = FakeSession()
        let source = CanvasSource(session: session, base: base, calendar: Fixture.calendar, clock: { Fixture.now })
        session.results = [.success(WebFetchResult(status: 200, body: "{}"))]
        h.equal(await source.isLoggedIn(), true, "200 on /users/self means logged in")
        session.results = [.success(WebFetchResult(status: 401, body: ""))]
        h.equal(await source.isLoggedIn(), false, "401 means logged out")
        session.results = [.success(WebFetchResult(status: 200, body: String(decoding: data, as: UTF8.self)))]
        let fetched = try? await source.fetchItems()
        h.equal(fetched?.count, 5, "fetchItems parses the planner answer")
        session.results = [.success(WebFetchResult(status: 401, body: ""))]
        do { _ = try await source.fetchItems(); h.check(false, "401 throws") }
        catch { h.equal(error as? SourceError, .notLoggedIn, "401 -> not logged in") }
        session.results = [.success(WebFetchResult(status: 500, body: ""))]
        do { _ = try await source.fetchItems(); h.check(false, "500 throws") }
        catch { h.equal(error as? SourceError, .http(500), "500 -> http error") }

        sync(h, items: items)
    }

    // MARK: sync engine

    private static func sync(_ h: Harness, items: [RemoteItem]) {
        h.suite = "sync"
        let now = Fixture.now
        var watcher = WatcherConfig(id: "w-canvas", kind: .canvas, name: "同济 Canvas", url: "https://canvas.tongji.edu.cn/")

        // First sync: pending items are imported, completed ones are not.
        let first = SyncEngine.reconcile(existing: [], remote: items, watcher: watcher, now: now)
        h.equal(first.added.map(\.externalKey), ["canvas:assignment:9001", "canvas:quiz:7001", "canvas:discussion_topic:5001"].map { Optional($0) },
                "only open items are imported")
        let lab4 = first.reminders.first { $0.externalKey == "canvas:assignment:9001" }
        h.equal(lab4?.source, .canvas, "source kind")
        h.equal(lab4?.watcherID, "w-canvas", "watcher id")
        h.equal(lab4?.isDeadline, true, "synced items are deadlines")
        h.equal(lab4?.leadTimes, LeadTimes.standard, "alert schedule")
        h.equal(Fixture.format(lab4?.due), "2026-10-30 23:59", "due time")

        // Second sync with the same data: nothing changes.
        let second = SyncEngine.reconcile(existing: first.reminders, remote: items, watcher: watcher, now: now)
        h.equal(second.hasChanges, false, "syncing unchanged data changes nothing")
        h.equal(second.reminders.count, first.reminders.count, "no duplicates")

        // The site moves a deadline.
        var moved = items
        moved[0].due = Fixture.date("2026-11-01 23:59")
        let third = SyncEngine.reconcile(existing: first.reminders, remote: moved, watcher: watcher, now: now)
        h.equal(third.changedDue.count, 1, "a moved deadline is reported")
        h.equal(Fixture.format(third.changedDue.first?.oldDue), "2026-10-30 23:59", "old due is kept for the message")
        h.equal(Fixture.format(third.reminders.first { $0.externalKey == "canvas:assignment:9001" }?.due), "2026-11-01 23:59", "reminder follows the site")

        // Submitted elsewhere -> completed here.
        var submitted = items
        submitted[0].completed = true
        let fourth = SyncEngine.reconcile(existing: first.reminders, remote: submitted, watcher: watcher, now: now)
        h.equal(fourth.autoCompleted.count, 1, "a submission completes the reminder")
        h.equal(fourth.reminders.first { $0.externalKey == "canvas:assignment:9001" }?.status, .done, "status is done")

        // For Canvas the website decides: a "done" that is not backed by the site is undone by the next read.
        var userDone = first.reminders
        if let i = userDone.firstIndex(where: { $0.externalKey == "canvas:assignment:9001" }) { userDone[i].status = .done }
        let fifth = SyncEngine.reconcile(existing: userDone, remote: items, watcher: watcher, now: now)
        h.equal(fifth.reminders.first { $0.externalKey == "canvas:assignment:9001" }?.status, .pending,
                "an item the site still lists as open is open again (the site decides, not a local tick)")
        h.equal(fifth.reopened.count, 1, "…and the reopening is reported")
        h.equal(fifth.hasChanges, true, "a reopening counts as a change")
        // Generic pages cannot report completion, so a manual completion stands there.
        let webWatcher = WatcherConfig(id: "w-web", kind: .web, name: "网页", url: "https://x.example/")
        let webItems = [RemoteItem(key: "web:w-web:abc", title: "某作业", course: nil, due: Fixture.date("2026-11-03 23:59"))]
        var webList = SyncEngine.reconcile(existing: [], remote: webItems, watcher: webWatcher, now: now).reminders
        webList[0].status = .done
        let webAgain = SyncEngine.reconcile(existing: webList, remote: webItems, watcher: webWatcher, now: now)
        h.equal(webAgain.reminders[0].status, .done, "on a generic page a manual completion stands")
        h.equal(webAgain.reopened.count, 0, "…and is not reopened")
        // Canvas / 课堂派: nothing the site lists as open can be hidden for good, so an old "deleted" mark is ignored.
        watcher.deletedKeys = ["canvas:quiz:7001"]
        let sixth = SyncEngine.reconcile(existing: first.reminders.filter { $0.externalKey != "canvas:quiz:7001" }, remote: items, watcher: watcher, now: now)
        h.equal(sixth.added.map(\.externalKey), ["canvas:quiz:7001"], "a Canvas item comes back while the site still lists it as open")
        // Generic pages cannot say whether something is done, so there a hand-deleted item stays deleted.
        var deletedOnWeb = webWatcher
        deletedOnWeb.deletedKeys = ["web:w-web:abc"]
        let webDeleted = SyncEngine.reconcile(existing: [], remote: webItems, watcher: deletedOnWeb, now: now)
        h.equal(webDeleted.added.count, 0, "a deleted item from a generic page does not come back")

        // Items that disappear from the site are reported but left alone.
        let seventh = SyncEngine.reconcile(existing: first.reminders, remote: Array(items.dropFirst(2)), watcher: watcher, now: now)
        h.equal(seventh.missing.count, 1, "an item missing at the source is reported")
        h.equal(seventh.reminders.count, first.reminders.count, "…but not removed")

        // Canvas lists only a window starting two weeks back: what aged out of it is retired (nobody can act on it any more),
        // what is still inside the window is left alone, and whatever the site still lists is never touched.
        func canvasItem(_ title: String, _ key: String, due: String) -> Reminder {
            Reminder(title: title, due: Fixture.date(due), hasExplicitTime: true, isDeadline: true, source: .canvas,
                     watcherID: watcher.id, externalKey: key, createdAt: now)
        }
        let aged = canvasItem("很久以前的作业", "canvas:assignment:1", due: "2026-10-05 23:59")
        let lastWeek = canvasItem("上周的作业", "canvas:assignment:2", due: "2026-10-22 23:59")
        let cutoff = Fixture.date("2026-10-11 21:05")
        let ninth = SyncEngine.reconcile(existing: [aged, lastWeek], remote: [], watcher: watcher, now: now, retireBefore: cutoff)
        h.equal(ninth.retired.map(\.title), ["很久以前的作业"], "an item that aged out of the window is retired")
        h.equal(ninth.reminders.first { $0.externalKey == "canvas:assignment:1" }?.status, .done, "…and no longer pending")
        h.equal(ninth.reminders.first { $0.externalKey == "canvas:assignment:2" }?.status, .pending, "an item still inside the window is left alone")
        h.equal(ninth.missing.map(\.title), ["上周的作业"], "…and reported as missing")
        h.equal(ninth.autoCompleted.count, 0, "retiring is not reported as the site completing something")
        h.equal(ninth.hasChanges, true, "a retirement counts as a change")
        let listedOld = RemoteItem(key: "canvas:assignment:1", title: "很久以前的作业", course: nil, due: aged.due)
        let tenth = SyncEngine.reconcile(existing: [aged], remote: [listedOld], watcher: watcher, now: now, retireBefore: cutoff)
        h.equal(tenth.retired.count, 0, "an old item the site still lists is never retired")
        h.equal(tenth.reminders.first?.status, .pending, "…it stays open")
        let eleventh = SyncEngine.reconcile(existing: [aged], remote: [], watcher: watcher, now: now)
        h.equal(eleventh.retired.count, 0, "without a window edge nothing is retired")

        // Another watcher's reminders and manual reminders are never touched.
        let manual = Reminder(title: "手动", due: Fixture.date("2026-10-27 09:00"))
        let eighth = SyncEngine.reconcile(existing: first.reminders + [manual], remote: [], watcher: watcher, now: now)
        h.check(eighth.reminders.contains(manual), "manual reminders are untouched")
        h.equal(eighth.autoCompleted.count, 0, "nothing is completed just because it is missing")
    }
}

enum ShapeTests {
    static func run(_ h: Harness) {
        h.suite = "shape"
        let json = #"[{"plannable_type":"assignment","context_name":"数据库原理","plannable":{"title":"Lab 4","due_at":"2026-10-30T15:59:00Z","points_possible":10.0},"submissions":{"submitted":false,"graded":false},"planner_override":null}]"#
        let shape = JSONShape.describe(json)
        h.check(shape.contains("plannable_type: \"assignment\""), "protocol vocabulary is kept")
        h.check(shape.contains("due_at: <date YYYY-MM-DDTHH:MM:SSZ>"), "dates show only their format", shape)
        h.check(shape.contains("submitted: false"), "booleans are kept")
        h.check(!shape.contains("数据库原理") && !shape.contains("Lab 4"), "names and titles never appear", shape)
        h.check(shape.contains("planner_override: null"), "null is shown")
        h.check(shape.contains("title: <string, 5 chars>"), "free text is reduced to its length")
        h.equal(JSONShape.describe("nope"), "(not JSON, 4 characters)", "non-JSON input")
    }
}

enum RedactorTests {
    static func run(_ h: Harness) {
        h.suite = "redactor"
        let text = #"{"token":"abc.def.ghi","data":{"password":"p@ss","title":"实验报告","userPhone":"13800000000","count":3},"url":"https://x.com/a?token=SECRET&page=1","h":"Bearer abcDEF123"}"#
        let out = Redactor.scrub(text)
        h.check(!out.contains("abc.def.ghi"), "token value removed", out)
        h.check(!out.contains("p@ss"), "password removed", out)
        h.check(!out.contains("13800000000"), "phone removed", out)
        h.check(!out.contains("SECRET"), "token in a query string removed", out)
        h.check(!out.contains("abcDEF123"), "bearer value removed", out)
        h.check(out.contains("实验报告") && out.contains("\"count\":3"), "ordinary fields stay", out)
        h.check(out.contains("page=1"), "other query parameters stay", out)
    }
}

enum KetangpaiTests {
    @MainActor
    static func run(_ h: Harness) async {
        h.suite = "ketangpai"

        // The scripts may only read.
        let called = KetangpaiAPI.pathsCalledByScripts
        h.equal(called, KetangpaiAPI.allowedPaths, "the scripts call exactly the allow-listed read-only paths")
        h.check(called.allSatisfy { KetangpaiAPI.isAllowed(path: $0) }, "every called path is allowed")
        let scripts = KetangpaiAPI.loginCheckScript + KetangpaiAPI.fetchScript
        for forbidden in ["ignoreTodo", "tagFinishedTodo", "submitHomework", "delete", "remove", "update", "save", "submit", "ignore"] {
            h.check(!scripts.localizedCaseInsensitiveContains(forbidden), "the scripts never mention “\(forbidden)”")
        }
        h.check(!KetangpaiAPI.isAllowed(path: "/Futurev2/Todo/tagFinishedTodo"), "writing endpoints are not allowed")
        h.check(scripts.contains("'token': token"), "the session token goes in the token header like the web app does")
        h.check(scripts.contains("cache: 'no-store'"), "a read never answers from the browser cache")
        h.check(scripts.contains("https://openapiv5.ketangpai.com/"), "the API host")

        // Parsing the calibrated shape
        guard let data = SourceTests.fixture("ketangpai_todo.json") else {
            h.check(false, "Tests/Fixtures/ketangpai_todo.json is readable")
            return
        }
        let body = String(decoding: data, as: UTF8.self)
        let items = (try? KetangpaiAPI.parse(body: body)) ?? []
        h.equal(items.map(\.title), ["第七周习题", "单元测验一"], "homework with a deadline and a quiz are imported; the item without any deadline is not")
        let hw = items.first
        h.equal(hw?.key, "ketangpai:4:CID_OPEN_A", "stable key from the content id")
        h.equal(hw?.course, "材料力学", "course name")
        h.equal(Fixture.format(hw?.due), "2026-10-29 23:00", "the deadline comes from the course's homework list (epoch seconds)")
        h.equal(hw?.completed, false, "to-do items are open")
        h.equal(hw?.url, "https://www.ketangpai.com/#/main/todo", "link to the to-do page")
        h.equal(Fixture.format(items.last?.due), "2026-11-02 21:30", "a deadline carried by the to-do entry itself is used (numeric epoch)")
        h.equal(items.filter { $0.key == "ketangpai:4:CID_OPEN_A" }.count, 1, "a duplicated to-do row does not duplicate the reminder")

        func parse(_ json: String) -> [RemoteItem] { (try? KetangpaiAPI.parse(body: json)) ?? [] }
        let ms = #"{"todo":[{"contentid":"X1","contenttitle":"毫秒时间","contenttype":"5","courseid":"C","coursename":"课","endtime":1793286000000}],"homework":{}}"#
        h.equal(Fixture.format(parse(ms).first?.due), "2026-10-29 23:00", "millisecond timestamps are tolerated")
        let str = #"{"todo":[{"contentid":"X2","contenttitle":"字符串时间","contenttype":"5","courseid":"C","coursename":"课","endtime":"1793286000"}],"homework":{}}"#
        h.equal(Fixture.format(parse(str).first?.due), "2026-10-29 23:00", "string timestamps are accepted")
        h.equal(parse(#"{"todo":[],"homework":{}}"#).count, 0, "an empty to-do list is fine")
        h.check((try? KetangpaiAPI.parse(body: "[]")) == nil, "a wrong shape is rejected")
        h.equal(parse(#"{"todo":[{"contentid":"","contenttitle":"","contenttype":"4"}],"homework":{}}"#).count, 0, "rows without id or title are ignored")

        // The source object
        let session = KFakeSession()
        let source = KetangpaiSource(session: session)
        session.results = [.success(WebFetchResult(status: 200, body: ""))]
        h.equal(await source.isLoggedIn(), true, "a working token means logged in")
        session.results = [.success(WebFetchResult(status: 401, body: ""))]
        h.equal(await source.isLoggedIn(), false, "no / rejected token means logged out")
        session.results = [.success(WebFetchResult(status: 200, body: body))]
        let fetched = try? await source.fetchItems()
        h.equal(fetched?.count, 2, "fetchItems parses the combined answer")
        session.results = [.success(WebFetchResult(status: 401, body: ""))]
        do { _ = try await source.fetchItems(); h.check(false, "401 throws") }
        catch { h.equal(error as? SourceError, .notLoggedIn, "401 -> not logged in") }
        session.results = [.success(WebFetchResult(status: 502, body: "系统繁忙"))]
        do { _ = try await source.fetchItems(); h.check(false, "502 throws") }
        catch { h.equal(error as? SourceError, .badResponse("系统繁忙"), "a failure status from the site carries its message") }

        // Items that vanish from the open-items list
        let watcher = WatcherConfig(id: "w-kt", kind: .ketangpai, name: "课堂派", url: "https://www.ketangpai.com/#/main")
        let now = Fixture.now
        let first = SyncEngine.reconcile(existing: [], remote: items, watcher: watcher, now: now, completeMissing: true)
        h.equal(first.added.count, 2, "both items are imported")
        let onlyQuiz = [items[1]]
        let second = SyncEngine.reconcile(existing: first.reminders, remote: onlyQuiz, watcher: watcher, now: now, completeMissing: true)
        h.equal(second.autoCompleted.map(\.title), ["第七周习题"], "an item that left the to-do list before its deadline is completed (submitted)")
        h.equal(second.reminders.first { $0.title == "第七周习题" }?.status, .done, "its status is done")
        let keep = SyncEngine.reconcile(existing: first.reminders, remote: onlyQuiz, watcher: watcher, now: now, completeMissing: false)
        h.equal(keep.autoCompleted.count, 0, "without the flag nothing is completed")
        let later = Fixture.date("2026-10-30 12:00")
        let third = SyncEngine.reconcile(existing: first.reminders, remote: [], watcher: watcher, now: later, completeMissing: true)
        h.equal(third.autoCompleted.map(\.title), ["第七周习题", "单元测验一"],
                "whatever left the site's to-do list is completed, also after its deadline (the site no longer lists it)")
        h.equal(third.missing.count, 0, "nothing is left half-way")
        let back = SyncEngine.reconcile(existing: third.reminders, remote: items, watcher: watcher, now: later, completeMissing: true)
        h.equal(back.reopened.count, 2, "if the site lists them again they are reopened")
        h.equal(back.reminders.filter { $0.status == .pending }.count, 2, "…and pending again")
    }
}

@MainActor
private final class KFakeSession: WebSessionFetching {
    var results: [Result<WebFetchResult, SourceError>] = []
    func fetch(script: String, baseURL: URL) async throws -> WebFetchResult {
        guard !results.isEmpty else { return WebFetchResult(status: 200, body: "") }
        return try results.removeFirst().get()
    }
    func pageText(url: URL) async throws -> String { "" }
}


enum CompletionRuleTests {
    static func run(_ h: Harness) {
        h.suite = "completion"
        h.equal(SourceKind.allCases.filter { $0.completionFollowsSite }, [.canvas, .ketangpai],
                "only Canvas and 课堂派 follow the site's completion state")
        h.equal(Reminder(title: "自己的", due: nil).completionFollowsSite, false, "own reminders are completed by hand")
        h.equal(Reminder(title: "x", due: nil, source: .canvas).completionFollowsSite, true, "Canvas items follow the site")
        h.equal(Reminder(title: "x", due: nil, source: .ketangpai).completionFollowsSite, true, "课堂派 items follow the site")
        h.equal(Reminder(title: "x", due: nil, source: .web).completionFollowsSite, false, "generic page items can be ticked by hand")
        h.equal(Reminder(title: "x", due: nil, source: .ketangpai).completionFollowsSite, true, "…and 课堂派 items cannot be deleted either")
    }
}
