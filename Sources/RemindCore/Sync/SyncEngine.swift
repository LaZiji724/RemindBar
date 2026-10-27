import Foundation

public struct SyncChange: Equatable, Sendable {
    public var reminder: Reminder
    public var oldDue: Date?
}

public struct SyncResult: Equatable, Sendable {
    public var reminders: [Reminder]
    public var added: [Reminder] = []
    public var changedDue: [SyncChange] = []
    /// Finished on the site (submitted, ticked off, or gone from its to-do list) since the last sync.
    public var autoCompleted: [Reminder] = []
    /// Done here before, but the site lists them as open again.
    public var reopened: [Reminder] = []
    /// Not listed any more because they are too old for the window the site is asked about (nobody can act on them).
    public var retired: [Reminder] = []
    /// Tracked items the site no longer lists (left untouched; reported for diagnostics).
    public var missing: [Reminder] = []

    public var hasChanges: Bool {
        !added.isEmpty || !changedDue.isEmpty || !autoCompleted.isEmpty || !reopened.isEmpty || !retired.isEmpty
    }
}

/// Merges what a site reports into the reminder list.
///
/// For sites whose completion state we can read (Canvas, 课堂派) the site is the single source of truth: there is no manual
/// "done" and no delete for those items, a sync completes what the site shows as finished and reopens what it shows as
/// open again. For generic pages the site cannot say, so a completion the user made by hand stands, and an item the user
/// deleted by hand is never recreated.
public enum SyncEngine {
    /// - Parameter completeMissing: for sites whose list holds only OPEN items (课堂派 to-do): an item that vanished from the
    ///   list has been submitted, ignored, removed or has ended, so its reminder is completed.
    /// - Parameter retireBefore: for sites that list only a window of time (Canvas planner: two weeks back): an item that
    ///   is absent and was due before this moment has merely aged out of the window, so its reminder is retired. Items
    ///   absent but still inside the window are left alone, because a short or failed read must never drop a deadline.
    public static func reconcile(existing: [Reminder], remote: [RemoteItem], watcher: WatcherConfig, now: Date,
                                 completeMissing: Bool = false, retireBefore: Date? = nil) -> SyncResult {
        var list = existing
        var result = SyncResult(reminders: existing)
        var index: [String: Int] = [:]
        for (i, r) in list.enumerated() where r.watcherID == watcher.id {
            if let key = r.externalKey { index[key] = i }
        }
        var reported = Set<String>()
        let followsSite = watcher.kind.completionFollowsSite
        // A hand-deleted item stays gone only on generic pages. For Canvas / 课堂派 the site decides, so nothing the
        // site still lists as open can be hidden for good (that would silently drop a deadline).
        let tombstones = followsSite ? Set<String>() : Set(watcher.deletedKeys)

        for item in remote {
            reported.insert(item.key)
            if let i = index[item.key] {
                var r = list[i]
                let before = r

                if item.completed {
                    if r.status == .pending {
                        r.status = .done
                        r.completedAt = now
                        r.snoozedUntil = nil
                        r.ignored = false
                        list[i] = r
                        result.autoCompleted.append(r)
                    }
                    continue
                }

                // The site lists it as open.
                var reopened = false
                if r.status == .done {
                    guard followsSite else { continue } // a generic page cannot tell: the user's own tick stands
                    r.status = .pending
                    r.completedAt = nil
                    r.ignored = false
                    reopened = true
                }
                if r.title != item.title { r.title = item.title }
                if r.course != item.course { r.course = item.course }
                if r.url != item.url { r.url = item.url }
                var oldDue: Date?
                if let newDue = item.due, abs((r.due ?? .distantPast).timeIntervalSince(newDue)) > 60 {
                    oldDue = r.due
                    r.due = newDue
                    r.snoozedUntil = nil
                    if !reopened { result.changedDue.append(SyncChange(reminder: r, oldDue: oldDue)) }
                }
                if r != before { list[i] = r }
                if reopened { result.reopened.append(r) }
            } else if !item.completed, !tombstones.contains(item.key), let due = item.due {
                let r = Reminder(title: item.title, due: due, hasExplicitTime: true, isDeadline: true,
                                 source: watcher.kind, watcherID: watcher.id, externalKey: item.key,
                                 course: item.course, url: item.url, createdAt: now)
                list.append(r)
                result.added.append(r)
            }
        }

        for (key, i) in index.sorted(by: { $0.value < $1.value }) where !reported.contains(key) && list[i].status == .pending {
            if completeMissing {
                list[i].status = .done
                list[i].completedAt = now
                list[i].snoozedUntil = nil
                list[i].ignored = false
                result.autoCompleted.append(list[i])
            } else if let cutoff = retireBefore, let due = list[i].due, due < cutoff {
                list[i].status = .done
                list[i].completedAt = now
                list[i].snoozedUntil = nil
                list[i].ignored = false
                result.retired.append(list[i])
            } else {
                result.missing.append(list[i])
            }
        }
        result.reminders = list
        return result
    }
}
