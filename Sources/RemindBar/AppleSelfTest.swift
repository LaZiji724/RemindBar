import AppKit
import RemindCore

/// `RemindBar --apple-selftest <outfile>`: runs the sync engine against the REAL Reminders database, inside a temporary list
/// that is removed again at the end. Nothing else in the user's Reminders is read or changed.
/// Start it with `open -n -W -a <app> --args --apple-selftest <outfile>` so the system's permission dialog is attributed to
/// this app (and the person can answer it once).
@MainActor
enum AppleSelfTest {
    static func run(outputPath: String) async {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            lines.append((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  — " + detail))
            if !ok { failures += 1 }
        }
        func flush() { try? lines.joined(separator: "\n").write(toFile: outputPath, atomically: true, encoding: .utf8) }

        let cal = Calendar.reminder
        let store = EventKitStore(calendar: cal)
        lines.append("authorisation at start: \(store.access())")
        flush()
        if store.access() == .notDetermined {
            lines.append("waiting for the answer to the system's permission dialog (up to 3 minutes)…")
            flush()
            Task { _ = await store.requestAccess() }
            var waited = 0.0
            while store.access() == .notDetermined && waited < 180 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                waited += 0.5
            }
        }
        check(store.access() == .full, "the app may read and write reminders", "\(store.access())")
        guard store.access() == .full else {
            lines.append("RESULT: NO ACCESS")
            flush()
            return
        }

        // Leftovers of an earlier run that was interrupted.
        for list in store.lists() where list.title.hasPrefix("提醒条自检") { try? store.removeList(id: list.id) }

        let title = "提醒条自检-\(Int.random(in: 1000...9999))"
        var tempList: AppleList?
        do {
            tempList = try store.createList(title: title)
        } catch {
            check(false, "a temporary list can be created", error.localizedDescription)
        }
        if let list = tempList {
            check(store.lists().contains { $0.id == list.id && $0.title == title && $0.writable }, "the temporary list exists and is writable",
                  "account: \(list.account)")
            await scenario(store: store, list: list, cal: cal, check: check, log: { lines.append($0) })
            do { try store.removeList(id: list.id) } catch { check(false, "the temporary list can be removed", error.localizedDescription) }
            check(!store.lists().contains { $0.id == list.id }, "the temporary list is gone again")
        }
        lines.append("")
        lines.append("RESULT: \(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")")
        flush()
    }

    // MARK: the scenario

    private static func scenario(store: EventKitStore, list: AppleList, cal: Calendar,
                                 check record: (Bool, String, String) -> Void, log: (String) -> Void) async {
        func check(_ ok: Bool, _ name: String, _ detail: String = "") { record(ok, name, detail) }
        func minute(_ d: Date) -> Date { Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded(.down) * 60) }
        func fmt(_ d: Date?) -> String {
            guard let d else { return "nil" }
            let f = DateFormatter(); f.calendar = cal; f.timeZone = cal.timeZone; f.dateFormat = "MM-dd HH:mm"
            return f.string(from: d)
        }

        var reminders: [Reminder] = []
        var links: [AppleLink] = []
        @discardableResult
        func sync(_ label: String) async -> AppleSyncEngine.Report {
            let fetched = (try? await store.fetchIncomplete(listIDs: [list.id])) ?? []
            let options = AppleSyncEngine.Options(managedListID: list.id, now: Date(), calendar: cal, defaultHour: 9, defaultMinute: 0)
            let result = AppleSyncEngine.merge(reminders: reminders, links: links, fetched: fetched, store: store, options: options)
            reminders = result.reminders
            links = result.links
            log("  · \(label): \(result.report.text)" + (result.report.failures.isEmpty ? "" : " | " + result.report.failures.joined(separator: "; ")))
            return result.report
        }
        func appleItem(_ title: String) async -> AppleItem? {
            let items = (try? await store.fetchIncomplete(listIDs: [list.id])) ?? []
            if let hit = items.first(where: { $0.fields.title == title }) { return hit }
            // completed ones are not among the incomplete
            return links.compactMap { l in l.appleID.flatMap { store.item(withID: $0) } }.first { $0.fields.title == title }
        }
        func reminder(_ title: String) -> Reminder? { reminders.first { $0.title == title } }
        func appleID(_ title: String) -> String? {
            reminder(title).flatMap { r in links.first { $0.reminderID == r.id }?.appleID }
        }

        let now = Date()
        let in3h = minute(now.addingTimeInterval(3 * 3_600))
        let tomorrow9 = cal.date(bySettingHour: 9, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!)!
        let deadline = cal.date(bySettingHour: 23, minute: 59, second: 59, of: cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: now))!)!
        let siteURL = "https://canvas.tongji.edu.cn/courses/1/assignments/2"

        // 1. Everything is written to Reminders.
        reminders = [
            Reminder(title: "自检-睡觉", due: in3h, hasExplicitTime: true, createdAt: now),
            Reminder(title: "自检-交材料", due: tomorrow9, hasExplicitTime: false, createdAt: now),
            Reminder(title: "自检-买牛奶", due: nil, createdAt: now),
            Reminder(title: "自检-网站作业", due: deadline, hasExplicitTime: true, isDeadline: true, source: .canvas, watcherID: "selftest",
                     externalKey: "canvas:assignment:selftest", course: "自检课程", url: siteURL, createdAt: now)
        ]
        let first = await sync("first sync")
        check(first.created == 4 && first.failures.isEmpty, "four reminders are written to Reminders", first.text)
        let bed = await appleItem("自检-睡觉")
        check(bed != nil && bed?.fields.hasTime == true && bed?.fields.due == in3h, "a timed reminder keeps its time", "\(fmt(bed?.fields.due)) vs \(fmt(in3h))")
        check(bed?.alarmDates.contains { minute($0) == in3h } == true, "…and has an alarm at that time", bed?.alarmDates.map(fmt).joined(separator: ",") ?? "nil")
        check(bed?.listID == list.id, "…in the temporary list only")
        check((bed?.externalID ?? "").isEmpty == false, "…with a server identifier", bed?.externalID ?? "nil")
        let material = await appleItem("自检-交材料")
        check(material != nil && material?.fields.hasTime == false && material?.fields.due == cal.startOfDay(for: tomorrow9),
              "a plain date stays a plain date", "\(fmt(material?.fields.due)) hasTime=\(String(describing: material?.fields.hasTime))")
        check(material?.alarmDates.isEmpty == true, "…without an alarm")
        let milk = await appleItem("自检-买牛奶")
        check(milk != nil && milk?.fields.due == nil, "an undated reminder stays undated")
        let site = await appleItem("自检-网站作业")
        check(site?.fields.due == minute(deadline), "a website deadline is written to the minute", "\(fmt(site?.fields.due)) vs \(fmt(minute(deadline)))")
        check(site?.notes?.contains("自检课程") == true && site?.notes?.contains("Canvas") == true, "…with a note naming course and site", site?.notes ?? "nil")
        check(site?.url == siteURL, "…and the link to the assignment", site?.url ?? "nil")
        check(site?.alarmDates.contains { minute($0) == minute(deadline) } == true, "…and an alarm at the deadline")
        if let id = bed?.id {
            check(store.item(withID: id)?.fields.title == "自检-睡觉", "a reminder can be found again by its identifier")
            check(bed?.externalID.map { store.items(withExternalID: $0).contains { $0.id == id } } == true, "…and by its server identifier")
        }

        // 2. Nothing changed: nothing is written.
        let quiet = await sync("second sync")
        check(!quiet.changedAnything && quiet.failures.isEmpty, "a sync with no changes does nothing", quiet.text)

        // 3. Edits made on the Reminders side come over.
        if let id = appleID("自检-睡觉") {
            var change = AppleChange()
            change.title = "自检-睡觉(改)"
            change.due = .set(in3h.addingTimeInterval(3_600), hasTime: true)
            change.removeAlarms = [in3h]
            change.addAlarm = in3h.addingTimeInterval(3_600)
            _ = try? store.update(id: id, change)
        }
        if let id = appleID("自检-买牛奶") {
            var change = AppleChange(); change.completed = true
            _ = try? store.update(id: id, change)
        }
        if let id = appleID("自检-网站作业") {
            var change = AppleChange(); change.completed = true
            _ = try? store.update(id: id, change)
        }
        let siri = try? store.create(AppleNewItem(fields: AppleFields(title: "自检-Siri", due: in3h.addingTimeInterval(7_200), hasTime: true,
                                                                    completed: false, calendar: cal)), inList: list.id)
        check(siri != nil, "a reminder can be added the way Reminders would")
        let pulled = await sync("after edits in Reminders")
        check(pulled.failures.isEmpty, "that sync has no failures", pulled.text)
        check(reminder("自检-睡觉(改)") != nil, "a new title in Reminders comes over")
        check(reminder("自检-睡觉(改)")?.due == in3h.addingTimeInterval(3_600), "…with the new time", fmt(reminder("自检-睡觉(改)")?.due))
        check(reminder("自检-买牛奶")?.status == .done, "ticking in Reminders completes it here")
        check(reminder("自检-Siri")?.source == .apple && reminder("自检-Siri")?.due == in3h.addingTimeInterval(7_200), "a reminder made there is imported")
        check(reminder("自检-网站作业")?.status == .pending, "ticking a website copy does not complete the item")
        let quiet2 = await sync("settling")
        check(!quiet2.changedAnything, "and then it is quiet again", quiet2.text)

        // 4. Edits made here go over.
        if let i = reminders.firstIndex(where: { $0.title == "自检-交材料" }) { reminders[i].status = .done; reminders[i].completedAt = Date() }
        let movedDeadline = deadline.addingTimeInterval(86_400)
        if let i = reminders.firstIndex(where: { $0.title == "自检-网站作业" }) { reminders[i].due = movedDeadline }
        reminders.removeAll { $0.title == "自检-Siri" }
        let pushed = await sync("after edits here")
        check(pushed.failures.isEmpty, "that sync has no failures", pushed.text)
        let material2 = links.first { $0.reminderID == reminder("自检-交材料")?.id }?.appleID.flatMap { store.item(withID: $0) }
        check(material2?.fields.completed == true, "completing here ticks it in Reminders")
        let site2 = await appleItem("自检-网站作业")
        check(site2?.fields.due == minute(movedDeadline), "a deadline moved by the website moves the copy", fmt(site2?.fields.due))
        check(site2?.fields.completed == true, "a tick the user made on a website copy stays (only the website can change that)")
        check(site2?.alarmDates.isEmpty == true, "…and a ticked copy has no alarm", site2?.alarmDates.map(fmt).joined(separator: ",") ?? "nil")
        check(await appleItem("自检-Siri") == nil, "deleting here deletes in Reminders")

        // 5. Deletions made in Reminders come over.
        if let id = appleID("自检-睡觉(改)") { try? store.remove(id: id) }
        if let id = appleID("自检-网站作业") { try? store.remove(id: id) }
        let deleted = await sync("after deletions in Reminders")
        check(reminder("自检-睡觉(改)") == nil, "deleting in Reminders deletes here")
        check(reminder("自检-网站作业") != nil, "deleting a website copy keeps the item")
        let quiet3 = await sync("settling")
        check(!quiet3.changedAnything && deleted.failures.isEmpty, "…and the copy is not made again", quiet3.text)

        // 6. Ignoring takes the copy away, restoring brings it back.
        reminders.append(Reminder(title: "自检-网站作业2", due: deadline, hasExplicitTime: true, isDeadline: true, source: .ketangpai,
                                  watcherID: "selftest2", externalKey: "ketangpai:4:selftest", course: "自检课程", createdAt: now))
        await sync("second website item")
        check(await appleItem("自检-网站作业2") != nil, "a second website item is copied")
        let moved2 = deadline.addingTimeInterval(86_400)
        if let i = reminders.firstIndex(where: { $0.title == "自检-网站作业2" }) { reminders[i].due = moved2 }
        await sync("second item's deadline moved")
        let copy2 = await appleItem("自检-网站作业2")
        check(copy2?.fields.due == minute(moved2), "a deadline moved by the website moves an open copy", fmt(copy2?.fields.due))
        check(copy2?.alarmDates.count == 1 && copy2?.alarmDates.first.map(minute) == minute(moved2), "…and its alarm moves with it", copy2?.alarmDates.map(fmt).joined(separator: ",") ?? "nil")
        if let i = reminders.firstIndex(where: { $0.title == "自检-网站作业2" }) { reminders[i].ignored = true }
        await sync("after ignoring")
        check(await appleItem("自检-网站作业2") == nil, "ignoring removes its copy")
        if let i = reminders.firstIndex(where: { $0.title == "自检-网站作业2" }) { reminders[i].ignored = false }
        await sync("after restoring")
        check(await appleItem("自检-网站作业2") != nil, "restoring copies it again")
    }
}

/// `RemindBar --apple-status <outfile>`: a read-only look at what Reminders holds, to see what the link did. It never asks
/// for permission and never writes. Only list names and counts are printed, plus the contents of the app's own list.
@MainActor
enum AppleStatusProbe {
    static func run(outputPath: String) async {
        var lines: [String] = []
        let cal = Calendar.reminder
        let store = EventKitStore(calendar: cal)
        lines.append("authorisation: \(store.access())")
        if store.access() == .full {
            let defaultID = store.defaultListID()
            let now = Date()
            func fmt(_ d: Date?, timed: Bool) -> String {
                guard let d else { return "no date" }
                let f = DateFormatter()
                f.calendar = cal
                f.timeZone = cal.timeZone
                f.dateFormat = timed ? "MM-dd HH:mm" : "MM-dd"
                return f.string(from: d)
            }
            for list in store.lists() {
                let items = (try? await store.fetchIncomplete(listIDs: [list.id])) ?? []
                let overdue = items.filter { ($0.fields.due ?? .distantFuture) < now }.count
                lines.append("list 「\(list.title)」 [\(list.account)]\(list.id == defaultID ? " (default)" : ""): \(items.count) open, \(overdue) overdue")
                if list.title == "提醒条" {
                    for item in items.sorted(by: { ($0.fields.due ?? .distantFuture) < ($1.fields.due ?? .distantFuture) }) {
                        let note = item.notes.map { String($0.split(separator: "\n").first ?? "").prefix(24) } ?? ""
                        lines.append("    - \(item.fields.title) | \(fmt(item.fields.due, timed: item.fields.hasTime)) | alarms \(item.alarmDates.count) | url \(item.url == nil ? "no" : "yes") | \(note)")
                    }
                }
            }
        }
        try? lines.joined(separator: "\n").write(toFile: outputPath, atomically: true, encoding: .utf8)
    }
}
