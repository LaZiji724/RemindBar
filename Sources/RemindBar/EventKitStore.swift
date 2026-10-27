import Foundation
@preconcurrency import EventKit
import RemindCore

/// Apple's Reminders database through EventKit. Everything the merge logic needs goes through `AppleReminderStore`, so
/// nothing else in the app knows about EventKit.
@MainActor
final class EventKitStore: AppleReminderStore {
    private let store = EKEventStore()
    private let calendar: Calendar
    private var observer: NSObjectProtocol?
    var onChange: (() -> Void)?

    init(calendar: Calendar = .reminder) {
        self.calendar = calendar
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onChange?() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: access

    func access() -> AppleAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .full
        case .writeOnly: return .writeOnly
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }

    func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToReminders()
        } catch {
            return false
        }
    }

    // MARK: lists

    func lists() -> [AppleList] {
        store.calendars(for: .reminder).map(Self.list)
    }

    func defaultListID() -> String? {
        store.defaultCalendarForNewReminders()?.calendarIdentifier
    }

    private static func list(_ c: EKCalendar) -> AppleList {
        AppleList(id: c.calendarIdentifier, title: c.title, account: c.source?.title ?? "", writable: c.allowsContentModifications)
    }

    func createList(title: String) throws -> AppleList {
        let list = EKCalendar(for: .reminder, eventStore: store)
        list.title = title
        // The account the user's own default list lives in (iCloud, usually), else any local one.
        guard let source = store.defaultCalendarForNewReminders()?.source
                ?? store.sources.first(where: { $0.sourceType == .local })
                ?? store.sources.first(where: { $0.sourceType == .calDAV }) else {
            throw AppleStoreError.failed("找不到可以新建列表的提醒事项账户")
        }
        list.source = source
        try store.saveCalendar(list, commit: true)
        return Self.list(list)
    }

    /// Developer self-check only: removes a list this app made.
    func removeList(id: String) throws {
        guard let list = store.calendar(withIdentifier: id) else { return }
        try store.removeCalendar(list, commit: true)
    }

    // MARK: reading

    func fetchIncomplete(listIDs: [String]) async throws -> [AppleItem] {
        guard access() == .full else { throw AppleStoreError.noAccess }
        let calendars = listIDs.compactMap { store.calendar(withIdentifier: $0) }
        guard !calendars.isEmpty else { return [] }
        store.refreshSourcesIfNecessary()
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
        let cal = calendar
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[AppleItem], Error>) in
            let gate = OnceGate()
            _ = store.fetchReminders(matching: predicate) { reminders in
                // Runs on a background queue: only plain values leave this closure.
                let items = (reminders ?? []).map { Self.convert($0, calendar: cal) }
                if gate.fire() { continuation.resume(returning: items) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                if gate.fire() { continuation.resume(throwing: AppleStoreError.failed("读取提醒事项超时")) }
            }
        }
    }

    func item(withID id: String) -> AppleItem? {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return nil }
        return Self.convert(reminder, calendar: calendar)
    }

    func items(withExternalID id: String) -> [AppleItem] {
        store.calendarItems(withExternalIdentifier: id).compactMap { $0 as? EKReminder }.map { Self.convert($0, calendar: calendar) }
    }

    nonisolated static func convert(_ r: EKReminder, calendar: Calendar) -> AppleItem {
        var due: Date?
        var hasTime = false
        if let parts = r.dueDateComponents {
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = parts.timeZone ?? calendar.timeZone
            var plain = parts
            plain.calendar = nil
            plain.timeZone = gregorian.timeZone
            hasTime = parts.hour != nil
            due = gregorian.date(from: plain)
        }
        let fields = AppleFields(title: r.title ?? "", due: due, hasTime: hasTime, completed: r.isCompleted, calendar: calendar)
        return AppleItem(id: r.calendarItemIdentifier, externalID: r.calendarItemExternalIdentifier, listID: r.calendar?.calendarIdentifier ?? "",
                         fields: fields, completedAt: r.completionDate, hasRecurrence: r.hasRecurrenceRules,
                         alarmDates: (r.alarms ?? []).compactMap(\.absoluteDate),
                         alarmOffsets: (r.alarms ?? []).filter { $0.absoluteDate == nil && $0.structuredLocation == nil }.map(\.relativeOffset),
                         notes: r.notes, url: r.url?.absoluteString,
                         modifiedAt: r.lastModifiedDate)
    }

    // MARK: writing

    func create(_ new: AppleNewItem, inList listID: String) throws -> AppleItem {
        guard access() == .full else { throw AppleStoreError.noAccess }
        guard let list = store.calendar(withIdentifier: listID) else { throw AppleStoreError.listMissing }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        reminder.title = new.fields.title
        reminder.dueDateComponents = new.fields.due.map { components(for: $0, hasTime: new.fields.hasTime) }
        if let notes = new.notes { reminder.notes = notes }
        if let link = new.url, let url = URL(string: link) { reminder.url = url }
        for alarm in new.alarms { reminder.addAlarm(EKAlarm(absoluteDate: alarm)) }
        try store.save(reminder, commit: true)
        return Self.convert(reminder, calendar: calendar)
    }

    func update(id: String, _ change: AppleChange) throws -> AppleItem {
        guard access() == .full else { throw AppleStoreError.noAccess }
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { throw AppleStoreError.notFound(id) }
        if let title = change.title { reminder.title = title }
        switch change.due {
        case .set(let date, let hasTime)?: reminder.dueDateComponents = components(for: date, hasTime: hasTime)
        case .clear?: reminder.dueDateComponents = nil
        case nil: break
        }
        if let done = change.completed { reminder.isCompleted = done }
        for old in change.removeAlarms {
            for alarm in reminder.alarms ?? [] {
                if let at = alarm.absoluteDate, Int(at.timeIntervalSince1970 / 60) == Int(old.timeIntervalSince1970 / 60) {
                    reminder.removeAlarm(alarm)
                }
            }
        }
        for old in change.removeAlarmOffsets {
            for alarm in reminder.alarms ?? [] where alarm.absoluteDate == nil && alarm.structuredLocation == nil
                && abs(alarm.relativeOffset - old) < 1 {
                reminder.removeAlarm(alarm)
            }
        }
        for alarm in change.addAlarms { reminder.addAlarm(EKAlarm(absoluteDate: alarm)) }
        for offset in change.addAlarmOffsets { reminder.addAlarm(EKAlarm(relativeOffset: offset)) }
        try store.save(reminder, commit: true)
        return Self.convert(reminder, calendar: calendar)
    }

    func remove(id: String) throws {
        guard access() == .full else { throw AppleStoreError.noAccess }
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        try store.remove(reminder, commit: true)
    }

    /// A deadline with a time is pinned to the app's time zone; a plain date floats (it is "that day", wherever you are).
    private func components(for date: Date, hasTime: Bool) -> DateComponents {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        var parts = gregorian.dateComponents(hasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: date)
        parts.calendar = Calendar(identifier: .gregorian)
        parts.timeZone = hasTime ? calendar.timeZone : nil
        return parts
    }
}

/// Lets exactly one of two racing callbacks (the fetch finishing, the time-out) resume a continuation.
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if fired { return false }
        fired = true
        return true
    }
}
