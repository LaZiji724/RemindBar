import Foundation
import RemindCore

/// The two-way link with Apple's Reminders app, tested against an in-memory stand-in for it.
@MainActor
final class AppleRig {
    var reminders: [Reminder] = []
    var links: [AppleLink] = []
    let store: InMemoryAppleStore
    let managed: AppleList
    var shopping: AppleList
    var work: AppleList
    var options: AppleSyncEngine.Options
    var lastReport = AppleSyncEngine.Report()

    init(importShopping: Bool = true) {
        let cal = Fixture.calendar
        store = InMemoryAppleStore(calendar: cal, clock: { Fixture.now })
        managed = (try? store.createList(title: "提醒条")) ?? AppleList(id: "?", title: "?")
        shopping = store.userAddList("购物")
        work = store.userAddList("工作")
        options = AppleSyncEngine.Options(managedListID: managed.id, importListIDs: importShopping ? [shopping.id] : [],
                                          now: Fixture.now, calendar: cal, defaultHour: 9, defaultMinute: 0)
    }

    @discardableResult
    func sync() async -> AppleSyncEngine.Report {
        let ids = [options.managedListID] + options.importListIDs
        let fetched = (try? await store.fetchIncomplete(listIDs: ids)) ?? []
        let result = AppleSyncEngine.merge(reminders: reminders, links: links, fetched: fetched, store: store, options: options)
        reminders = result.reminders
        links = result.links
        lastReport = result.report
        return result.report
    }

    func reminder(_ title: String) -> Reminder? { reminders.first { $0.title == title } }
    func link(for title: String) -> AppleLink? { reminder(title).flatMap { r in links.first { $0.reminderID == r.id } } }
    func apple(for title: String) -> AppleItem? { link(for: title)?.appleID.flatMap { store.item(withID: $0) } }
    func appleItems(in list: AppleList? = nil) -> [AppleItem] {
        store.items.values.filter { list == nil || $0.listID == list!.id }.sorted { $0.fields.title < $1.fields.title }
    }
    func setReminder(_ title: String, _ change: (inout Reminder) -> Void) {
        if let i = reminders.firstIndex(where: { $0.title == title }) { change(&reminders[i]) }
    }
}

enum AppleSyncTests {
    static func date(_ s: String) -> Date { Fixture.date(s) }

    static func site(_ title: String, key: String, due: String, source: SourceKind = .canvas, seconds: Double = 0) -> Reminder {
        Reminder(title: title, due: date(due).addingTimeInterval(seconds), hasExplicitTime: true, isDeadline: true, source: source,
                 watcherID: "w-\(source.rawValue)", externalKey: key, course: "材料力学B", url: "https://canvas.tongji.edu.cn/courses/1/assignments/\(key.suffix(1))",
                 createdAt: Fixture.now)
    }

    static func own(_ title: String, due: String? = nil, timed: Bool = true) -> Reminder {
        Reminder(title: title, due: due.map(date), hasExplicitTime: timed, createdAt: Fixture.now)
    }

    @MainActor
    static func run(_ h: Harness) async {
        fields(h)
        await firstSync(h)
        await editsFromApple(h)
        await websiteCopies(h)
        await completion(h)
        await deletions(h)
        await safety(h)
        await importing(h)
        await conflicts(h)
        await ignoring(h)
        await settings(h)
        await identity(h)
        await robustness(h)
        storage(h)
    }

    // MARK: field normalisation

    @MainActor
    private static func fields(_ h: Harness) {
        h.suite = "apple-fields"
        let cal = Fixture.calendar
        let a = AppleFields(title: "  交作业\n", due: date("2026-10-28 23:59").addingTimeInterval(59), hasTime: true, completed: false, calendar: cal)
        let b = AppleFields(title: "交作业", due: date("2026-10-28 23:59"), hasTime: true, completed: false, calendar: cal)
        h.equal(a, b, "seconds and surrounding spaces do not matter")
        let d1 = AppleFields(title: "x", due: date("2026-10-28 15:30"), hasTime: false, completed: false, calendar: cal)
        let d2 = AppleFields(title: "x", due: date("2026-10-28 00:00"), hasTime: false, completed: false, calendar: cal)
        h.equal(d1, d2, "a date without a time is the start of its day, whatever time it carried")
        h.equal(d1.due.flatMap { Fixture.format($0) }, "2026-10-28 00:00", "…in the app's calendar")
        let n = AppleFields(title: "x", due: nil, hasTime: true, completed: false, calendar: cal)
        h.equal(n.hasTime, false, "no deadline means no time of day either")
        h.check(AppleFields(title: "x", due: date("2026-10-28 09:00"), hasTime: true, completed: false, calendar: cal)
                != AppleFields(title: "x", due: date("2026-10-28 09:00"), hasTime: false, completed: false, calendar: cal),
                "09:00 and a plain date are different deadlines")
    }

    // MARK: first sync

    @MainActor
    private static func firstSync(_ h: Harness) async {
        h.suite = "apple-first"
        let rig = AppleRig()
        var ignored = site("忽略的作业", key: "ketangpai:4:IGN", due: "2026-10-30 23:00", source: .ketangpai)
        ignored.ignored = true
        var finished = own("已完成的事", due: "2026-10-26 18:00")
        finished.status = .done
        finished.completedAt = Fixture.now
        rig.reminders = [
            own("去睡觉", due: "2026-10-26 23:00"),
            own("交材料", due: "2026-10-29 09:00", timed: false),
            own("买牛奶"),
            site("第六周作业", key: "canvas:assignment:1", due: "2026-10-28 23:59", seconds: 59),
            ignored, finished
        ]
        let report = await rig.sync()
        h.equal(report.created, 4, "own, date-only, undated and website items are written; done and ignored ones are not")
        h.equal(rig.appleItems(in: rig.managed).count, 4, "they all land in the managed list")
        h.check(rig.appleItems().allSatisfy { $0.listID == rig.managed.id }, "nothing is written anywhere else")
        h.equal(rig.links.count, 4, "every written reminder has a link")
        h.check(rig.links.allSatisfy { $0.origin == .app && !$0.optOut && $0.synced != nil }, "…made by the app, with the agreed values remembered")

        let bed = rig.apple(for: "去睡觉")
        h.equal(Fixture.format(bed?.fields.due), "2026-10-26 23:00", "a time is carried over")
        h.equal(bed?.fields.hasTime, true, "…as a time")
        h.equal(bed?.alarmDates.map { Fixture.format($0) ?? "" }, ["2026-10-26 23:00"], "a future timed item gets an alarm at its time")
        let material = rig.apple(for: "交材料")
        h.equal(Fixture.format(material?.fields.due), "2026-10-29 00:00", "a date without a time stays a plain date")
        h.equal(material?.fields.hasTime, false, "…without a time of day")
        h.equal(material?.alarmDates.count, 0, "…and without an alarm")
        let milk = rig.apple(for: "买牛奶")
        h.equal(milk?.fields.due == nil, true, "an undated reminder stays undated")
        h.equal(milk?.alarmDates.count, 0, "…and has no alarm")
        let canvas = rig.apple(for: "第六周作业")
        h.equal(Fixture.format(canvas?.fields.due), "2026-10-28 23:59", "a deadline's seconds are dropped")
        h.equal(canvas?.alarmDates.map { Fixture.format($0) ?? "" }, ["2026-10-28 23:59"], "a website deadline gets an alarm too")
        h.check(canvas?.notes?.contains("材料力学B") == true && canvas?.notes?.contains("Canvas") == true, "its note names the course and the site", canvas?.notes ?? "nil")
        h.check(canvas?.notes?.contains("以网站为准") == true, "…and says the website decides", canvas?.notes ?? "nil")
        h.equal(canvas?.url, "https://canvas.tongji.edu.cn/courses/1/assignments/1", "…and carries the link to the assignment")
        h.equal(bed?.notes == nil && bed?.url == nil, true, "an own reminder gets no note or link")
        h.equal(rig.apple(for: "已完成的事") == nil, true, "a finished reminder is not exported")
        h.equal(rig.apple(for: "忽略的作业") == nil, true, "an ignored one is not exported either")

        let writes = rig.store.writes
        let again = await rig.sync()
        h.equal(rig.store.writes, writes, "a second sync with no changes writes nothing")
        h.equal(again.changedAnything, false, "…and reports nothing")
        h.equal(again.text, "已是最新", "…as 已是最新")
        h.equal(rig.reminders.count, 6, "…and the reminder list is untouched")
    }

    // MARK: edits made in the Reminders app

    @MainActor
    private static func editsFromApple(_ h: Harness) async {
        h.suite = "apple-pull"
        let rig = AppleRig()
        rig.reminders = [own("开会", due: "2026-10-27 15:00"), own("写周报", due: "2026-10-29 09:00", timed: false)]
        await rig.sync()
        let meeting = rig.link(for: "开会")!.appleID!
        let report = rig.link(for: "写周报")!.appleID!

        rig.store.userSetTitle(meeting, "开项目会")
        rig.store.userSetDue(meeting, date("2026-10-27 16:30"), moveAlarms: true)
        let w = rig.store.writes
        await rig.sync()
        h.equal(rig.reminder("开项目会")?.title, "开项目会", "a new title in Reminders comes over")
        h.equal(Fixture.format(rig.reminder("开项目会")?.due), "2026-10-27 16:30", "…and a new time")
        h.equal(rig.reminder("开项目会")?.hasExplicitTime, true, "…still with a time")
        h.equal(rig.store.writes, w, "taking over an edit writes nothing back")
        h.equal(rig.apple(for: "开项目会")?.alarmDates.map { Fixture.format($0) ?? "" }, ["2026-10-27 16:30"], "…the alarm Reminders moved stays as it is")
        // Were the alarm left behind at the old time, the app would put it right (only that).
        rig.store.userSetDue(meeting, date("2026-10-27 18:00"))
        await rig.sync()
        h.equal(rig.apple(for: "开项目会")?.alarmDates.map { Fixture.format($0) ?? "" }, ["2026-10-27 18:00"], "an alarm left at the old time is moved to the new one")
        rig.store.userSetDue(meeting, date("2026-10-27 16:30"), moveAlarms: true)
        await rig.sync()

        rig.store.userSetDue(report, date("2026-10-30 18:00"), hasTime: true)
        await rig.sync()
        h.equal(Fixture.format(rig.reminder("写周报")?.due), "2026-10-30 18:00", "a time added in Reminders makes the deadline timed")
        h.equal(rig.reminder("写周报")?.hasExplicitTime, true, "…and the reminder knows it has a time")
        rig.store.userSetDue(report, date("2026-10-31 00:00"), hasTime: false)
        await rig.sync()
        h.equal(rig.reminder("写周报")?.hasExplicitTime, false, "taking the time away makes it a plain date")
        h.equal(Fixture.format(rig.reminder("写周报")?.due), "2026-10-31 09:00", "…which is reminded at the default time of day")
        rig.store.userSetDue(report, nil)
        await rig.sync()
        h.equal(rig.reminder("写周报")?.due == nil, true, "removing the date in Reminders removes the deadline")
        let w2 = rig.store.writes
        await rig.sync()
        h.equal(rig.store.writes, w2, "and then everything is quiet again")

        // The same in the other direction: an edit of the date here is carried over.
        rig.setReminder("开项目会") { $0.due = date("2026-10-27 17:00") }
        await rig.sync()
        h.equal(Fixture.format(rig.apple(for: "开项目会")?.fields.due), "2026-10-27 17:00", "a new time here is written to Reminders")
        h.equal(rig.apple(for: "开项目会")?.alarmDates.map { Fixture.format($0) ?? "" }, ["2026-10-27 17:00"], "…and the alarm moves with it")
    }

    // MARK: website copies are a mirror

    @MainActor
    private static func websiteCopies(_ h: Harness) async {
        h.suite = "apple-site"
        let rig = AppleRig()
        rig.reminders = [site("第六周作业", key: "canvas:assignment:1", due: "2026-10-28 23:59")]
        await rig.sync()
        let id = rig.link(for: "第六周作业")!.appleID!

        rig.store.userSetTitle(id, "我改的标题")
        rig.store.userSetDue(id, date("2026-10-29 12:00"))
        let w = rig.store.writes
        await rig.sync()
        h.equal(rig.reminders.first?.title, "第六周作业", "edits to a website copy never reach the app (title)")
        h.equal(Fixture.format(rig.reminders.first?.due), "2026-10-28 23:59", "…nor the deadline")
        h.equal(rig.store.writes, w, "…and the app does not fight the edit either")
        await rig.sync()
        h.equal(rig.store.writes, w, "…however often it syncs")

        // Ticking the copy does not complete the item: the website decides.
        rig.store.userSetCompleted(id, true)
        await rig.sync()
        h.equal(rig.reminders.first?.status, .pending, "ticking the copy leaves the item open here")
        h.equal(rig.store.writes, w, "…and the tick stays on the copy")
        // The website then finishes it: both agree, nothing to write.
        rig.setReminder("第六周作业") { $0.status = .done; $0.completedAt = Fixture.now }
        await rig.sync()
        h.equal(rig.store.writes, w, "when the website agrees there is nothing to write")
        h.equal(rig.apple(for: "第六周作业")?.fields.completed, true, "…and the copy stays ticked")
        // …and reopens it: the copy is reopened as well.
        rig.setReminder("第六周作业") { $0.status = .pending; $0.completedAt = nil }
        await rig.sync()
        h.equal(rig.apple(for: "第六周作业")?.fields.completed, false, "when the website reopens it the copy is reopened")

        // The website moves the deadline: the copy follows, also over the user's edit of it.
        rig.setReminder("第六周作业") { $0.due = date("2026-10-30 23:59") }
        await rig.sync()
        h.equal(Fixture.format(rig.apple(for: "第六周作业")?.fields.due), "2026-10-30 23:59", "a deadline moved by the website moves the copy")
        h.equal(rig.apple(for: "第六周作业")?.alarmDates.map { Fixture.format($0) ?? "" }, ["2026-10-30 23:59"], "…and its alarm")
        h.equal(rig.apple(for: "第六周作业")?.fields.title, "我改的标题", "…while an edit of the title that the website did not touch stays as it is")

        // The website finishes it while the copy is open: the copy is ticked.
        rig.setReminder("第六周作业") { $0.status = .done; $0.completedAt = Fixture.now }
        await rig.sync()
        h.equal(rig.apple(for: "第六周作业")?.fields.completed, true, "an item the website finished is ticked on the copy")
    }

    // MARK: completion on own reminders

    @MainActor
    private static func completion(_ h: Harness) async {
        h.suite = "apple-done"
        let rig = AppleRig()
        rig.reminders = [own("洗衣服", due: "2026-10-27 10:00"), own("寄快递", due: "2026-10-27 12:00")]
        await rig.sync()
        let laundry = rig.link(for: "洗衣服")!.appleID!

        rig.store.userSetCompleted(laundry, true)
        await rig.sync()
        h.equal(rig.reminder("洗衣服")?.status, .done, "ticking in Reminders completes it here")
        h.check(rig.reminder("洗衣服")?.completedAt != nil, "…with a completion time")
        let w = rig.store.writes
        await rig.sync()
        h.equal(rig.store.writes, w, "…and nothing bounces back")
        rig.setReminder("洗衣服") { $0.status = .pending; $0.completedAt = nil }
        await rig.sync()
        h.equal(rig.apple(for: "洗衣服")?.fields.completed, false, "reopening here unticks it in Reminders")

        rig.setReminder("寄快递") { $0.status = .done; $0.completedAt = Fixture.now }
        let count = rig.store.items.count
        await rig.sync()
        h.equal(rig.apple(for: "寄快递")?.fields.completed, true, "completing here ticks it in Reminders")
        h.equal(rig.store.items.count, count, "…without creating or losing anything")
        await rig.sync()
        h.equal(rig.reminder("寄快递")?.status, .done, "…and it stays done after the next sync")

        // Finished long ago and in step: the pair is forgotten (the reminder itself stays).
        var old = rig.reminder("寄快递")!
        old.completedAt = Fixture.now.addingTimeInterval(-15 * 86_400)
        rig.setReminder("寄快递") { $0 = old }
        await rig.sync()
        h.equal(rig.link(for: "寄快递") == nil, true, "a pair finished more than two weeks ago is forgotten")
        h.equal(rig.reminder("寄快递")?.status, .done, "…the reminder stays")
        let w2 = rig.store.writes
        await rig.sync()
        h.equal(rig.store.writes, w2, "…and a done reminder is not exported again")
    }

    // MARK: deletions

    @MainActor
    private static func deletions(_ h: Harness) async {
        h.suite = "apple-delete"
        let rig = AppleRig()
        rig.reminders = [own("A事", due: "2026-10-27 10:00"), own("B事", due: "2026-10-27 11:00"), own("C事", due: "2026-10-27 12:00"),
                         own("D事", due: "2026-10-27 13:00"), site("网站作业", key: "canvas:assignment:1", due: "2026-10-28 23:59"),
                         own("E事", due: "2026-10-27 14:00"), own("F事", due: "2026-10-27 15:00")]
        await rig.sync()

        // Deleted in Reminders: gone here too.
        rig.store.userDelete(rig.link(for: "A事")!.appleID!)
        let report = await rig.sync()
        h.equal(rig.reminder("A事") == nil, true, "deleting in Reminders deletes here")
        h.equal(report.removedLocal, 1, "…and says so")
        h.equal(rig.links.count, 6, "…and forgets the pair")
        let w = rig.store.writes
        await rig.sync()
        h.equal(rig.store.writes, w, "…and nothing is written back")

        // Deleted here: gone in Reminders too.
        let bID = rig.link(for: "B事")!.appleID!
        rig.reminders.removeAll { $0.title == "B事" }
        let report2 = await rig.sync()
        h.equal(rig.store.item(withID: bID) == nil, true, "deleting here deletes in Reminders")
        h.equal(report2.removedApple, 1, "…and says so")
        h.equal(rig.links.count, 5, "…and forgets the pair")

        // A website item whose copy is deleted keeps being tracked but is never copied again.
        rig.store.userDelete(rig.link(for: "网站作业")!.appleID!)
        let report3 = await rig.sync()
        h.equal(rig.reminder("网站作业") != nil, true, "deleting a website copy does not delete the item")
        h.equal(report3.optedOut, 1, "…the pair just stops being synced")
        h.equal(rig.link(for: "网站作业")?.optOut, true, "…and is remembered as opted out")
        let w3 = rig.store.writes
        await rig.sync()
        await rig.sync()
        h.equal(rig.store.writes, w3, "…so the copy is not made again")
        h.equal(rig.appleItems().contains { $0.fields.title == "网站作业" }, false, "…not even later")
        rig.reminders.removeAll { $0.title == "网站作业" }
        await rig.sync()
        h.equal(rig.links.contains { $0.optOut }, false, "when the item itself is gone the opt-out is cleaned up")

        // Finished here and deleted there: the finished reminder stays as it is.
        rig.setReminder("C事") { $0.status = .done; $0.completedAt = Fixture.now }
        await rig.sync()
        rig.store.userDelete(rig.link(for: "C事")!.appleID!)
        await rig.sync()
        h.equal(rig.reminder("C事")?.status, .done, "a finished reminder survives the deletion of its copy")
        h.equal(rig.link(for: "C事") == nil, true, "…only the pair is dropped")
    }

    // MARK: the brake against wiping either side

    @MainActor
    private static func safety(_ h: Harness) async {
        h.suite = "apple-safety"
        // Everything vanishes from Reminders at once (a store that came back empty, a list removed…).
        do {
            let rig = AppleRig()
            rig.reminders = (1...6).map { own("事项\($0)", due: "2026-10-27 \(String(format: "%02d", 8 + $0)):00") }
            await rig.sync()
            for item in rig.store.items.values { rig.store.userDelete(item.id) }
            let report = await rig.sync()
            h.equal(rig.reminders.count, 6, "six reminders vanishing from Reminders at once delete nothing here")
            h.check(!report.warnings.isEmpty, "…and a warning says why")
            h.equal(rig.store.items.count, 6, "…and they are written to Reminders again")
        }
        // Everything vanishes here at once (a reset state).
        do {
            let rig = AppleRig()
            rig.reminders = (1...6).map { own("事项\($0)", due: "2026-10-27 \(String(format: "%02d", 8 + $0)):00") }
            await rig.sync()
            rig.reminders = []
            let report = await rig.sync()
            h.equal(rig.store.items.count, 6, "six reminders vanishing here at once delete nothing in Reminders")
            h.check(!report.warnings.isEmpty, "…and a warning says why")
            h.equal(rig.reminders.count, 6, "…and they are brought back here")
        }
        // A couple of deletions are normal.
        do {
            let rig = AppleRig()
            rig.reminders = (1...6).map { own("事项\($0)", due: "2026-10-27 \(String(format: "%02d", 8 + $0)):00") }
            await rig.sync()
            rig.reminders.removeAll { ["事项1", "事项2", "事项3"].contains($0.title) }
            await rig.sync()
            h.equal(rig.store.items.count, 3, "three deliberate deletions go through")
            h.equal(rig.reminders.count, 3, "…and the deleted ones do not come back from Reminders")
            h.equal(rig.links.count, 3, "…and their pairs are gone")
        }
    }

    // MARK: importing

    @MainActor
    private static func importing(_ h: Harness) async {
        h.suite = "apple-import"
        let rig = AppleRig()
        let siri = rig.store.userAdd(title: "明天交作业", due: date("2026-10-27 15:00"), in: rig.managed.id)
        rig.store.userAdd(title: "买牛奶", due: date("2026-10-27 00:00"), hasTime: false, in: rig.shopping.id)
        rig.store.userAdd(title: "买鸡蛋", in: rig.shopping.id)
        rig.store.userAdd(title: "工作的事", due: date("2026-10-27 10:00"), in: rig.work.id)
        let done = rig.store.userAdd(title: "已经做完", due: date("2026-10-26 10:00"), in: rig.managed.id)
        rig.store.userSetCompleted(done, true)
        rig.store.userAdd(title: "每周例会", due: date("2026-10-27 10:00"), in: rig.managed.id, recurring: true)
        rig.store.userAdd(title: "   ", in: rig.managed.id)
        let report = await rig.sync()
        h.equal(report.imported, 3, "incomplete reminders of the synced lists are imported")
        h.equal(Set(rig.reminders.map(\.title)), ["明天交作业", "买牛奶", "买鸡蛋"], "…and only those")
        h.check(rig.reminders.allSatisfy { $0.source == .apple }, "they are marked as coming from Reminders")
        h.equal(Fixture.format(rig.reminder("明天交作业")?.due), "2026-10-27 15:00", "a time is carried over")
        h.equal(rig.reminder("明天交作业")?.hasExplicitTime, true, "…as a time")
        h.equal(Fixture.format(rig.reminder("买牛奶")?.due), "2026-10-27 09:00", "a date alone is reminded at the default time")
        h.equal(rig.reminder("买牛奶")?.hasExplicitTime, false, "…and knows the time was not given")
        h.equal(rig.reminder("买鸡蛋")?.due == nil, true, "an undated reminder stays undated")
        h.equal(rig.reminder("明天交作业")?.leadTimes, LeadTimes.manual, "…and alerts only at its time")
        h.check(rig.links.allSatisfy { $0.origin == .apple && $0.synced != nil }, "the links remember where they came from")
        h.equal(rig.store.writes, 0, "importing writes nothing to Reminders")
        let again = await rig.sync()
        h.equal(again.changedAnything, false, "importing is done once")
        h.equal(rig.reminders.count, 3, "…not repeated")
        h.equal(rig.store.item(withID: siri)?.alarmDates.count, 0, "the app never adds alarms to what you made in Reminders")

        // Importing more lists later brings those in.
        rig.options.importListIDs.append(rig.work.id)
        await rig.sync()
        h.equal(rig.reminder("工作的事") != nil, true, "adding a list to the import brings its reminders in")

        // Importing stops at the limit and carries on next time.
        let big = AppleRig()
        for i in 1...7 { big.store.userAdd(title: "批量\(i)", due: date("2026-10-27 10:00").addingTimeInterval(Double(i) * 60), in: big.managed.id) }
        big.options.maxImport = 5
        let first = await big.sync()
        h.equal(first.imported, 5, "at most the limit is imported in one run")
        h.check(!first.warnings.isEmpty, "…with a note")
        await big.sync()
        h.equal(big.reminders.count, 7, "the rest follow in the next run")
    }

    // MARK: both sides changed the same thing

    @MainActor
    private static func conflicts(_ h: Harness) async {
        h.suite = "apple-conflict"
        let rig = AppleRig()
        rig.reminders = [own("原标题", due: "2026-10-27 10:00"), site("网站作业", key: "canvas:assignment:1", due: "2026-10-28 23:59")]
        await rig.sync()
        let ownID = rig.link(for: "原标题")!.appleID!
        let siteID = rig.link(for: "网站作业")!.appleID!

        rig.setReminder("原标题") { $0.title = "本机改的"; $0.due = date("2026-10-27 11:00") }
        rig.store.userSetTitle(ownID, "提醒事项改的")
        rig.store.userSetDue(ownID, date("2026-10-27 12:00"))
        await rig.sync()
        h.equal(rig.reminders.first { $0.id == rig.link(for: "提醒事项改的")?.reminderID }?.title, "提醒事项改的", "when both sides edit the title, Reminders wins")
        h.equal(Fixture.format(rig.reminder("提醒事项改的")?.due), "2026-10-27 12:00", "…and the time")
        h.equal(rig.store.item(withID: ownID)?.fields.title, "提醒事项改的", "…and it stays as it was in Reminders")

        // One field each: both survive.
        rig.setReminder("提醒事项改的") { $0.title = "只改标题" }
        rig.store.userSetDue(ownID, date("2026-10-27 13:00"))
        await rig.sync()
        h.equal(rig.reminder("只改标题")?.title, "只改标题", "a title changed here and a time changed there both survive (title)")
        h.equal(Fixture.format(rig.reminder("只改标题")?.due), "2026-10-27 13:00", "…(time)")
        h.equal(rig.store.item(withID: ownID)?.fields.title, "只改标题", "…and both are on the Reminders side as well")

        // A website item: the website wins.
        rig.setReminder("网站作业") { $0.title = "网站改的标题" }
        rig.store.userSetTitle(siteID, "我在提醒事项里改的")
        await rig.sync()
        h.equal(rig.store.item(withID: siteID)?.fields.title, "网站改的标题", "for a website item the website's title wins")
        h.equal(rig.reminders.contains { $0.title == "网站改的标题" }, true, "…and the app keeps it")
    }

    // MARK: ignoring

    @MainActor
    private static func ignoring(_ h: Harness) async {
        h.suite = "apple-ignore"
        let rig = AppleRig()
        rig.reminders = [site("第六周作业", key: "canvas:assignment:1", due: "2026-10-28 23:59"), own("自己的事", due: "2026-10-27 10:00")]
        await rig.sync()
        let copy = rig.link(for: "第六周作业")!.appleID!
        rig.setReminder("第六周作业") { $0.ignored = true }
        let report = await rig.sync()
        h.equal(rig.store.item(withID: copy) == nil, true, "ignoring an item takes its copy out of Reminders")
        h.equal(report.removedApple, 1, "…and says so")
        h.equal(rig.link(for: "第六周作业") == nil, true, "…and forgets the pair")
        h.equal(rig.reminder("第六周作业") != nil, true, "…while the item itself stays tracked here")
        let w = rig.store.writes
        await rig.sync()
        h.equal(rig.store.writes, w, "…and it is not copied again while ignored")

        rig.setReminder("第六周作业") { $0.ignored = false }
        await rig.sync()
        h.equal(rig.apple(for: "第六周作业") != nil, true, "restoring an item copies it to Reminders again")
        h.equal(rig.appleItems().filter { $0.fields.title == "第六周作业" }.count, 1, "…once")
    }

    // MARK: switches

    @MainActor
    private static func settings(_ h: Harness) async {
        h.suite = "apple-settings"
        let rig = AppleRig()
        rig.reminders = [site("网站作业", key: "canvas:assignment:1", due: "2026-10-28 23:59"), own("自己的事", due: "2026-10-27 10:00")]
        await rig.sync()
        h.equal(rig.appleItems().count, 2, "both are copied at first")

        rig.options.includeWebsiteItems = false
        let off = await rig.sync()
        h.equal(rig.appleItems().map(\.fields.title), ["自己的事"], "switching website items off removes their copies")
        h.equal(off.removedApple, 1, "…and nothing else")
        h.equal(rig.reminder("网站作业") != nil, true, "…the items themselves stay")
        rig.options.includeWebsiteItems = true
        await rig.sync()
        h.equal(rig.appleItems().count, 2, "switching them on again copies them again")

        // Alarms
        let rig2 = AppleRig()
        rig2.options.alarms = false
        rig2.reminders = [own("开会", due: "2026-10-27 15:00")]
        await rig2.sync()
        h.equal(rig2.apple(for: "开会")?.alarmDates.count, 0, "with alarms off a copy gets none")
        rig2.options.alarms = true
        await rig2.sync()
        h.equal(rig2.apple(for: "开会")?.alarmDates.map { Fixture.format($0) ?? "" }, ["2026-10-27 15:00"], "switching them on adds the alarm to existing copies")
        let w = rig2.store.writes
        await rig2.sync()
        h.equal(rig2.store.writes, w, "…once")
        rig2.options.alarms = false
        await rig2.sync()
        h.equal(rig2.apple(for: "开会")?.alarmDates.count, 0, "switching them off takes the alarm away again")

        // A reminder in the past gets no alarm, and a finished one keeps nothing to ring.
        let rig3 = AppleRig()
        rig3.reminders = [own("早就过了", due: "2026-10-26 08:00")]
        await rig3.sync()
        h.equal(rig3.apple(for: "早就过了")?.alarmDates.count, 0, "an alarm in the past is not created")
        // What the user made in Reminders is never given alarms by the app.
        let rig4 = AppleRig()
        rig4.store.userAdd(title: "他自己的", due: date("2026-10-27 15:00"), in: rig4.managed.id)
        await rig4.sync()
        await rig4.sync()
        h.equal(rig4.appleItems().first?.alarmDates.count, 0, "an imported reminder keeps exactly the alarms it had")
    }

    // MARK: identity

    @MainActor
    private static func identity(_ h: Harness) async {
        h.suite = "apple-identity"
        // The database renumbers a reminder: it is found again by its server identifier.
        do {
            let rig = AppleRig()
            rig.reminders = [own("开会", due: "2026-10-27 15:00")]
            await rig.sync()
            let old = rig.link(for: "开会")!.appleID!
            let new = rig.store.userRekey(old)!
            let w = rig.store.writes
            await rig.sync()
            h.equal(rig.link(for: "开会")?.appleID, new, "a renumbered reminder keeps its pair")
            h.equal(rig.store.items.count, 1, "…without a duplicate")
            h.equal(rig.store.writes, w, "…and without writing anything")
            h.equal(rig.reminders.count, 1, "…or losing anything here")
            // …also when it is completed (then it is not among the incomplete ones).
            rig.store.userSetCompleted(new, true)
            let new2 = rig.store.userRekey(new)!
            await rig.sync()
            h.equal(rig.reminder("开会")?.status, .done, "a renumbered completed reminder is still found")
            h.equal(rig.link(for: "开会")?.appleID, new2, "…with its new number")
        }
        // The same reminder is already in the managed list but the link is lost: pair them, do not duplicate.
        do {
            let rig = AppleRig()
            rig.reminders = [own("去睡觉", due: "2026-10-26 23:00")]
            rig.store.userAdd(title: "去睡觉", due: date("2026-10-26 23:00"), in: rig.managed.id)
            let report = await rig.sync()
            h.equal(report.relinked, 1, "an identical reminder in the managed list is paired up")
            h.equal(rig.store.items.count, 1, "…not duplicated")
            h.equal(rig.reminders.count, 1, "…and not imported twice")
        }
        // Ambiguous: two identical ones there. Nothing is guessed.
        do {
            let rig = AppleRig()
            rig.reminders = [own("去睡觉", due: "2026-10-26 23:00")]
            rig.store.userAdd(title: "去睡觉", due: date("2026-10-26 23:00"), in: rig.managed.id)
            rig.store.userAdd(title: "去睡觉", due: date("2026-10-26 23:00"), in: rig.managed.id)
            let report = await rig.sync()
            h.equal(report.relinked, 0, "two identical candidates are not paired")
            h.equal(rig.reminders.count, 3, "…each becomes its own reminder")
        }
        // Moves between lists.
        do {
            let rig = AppleRig()
            rig.reminders = [own("开会", due: "2026-10-27 15:00")]
            await rig.sync()
            let id = rig.link(for: "开会")!.appleID!
            rig.store.userMove(id, to: rig.shopping.id)
            let w = rig.store.writes
            await rig.sync()
            h.equal(rig.link(for: "开会")?.listID, rig.shopping.id, "a move into another synced list is followed")
            h.equal(rig.store.writes, w, "…without writing")
            rig.store.userMove(id, to: rig.work.id)
            let report = await rig.sync()
            h.equal(report.optedOut, 1, "a move out of the synced lists ends the pairing")
            h.equal(rig.reminder("开会") != nil, true, "…and keeps the reminder here")
            let w2 = rig.store.writes
            await rig.sync()
            h.equal(rig.store.writes, w2, "…without making a new copy")
            h.equal(rig.store.items.count, 1, "…so there is still just the moved one")
        }
        // A reminder that becomes a repeating one over there is left to Reminders.
        do {
            let rig = AppleRig()
            rig.reminders = [own("开会", due: "2026-10-27 15:00")]
            await rig.sync()
            rig.store.userSetRecurring(rig.link(for: "开会")!.appleID!)
            let report = await rig.sync()
            h.equal(report.skippedRecurring, 1, "a reminder that starts repeating in Reminders is no longer synced")
            h.equal(rig.link(for: "开会")?.optOut, true, "…and never copied again")
            h.equal(rig.reminder("开会") != nil, true, "…but kept here")
        }
    }

    // MARK: failures

    @MainActor
    private static func robustness(_ h: Harness) async {
        h.suite = "apple-robust"
        let rig = AppleRig()
        rig.reminders = [own("开会", due: "2026-10-27 15:00")]
        rig.store.failWrites = true
        let report = await rig.sync()
        h.equal(report.failures.count, 1, "a failing write is reported")
        h.equal(rig.links.count, 0, "…and no pair is recorded for it")
        h.equal(rig.reminders.count, 1, "…and nothing is lost here")
        rig.store.failWrites = false
        let ok = await rig.sync()
        h.equal(ok.created, 1, "the next sync tries again and succeeds")
        h.equal(ok.failures.count, 0, "…cleanly")

        // A failing update keeps the old base, so it is retried.
        rig.setReminder("开会") { $0.due = date("2026-10-27 16:00") }
        rig.store.failWrites = true
        let failed = await rig.sync()
        h.equal(failed.failures.count, 1, "a failing update is reported")
        h.equal(Fixture.format(rig.apple(for: "开会")?.fields.due), "2026-10-27 15:00", "…and Reminders keeps the old time")
        rig.store.failWrites = false
        await rig.sync()
        h.equal(Fixture.format(rig.apple(for: "开会")?.fields.due), "2026-10-27 16:00", "…until the next sync pushes it")

        // A failing removal keeps the pair, so it is retried.
        let id = rig.link(for: "开会")!.appleID!
        rig.reminders = []
        rig.store.failWrites = true
        let removal = await rig.sync()
        h.equal(removal.failures.count, 1, "a failing removal is reported")
        h.equal(rig.store.item(withID: id) != nil, true, "…and the copy is still there")
        rig.store.failWrites = false
        await rig.sync()
        h.equal(rig.store.item(withID: id) == nil, true, "…until the next sync removes it")

        // Plain bookkeeping that must never crash.
        let empty = AppleRig()
        let none = await empty.sync()
        h.equal(none.changedAnything, false, "syncing nothing with nothing does nothing")
    }

    // MARK: persistence

    @MainActor
    private static func storage(_ h: Harness) {
        h.suite = "apple-storage"
        var state = AppleSyncState()
        state.config.enabled = true
        state.config.managedListID = "L1"
        state.config.importListIDs = ["L2", "L3"]
        state.config.includeWebsiteItems = false
        state.config.alarms = false
        let fields = AppleFields(title: "x", due: date("2026-10-27 15:00"), hasTime: true, completed: false, calendar: Fixture.calendar)
        state.links = [AppleLink(reminderID: UUID(), appleID: "A", externalID: "E", listID: "L1", synced: fields, origin: .app),
                       AppleLink(reminderID: UUID(), appleID: nil, externalID: nil, listID: nil, synced: nil, origin: .app, optOut: true)]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? encoder.encode(state), let back = try? decoder.decode(AppleSyncState.self, from: data) {
            h.equal(back, state, "the link state survives saving and loading")
        } else {
            h.check(false, "the link state can be encoded and decoded")
        }
        if let empty = try? decoder.decode(AppleSyncState.self, from: Data("{}".utf8)) {
            h.equal(empty, AppleSyncState(), "an empty object decodes to the defaults")
            h.equal(empty.config.includeWebsiteItems, true, "…website items on")
            h.equal(empty.config.alarms, true, "…alarms on")
            h.equal(empty.config.enabled, false, "…and the link off")
        } else {
            h.check(false, "an empty object decodes")
        }
        if let partial = try? decoder.decode(AppleSyncConfig.self, from: Data(#"{"enabled":true}"#.utf8)) {
            h.equal(partial.enabled, true, "a config with missing keys still loads")
            h.equal(partial.managedListTitle, "提醒条", "…with the default list name")
        } else {
            h.check(false, "a partial config decodes")
        }
        h.equal(AppleSyncEngine.defaultImportLimit, 30, "a default list of up to 30 open reminders is brought along")
        h.equal(AppleSyncConfig().defaultListOffered, false, "the default list has not been offered at first")
        if let flagged = try? decoder.decode(AppleSyncConfig.self, from: Data(#"{"defaultListOffered":true}"#.utf8)) {
            h.equal(flagged.defaultListOffered, true, "…and the fact that it was offered is remembered")
        } else {
            h.check(false, "a config with the offered flag decodes")
        }
        var app = AppState()
        h.equal(app.apple == nil, true, "a state that never used the link stores nothing about it")
        app.apple = state
        if let data = try? encoder.encode(app), let back = try? decoder.decode(AppState.self, from: data) {
            h.equal(back.apple, state, "the link state lives inside the app state")
        } else {
            h.check(false, "the app state with a link can be encoded and decoded")
        }
    }
}
