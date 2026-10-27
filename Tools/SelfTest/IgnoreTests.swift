import Foundation
import RemindCore

/// "Ignore": a website item the user no longer wants to be reminded about. It stays tracked, so the website still decides
/// when it is done, but nothing alerts and nothing counts it.
enum IgnoreTests {
    static func run(_ h: Harness) {
        h.suite = "ignore"
        let now = Fixture.now
        let watcher = WatcherConfig(id: "w-canvas", kind: .canvas, name: "同济 Canvas", url: "https://canvas.tongji.edu.cn/")
        func site(_ key: String, _ title: String, due: String) -> Reminder {
            Reminder(title: title, due: Fixture.date(due), hasExplicitTime: true, isDeadline: true, source: .canvas,
                     watcherID: watcher.id, externalKey: key, createdAt: now)
        }
        func remote(_ r: Reminder, completed: Bool = false, due: String? = nil) -> RemoteItem {
            RemoteItem(key: r.externalKey ?? "", title: r.title, course: nil, due: due.map(Fixture.date) ?? r.due, url: nil, completed: completed)
        }

        // No alerts at all while ignored; they come back when restored.
        var item = site("canvas:assignment:1", "第六周作业", due: "2026-10-28 23:59")
        h.equal(FirePlanner.fires(for: item, after: now).count, LeadTimes.standard.count, "an ordinary deadline has all its alerts")
        item.ignored = true
        h.equal(FirePlanner.fires(for: item, after: now).count, 0, "an ignored item has no alerts")
        h.equal(FirePlanner.missed([item], from: now, to: Fixture.date("2026-10-29 00:00")).count, 0, "…and none are caught up later")
        h.equal(FirePlanner.plan([item], after: now).count, 0, "…and none are scheduled with the system")
        item.ignored = false
        h.equal(FirePlanner.fires(for: item, after: now).count, LeadTimes.standard.count, "restoring brings the alerts back")

        // Storage: optional on disk, so old files decode and a normal item adds nothing.
        let plain = try? JSONEncoder().encode(item)
        h.check(plain.map { !String(decoding: $0, as: UTF8.self).contains("ignoredFlag") } ?? false, "a normal item stores no ignore flag")
        item.ignored = true
        if let data = try? JSONEncoder().encode(item), let back = try? JSONDecoder().decode(Reminder.self, from: data) {
            h.equal(back.ignored, true, "the flag survives saving and loading")
            h.equal(back, item, "…without changing anything else")
        } else {
            h.check(false, "an ignored item can be encoded and decoded")
        }
        var oldJSON = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(site("canvas:assignment:2", "旧数据", due: "2026-10-30 23:59")))) as? [String: Any] ?? [:]
        oldJSON.removeValue(forKey: "ignoredFlag")
        if let data = try? JSONSerialization.data(withJSONObject: oldJSON), let old = try? JSONDecoder().decode(Reminder.self, from: data) {
            h.equal(old.ignored, false, "a state file from before this feature decodes, not ignored")
        } else {
            h.check(false, "an old state file still decodes")
        }

        // Syncing keeps the flag while nothing happened on the website …
        var a = site("canvas:assignment:1", "第六周作业", due: "2026-10-28 23:59")
        a.ignored = true
        let quiet = SyncEngine.reconcile(existing: [a], remote: [remote(a)], watcher: watcher, now: now)
        h.equal(quiet.reminders.first?.ignored, true, "a read that changes nothing keeps the item ignored")
        h.equal(quiet.hasChanges, false, "…and reports no change")
        let moved = SyncEngine.reconcile(existing: [a], remote: [remote(a, due: "2026-10-30 23:59")], watcher: watcher, now: now)
        h.equal(moved.reminders.first?.ignored, true, "a moved deadline does not undo the ignoring")
        h.equal(Fixture.format(moved.reminders.first?.due), "2026-10-30 23:59", "…but the new deadline is still tracked")

        // … and ends it when the website says it is finished, reopens it, or stops listing it.
        let finished = SyncEngine.reconcile(existing: [a], remote: [remote(a, completed: true)], watcher: watcher, now: now)
        h.equal(finished.reminders.first?.status, .done, "the website finishing an ignored item completes it")
        h.equal(finished.reminders.first?.ignored, false, "…and the flag is cleared")
        let reopened = SyncEngine.reconcile(existing: finished.reminders, remote: [remote(a)], watcher: watcher, now: now)
        h.equal(reopened.reminders.first?.status, .pending, "an item the website lists as open again is pending")
        h.equal(reopened.reminders.first?.ignored, false, "…and it is no longer ignored, so alerts resume")
        let gone = SyncEngine.reconcile(existing: [a], remote: [], watcher: watcher, now: now, completeMissing: true)
        h.equal(gone.reminders.first?.status, .done, "an ignored item that left the website's list is completed")
        h.equal(gone.reminders.first?.ignored, false, "…and its flag is cleared")
        var old = site("canvas:assignment:3", "很久以前", due: "2026-10-05 23:59")
        old.ignored = true
        let aged = SyncEngine.reconcile(existing: [old], remote: [], watcher: watcher, now: now, retireBefore: Fixture.date("2026-10-11 21:05"))
        h.equal(aged.reminders.first?.status, .done, "an ignored item that aged out of the window is retired")
        h.equal(aged.reminders.first?.ignored, false, "…and its flag is cleared")
    }
}
