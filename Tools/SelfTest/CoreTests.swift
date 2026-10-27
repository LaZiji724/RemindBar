import Foundation
import RemindCore

enum CoreTests {
    static func run(_ h: Harness) {
        router(h)
        reminders(h)
        scheduler(h)
        storage(h)
    }

    // MARK: intent routing

    private static func router(_ h: Harness) {
        h.suite = "router"
        let ctx = Fixture.context
        func kind(_ text: String) -> SourceKind? {
            if case .connect(let r) = IntentRouter.route(text, context: ctx) { return r.kind }
            return nil
        }
        h.equal(kind("监控课堂派的新作业"), .ketangpai, "课堂派 watch request")
        h.equal(kind("帮我盯着同济Canvas有没有新作业"), .canvas, "Canvas watch request")
        h.equal(kind("https://www.ketangpai.com/#/main 看看有没有新作业"), .ketangpai, "ketangpai URL")
        h.equal(kind("https://canvas.tongji.edu.cn/"), .canvas, "canvas URL")
        h.equal(kind("https://example.edu/portal 关注作业"), .web, "unknown site -> generic web")
        h.equal(kind("提醒我明天交课堂派作业"), nil, "reminder that merely mentions 课堂派")
        h.equal(kind("去睡觉，今晚19点"), nil, "plain reminder")
        h.equal(IntentRouter.route("   ", context: ctx), .empty, "blank text")
        if case .connect(let r) = IntentRouter.route("https://www.ketangpai.com/#/main 看看有没有新作业", context: ctx) {
            h.equal(r.url?.absoluteString, "https://www.ketangpai.com/#/main", "URL is carried over")
            h.equal(r.hint, "看看有没有新作业", "remaining text becomes the hint")
        } else {
            h.check(false, "URL + hint request routes to connect")
        }
    }

    // MARK: reminder model

    private static func reminders(_ h: Harness) {
        h.suite = "model"
        let deadline = NLParser.parse("周五前交作业", context: Fixture.context)[0]
        let r1 = Reminder(from: deadline, now: Fixture.now)
        h.equal(r1.leadTimes, LeadTimes.deadline, "deadline reminders get the deadline lead times")
        h.equal(r1.title, "交作业", "title carried over")
        let plain = NLParser.parse("明天下午3点开会", context: Fixture.context)[0]
        let r2 = Reminder(from: plain, now: Fixture.now)
        h.equal(r2.leadTimes, LeadTimes.manual, "plain reminders fire only at the due time")
        h.equal(r2.source, .manual, "manual source")
    }

    // MARK: fire planning

    private static func scheduler(_ h: Harness) {
        h.suite = "scheduler"
        let due = Fixture.date("2026-10-28 20:00")
        var r = Reminder(title: "交作业", due: due, isDeadline: true)
        let now = Fixture.now
        let all = FirePlanner.fires(for: r, after: now).map { Fixture.format($0.at) }
        h.equal(all, ["2026-10-27 20:00", "2026-10-28 17:00", "2026-10-28 19:30", "2026-10-28 20:00"],
                "deadline reminder fires 1d / 3h / 30m ahead and at the deadline")
        let later = FirePlanner.fires(for: r, after: Fixture.date("2026-10-28 18:00")).map { Fixture.format($0.at) }
        h.equal(later, ["2026-10-28 19:30", "2026-10-28 20:00"], "past alerts are skipped")

        r.snoozedUntil = Fixture.date("2026-10-26 22:00")
        let snoozed = FirePlanner.fires(for: r, after: now)
        h.equal(Fixture.format(snoozed.first?.at), "2026-10-26 22:00", "snooze adds an alert")
        h.equal(snoozed.first?.lead, -1, "snooze alert is marked")

        r.status = .done
        h.equal(FirePlanner.fires(for: r, after: now).count, 0, "completed reminders never fire")

        let many = (0..<100).map { i in
            Reminder(title: "r\(i)", due: now.addingTimeInterval(Double(i + 1) * 600))
        }
        let plan = FirePlanner.plan(many, after: now, limit: 60)
        h.equal(plan.count, 60, "plan is capped at the notification limit")
        h.equal(plan.first?.at, now.addingTimeInterval(600), "plan starts with the earliest alert")
        h.check(zip(plan, plan.dropFirst()).allSatisfy { $0.at <= $1.at }, "plan is sorted")

        let missed = FirePlanner.missed(many, from: now, to: now.addingTimeInterval(1_800))
        h.equal(missed.count, 3, "catch-up finds alerts inside (from, to]")
    }

    // MARK: persistence

    private static func storage(_ h: Harness) {
        h.suite = "storage"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remindbar-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = JSONStore<AppState>(url: dir.appendingPathComponent("state.json"))

        h.check((try? store.load()) == nil, "nothing saved yet -> nil")

        var s1 = AppState()
        s1.reminders = [Reminder(title: "第一版", due: Fixture.date("2026-10-27 09:00"))]
        s1.watchers = [WatcherConfig(kind: .canvas, name: "同济 Canvas", url: "https://canvas.tongji.edu.cn/")]
        do { try store.save(s1) } catch { h.check(false, "save succeeds", "\(error)") }
        let loaded = try? store.load()
        h.equal(loaded?.reminders.first?.title, "第一版", "round trip keeps reminders")
        h.equal(loaded?.watchers.first?.kind, .canvas, "round trip keeps watchers")
        h.equal(Fixture.format(loaded?.reminders.first?.due), "2026-10-27 09:00", "round trip keeps dates")

        var s2 = s1
        s2.reminders.append(Reminder(title: "第二版", due: nil))
        try? store.save(s2)
        try? Data("not json".utf8).write(to: store.url)
        let recovered = try? store.load()
        h.equal(recovered?.reminders.count, 1, "corrupt main file falls back to the previous generation")

        var s3 = s2
        s3.reminders.append(Reminder(title: "第三版", due: nil))
        try? store.save(s3)
        h.equal((try? store.load())?.reminders.count, 3, "saving over a corrupt file heals it")
        h.check(FileManager.default.fileExists(atPath: store.url.appendingPathExtension("bak").path), "backup exists")
    }
}
