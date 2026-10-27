import Foundation

/// Two-way merge between this app's reminders and Apple's Reminders app.
///
/// Every linked pair remembers the values both sides agreed on (`AppleLink.synced`). A sync compares each field of the pair
/// with that base: a change on one side is carried to the other, a change on both sides is settled by who owns the data.
/// Reminders from Canvas / 课堂派 are mirrored one way: the website owns them, so edits or ticks made on the Apple copy
/// never reach the app (the app still decides when they are done).
///
/// `merge` is synchronous on purpose: it runs right after the one asynchronous fetch, so nothing can change the reminder
/// list in between and the result can simply replace it.
@MainActor
public enum AppleSyncEngine {
    /// The default list is brought along when the link is first switched on only if it has at most this many open reminders.
    public static let defaultImportLimit = 30

    public struct Options {
        public var managedListID: String
        public var importListIDs: [String]
        public var includeWebsiteItems: Bool
        public var alarms: Bool
        public var now: Date
        public var calendar: Calendar
        public var defaultHour: Int
        public var defaultMinute: Int
        /// At most this many new reminders are imported in one run.
        public var maxImport: Int

        public init(managedListID: String, importListIDs: [String] = [], includeWebsiteItems: Bool = true, alarms: Bool = true,
                    now: Date, calendar: Calendar, defaultHour: Int = 9, defaultMinute: Int = 0, maxImport: Int = 200) {
            self.managedListID = managedListID
            self.importListIDs = importListIDs
            self.includeWebsiteItems = includeWebsiteItems
            self.alarms = alarms
            self.now = now
            self.calendar = calendar
            self.defaultHour = defaultHour
            self.defaultMinute = defaultMinute
            self.maxImport = maxImport
        }

        var syncedListIDs: Set<String> { Set([managedListID] + importListIDs) }
    }

    public struct Report: Equatable, Sendable {
        /// New reminders written to Apple's Reminders.
        public var created = 0
        /// Existing Apple reminders changed.
        public var updatedApple = 0
        /// Apple reminders removed (deleted here, ignored here, or website items switched off).
        public var removedApple = 0
        /// New reminders taken from Apple's Reminders.
        public var imported = 0
        /// Existing reminders changed here because they changed there.
        public var updatedLocal = 0
        /// Reminders deleted here because they were deleted there.
        public var removedLocal = 0
        public var relinked = 0
        /// Pairs that stopped being synced (the Apple copy was removed or moved away).
        public var optedOut = 0
        public var skippedRecurring = 0
        public var warnings: [String] = []
        public var failures: [String] = []

        public init() {}

        public var changedAnything: Bool {
            created + updatedApple + removedApple + imported + updatedLocal + removedLocal + relinked > 0
        }

        public var text: String {
            var parts: [String] = []
            if created > 0 { parts.append("写入提醒事项 \(created) 项") }
            if updatedApple > 0 { parts.append("更新提醒事项里 \(updatedApple) 项") }
            if removedApple > 0 { parts.append("从提醒事项移除 \(removedApple) 项") }
            if imported > 0 { parts.append("从提醒事项导入 \(imported) 项") }
            if updatedLocal > 0 { parts.append("按提醒事项更新 \(updatedLocal) 项") }
            if removedLocal > 0 { parts.append("提醒事项里删掉的 \(removedLocal) 项已同步删除") }
            if optedOut > 0 { parts.append("\(optedOut) 项不再同步") }
            var text = parts.isEmpty ? "已是最新" : parts.joined(separator: "，")
            if !failures.isEmpty { text += "；\(failures.count) 项失败" }
            return text
        }
    }

    public struct Result {
        public var reminders: [Reminder]
        public var links: [AppleLink]
        public var report: Report
    }

    // MARK: merge

    public static func merge(reminders: [Reminder], links: [AppleLink], fetched: [AppleItem],
                             store: AppleReminderStore, options o: Options) -> Result {
        let cal = o.calendar
        var list = reminders
        var report = Report()
        var kept: [AppleLink] = []
        var index: [UUID: Int] = [:]
        for (i, r) in list.enumerated() { index[r.id] = i }

        let syncedLists = o.syncedListIDs
        var fetchedByID: [String: AppleItem] = [:]
        var externalCount: [String: Int] = [:]
        for item in fetched {
            fetchedByID[item.id] = item
            if let e = item.externalID { externalCount[e, default: 0] += 1 }
        }
        // An external identifier is only trusted when exactly one fetched item carries it.
        var fetchedByExternal: [String: AppleItem] = [:]
        for item in fetched {
            if let e = item.externalID, externalCount[e] == 1 { fetchedByExternal[e] = item }
        }

        var claimed = Set<String>()
        var handled = Set<UUID>()
        var localDeletes: [UUID] = []
        var appleDeletes: [AppleLink] = []

        // 1. Every pair we already know.
        for var link in links {
            guard let i = index[link.reminderID] else {
                // The reminder is gone here: the Apple copy goes too (after the safety check below).
                if !link.optOut, link.appleID != nil { appleDeletes.append(link) }
                continue
            }
            handled.insert(link.reminderID)
            var r = list[i]
            if link.optOut { kept.append(link); continue }
            guard let appleID = link.appleID else { handled.remove(link.reminderID); continue }

            // Find the Apple side: still incomplete in a synced list, or completed / moved / re-numbered.
            var found = fetchedByID[appleID]
            if found == nil, let e = link.externalID, let hit = fetchedByExternal[e], !claimed.contains(hit.id) { found = hit }
            if found == nil, let hit = store.item(withID: appleID) { found = hit }
            if found == nil, let e = link.externalID {
                let hits = store.items(withExternalID: e).filter { !claimed.contains($0.id) }
                if hits.count == 1 { found = hits[0] }
            }
            guard var apple = found, !claimed.contains(apple.id) else {
                // Gone from Apple's Reminders.
                if r.status == .done {
                    handled.remove(r.id) // finished anyway: just forget the pair
                } else if r.completionFollowsSite {
                    // The website still tracks it; only the Apple copy is gone, and it stays gone.
                    link.optOut = true
                    link.appleID = nil; link.externalID = nil; link.listID = nil; link.synced = nil
                    kept.append(link)
                    report.optedOut += 1
                } else {
                    handled.remove(r.id)
                    localDeletes.append(r.id)
                }
                continue
            }
            if !syncedLists.contains(apple.listID) || apple.hasRecurrence {
                // Moved to a list we do not sync, or turned into a repeating reminder (not supported here).
                link.optOut = true
                link.appleID = nil; link.externalID = nil; link.listID = nil; link.synced = nil
                kept.append(link)
                if apple.hasRecurrence { report.skippedRecurring += 1 } else { report.optedOut += 1 }
                continue
            }
            claimed.insert(apple.id)

            if !isExportable(r, o) {
                // Ignored here, or website items switched off: the Apple copy goes away.
                do {
                    try store.remove(id: apple.id)
                    report.removedApple += 1
                } catch {
                    report.failures.append("移除「\(r.title)」失败：\(error.localizedDescription)")
                    link.listID = apple.listID
                    kept.append(link)
                }
                continue
            }

            let site = r.completionFollowsSite
            let local = fields(of: r, cal)
            let base = link.synced ?? apple.fields
            var newSynced = base
            var change = AppleChange()
            var changedLocal = false
            var pushedTitle = false, pushedDue = false, pushedDone = false

            switch decide(local.title, apple.fields.title, base.title, pullAllowed: !site) {
            case .agree: newSynced.title = local.title
            case .push: change.title = local.title; newSynced.title = local.title; pushedTitle = true
            case .pull:
                if !apple.fields.title.isEmpty {
                    r.title = apple.fields.title; newSynced.title = apple.fields.title; changedLocal = true
                }
            case .keep: break
            }

            var finalDue = apple.fields.dueSpec
            switch decide(local.dueSpec, apple.fields.dueSpec, base.dueSpec, pullAllowed: !site) {
            case .agree:
                newSynced.due = local.due; newSynced.hasTime = local.hasTime
            case .push:
                if let due = local.due { change.due = .set(due, hasTime: local.hasTime) } else { change.due = .clear }
                newSynced.due = local.due; newSynced.hasTime = local.hasTime
                pushedDue = true
                finalDue = local.dueSpec
            case .pull:
                r.due = localDate(for: apple.fields, o)
                r.hasExplicitTime = apple.fields.hasTime
                r.snoozedUntil = nil
                newSynced.due = apple.fields.due; newSynced.hasTime = apple.fields.hasTime
                changedLocal = true
            case .keep: break
            }

            switch decide(local.completed, apple.fields.completed, base.completed, pullAllowed: !site) {
            case .agree: newSynced.completed = local.completed
            case .push: change.completed = local.completed; newSynced.completed = local.completed; pushedDone = true
            case .pull:
                if apple.fields.completed {
                    r.status = .done
                    r.completedAt = apple.completedAt ?? o.now
                    r.snoozedUntil = nil
                } else {
                    r.status = .pending
                    r.completedAt = nil
                }
                newSynced.completed = apple.fields.completed
                changedLocal = true
            case .keep: break
            }

            // Copies this app made carry the same alarms as the app itself (when switched on), so the iPhone rings ahead of the
            // deadline and at it. The alarms follow the deadline only while both sides agree on it; a deadline edited on a
            // website copy is left alone.
            if link.origin == .app, finalDue == DueSpec(date: newSynced.due, hasTime: newSynced.hasTime) {
                let completedAfter = change.completed ?? apple.fields.completed
                // Every moment the schedule gives for the deadline; the ones that have gone by are left as they are.
                var wanted: [Date] = []
                if o.alarms, finalDue.hasTime, !completedAfter, let d = finalDue.date { wanted = alarmMoments(due: d, leads: r.leadTimes) }
                // Alarms of an earlier deadline, and the alarms of a deadline that no longer needs any, are taken away.
                var outdated: [Date] = []
                for spec in [base.dueSpec, apple.fields.dueSpec, finalDue] where spec.hasTime {
                    guard let d = spec.date else { continue }
                    for moment in alarmMoments(due: d, leads: r.leadTimes) {
                        guard !wanted.contains(where: { sameMinute($0, moment) }),
                              !outdated.contains(where: { sameMinute($0, moment) }),
                              apple.alarmDates.contains(where: { sameMinute($0, moment) }) else { continue }
                        outdated.append(moment)
                    }
                }
                change.removeAlarms.append(contentsOf: outdated)
                change.addAlarms = wanted.filter { moment in
                    moment > o.now && !apple.alarmDates.contains(where: { sameMinute($0, moment) })
                }
            }

            if !change.isEmpty {
                do {
                    apple = try store.update(id: apple.id, change)
                    report.updatedApple += 1
                } catch {
                    report.failures.append("更新「\(r.title)」失败：\(error.localizedDescription)")
                    // Leave the base as it was for what could not be pushed, so the next sync tries again.
                    if pushedTitle { newSynced.title = base.title }
                    if pushedDue { newSynced.due = base.due; newSynced.hasTime = base.hasTime }
                    if pushedDone { newSynced.completed = base.completed }
                }
            }

            link.appleID = apple.id
            link.externalID = apple.externalID ?? link.externalID
            link.listID = apple.listID
            link.synced = newSynced
            kept.append(link)
            if changedLocal {
                list[i] = r
                report.updatedLocal += 1
            }
        }

        // 2. Deletions that were only inferred ("it is not there any more") need a sanity check: a store that came back
        //    empty or a reset state must never wipe either side.
        let inferred = localDeletes.count + appleDeletes.count
        if inferred > max(3, links.count / 2) {
            report.warnings.append("两边有 \(inferred) 项对不上，已暂停删除以防误删：本机和提醒事项里的内容都原样保留，并会互相补齐")
        } else {
            if !localDeletes.isEmpty {
                let doomed = Set(localDeletes)
                list.removeAll { doomed.contains($0.id) }
                report.removedLocal += doomed.count
            }
            for link in appleDeletes {
                guard let id = link.appleID else { continue }
                claimed.insert(id) // what was fetched earlier must not be imported back
                do {
                    try store.remove(id: id)
                    report.removedApple += 1
                } catch {
                    report.failures.append("删除提醒事项里的一项失败：\(error.localizedDescription)")
                    kept.append(link) // try again next time
                }
            }
        }

        // 3. Reminders without a twin go to the managed list.
        var unlinked = fetched.filter { !claimed.contains($0.id) && syncedLists.contains($0.listID) && !$0.hasRecurrence }
        let candidates = list.filter { !handled.contains($0.id) && $0.status == .pending && isExportable($0, o) }
        // The same item may already be in the managed list (e.g. after a reset): pair them up instead of duplicating, but
        // only when the pairing is unambiguous on both sides.
        func signature(_ f: AppleFields) -> String {
            "\(f.title)|\(f.due.map { String(Int($0.timeIntervalSince1970)) } ?? "-")|\(f.hasTime)"
        }
        var localSignatures: [String: Int] = [:]
        for r in candidates { localSignatures[signature(fields(of: r, cal)), default: 0] += 1 }
        var appleSignatures: [String: Int] = [:]
        for item in unlinked where item.listID == o.managedListID { appleSignatures[signature(item.fields), default: 0] += 1 }

        for r in candidates.sorted(by: { ($0.due ?? .distantFuture, $0.createdAt) < ($1.due ?? .distantFuture, $1.createdAt) }) {
            let want = fields(of: r, cal)
            let sig = signature(want)
            if localSignatures[sig] == 1, appleSignatures[sig] == 1,
               let twin = unlinked.first(where: { $0.listID == o.managedListID && signature($0.fields) == sig }) {
                claimed.insert(twin.id)
                unlinked.removeAll { $0.id == twin.id }
                kept.append(AppleLink(reminderID: r.id, appleID: twin.id, externalID: twin.externalID, listID: twin.listID,
                                      synced: want, origin: .apple))
                report.relinked += 1
                continue
            }
            var alarms: [Date] = []
            if o.alarms, want.hasTime, let d = want.due { alarms = alarmMoments(due: d, leads: r.leadTimes).filter { $0 > o.now } }
            let new = AppleNewItem(fields: want, notes: notes(for: r), url: r.source == .manual || r.source == .apple ? nil : r.url,
                                   alarms: alarms)
            do {
                let item = try store.create(new, inList: o.managedListID)
                claimed.insert(item.id)
                kept.append(AppleLink(reminderID: r.id, appleID: item.id, externalID: item.externalID, listID: item.listID,
                                      synced: want, origin: .app))
                report.created += 1
            } catch {
                report.failures.append("写入「\(r.title)」失败：\(error.localizedDescription)")
            }
        }

        // 4. Reminders that only exist in Apple's Reminders are imported.
        var imported = 0
        let newcomers = unlinked.filter { !$0.fields.completed && !$0.fields.title.isEmpty }
            .sorted { ($0.fields.due ?? .distantFuture, $0.fields.title) < ($1.fields.due ?? .distantFuture, $1.fields.title) }
        for item in newcomers {
            if imported >= o.maxImport {
                report.warnings.append("提醒事项里还有一些没导入（一次最多导入 \(o.maxImport) 项），下次同步会继续")
                break
            }
            let r = Reminder(title: item.fields.title, due: localDate(for: item.fields, o), hasExplicitTime: item.fields.hasTime,
                             isDeadline: false, source: .apple, createdAt: o.now)
            list.append(r)
            kept.append(AppleLink(reminderID: r.id, appleID: item.id, externalID: item.externalID, listID: item.listID,
                                  synced: item.fields, origin: .apple))
            imported += 1
        }
        report.imported = imported

        // 5. Finished long ago and already in step: nothing left to keep track of.
        let byID = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let cutoff = o.now.addingTimeInterval(-14 * 86_400)
        kept.removeAll { link in
            guard let r = byID[link.reminderID], r.status == .done, link.synced?.completed == true,
                  let at = r.completedAt else { return false }
            return at < cutoff
        }

        return Result(reminders: list, links: kept, report: report)
    }

    // MARK: pieces

    enum Decision { case agree, push, pull, keep }

    /// Three-way decision for one field: `local` and `apple` are today's values, `base` is what they were at the last sync.
    static func decide<T: Equatable>(_ local: T, _ apple: T, _ base: T, pullAllowed: Bool) -> Decision {
        if local == apple { return .agree }
        let localChanged = local != base
        let appleChanged = apple != base
        if localChanged && !appleChanged { return .push }
        if appleChanged && !localChanged { return pullAllowed ? .pull : .keep }
        // Both changed: whoever owns the data wins. For website items that is us; otherwise the Reminders app.
        return pullAllowed ? .pull : .push
    }

    static func isExportable(_ r: Reminder, _ o: Options) -> Bool {
        if r.ignored { return false }
        return o.includeWebsiteItems || r.source == .manual || r.source == .apple
    }

    static func fields(of r: Reminder, _ cal: Calendar) -> AppleFields {
        AppleFields(title: r.title, due: r.due, hasTime: r.due != nil && r.hasExplicitTime, completed: r.status == .done, calendar: cal)
    }

    /// The instant a reminder from Apple's Reminders is due here. A date without a time gets the default time of day.
    static func localDate(for f: AppleFields, _ o: Options) -> Date? {
        guard let due = f.due else { return nil }
        if f.hasTime { return due }
        return o.calendar.date(bySettingHour: o.defaultHour, minute: o.defaultMinute, second: 0, of: due) ?? due
    }

    static func sameMinute(_ a: Date, _ b: Date) -> Bool {
        Int(a.timeIntervalSince1970 / 60) == Int(b.timeIntervalSince1970 / 60)
    }

    /// When the alarms of a copy with this deadline go off: one for each alert of the reminder, from the earliest to the
    /// deadline itself.
    static func alarmMoments(due: Date, leads: [Double]) -> [Date] {
        var moments: [Date] = []
        for lead in Set(leads).sorted(by: >) where lead >= 0 {
            let moment = due.addingTimeInterval(-lead)
            if !moments.contains(where: { sameMinute($0, moment) }) { moments.append(moment) }
        }
        return moments
    }

    /// The note written under the title of a website item's Apple copy.
    static func notes(for r: Reminder) -> String? {
        guard r.source != .manual, r.source != .apple else { return nil }
        var lines = [[r.course, r.source.displayName].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")]
        if r.completionFollowsSite {
            lines.append("是否完成以网站为准：在网站上提交后，提醒条刷新时会自动在这里打勾。")
        }
        return lines.joined(separator: "\n")
    }
}
