import Foundation

/// A stand-in for Apple's Reminders app that lives in memory. It is what the merge logic is tested against, and what the
/// UI smoke test links to. The `user…` methods act like the person editing in the Reminders app: they never count as a write
/// by this app and they notify `onChange` like the real database does.
@MainActor
public final class InMemoryAppleStore: AppleReminderStore {
    public var onChange: (() -> Void)?
    public var accessState: AppleAccess
    /// What the permission dialog answers.
    public var grantsAccess = true
    /// Every create / update / remove by this app throws while set.
    public var failWrites = false
    public private(set) var allLists: [AppleList]
    public private(set) var items: [String: AppleItem] = [:]
    /// Writes that changed something, made by the app (not by `user…`).
    public private(set) var writes = 0

    private let calendar: Calendar
    private let clock: () -> Date
    private var counter = 0

    public init(calendar: Calendar, lists: [AppleList] = [], access: AppleAccess = .full, clock: @escaping () -> Date = Date.init) {
        self.calendar = calendar
        self.allLists = lists
        self.accessState = access
        self.clock = clock
    }

    private func nextNumber() -> Int {
        counter += 1
        return counter
    }

    // MARK: AppleReminderStore

    public func access() -> AppleAccess { accessState }

    /// How often the permission dialog was asked for.
    public private(set) var accessRequests = 0
    /// False: nobody answers the dialog, so the access stays undetermined.
    public var answersRequests = true

    public func requestAccess() async -> Bool {
        accessRequests += 1
        if accessState == .notDetermined && answersRequests { accessState = grantsAccess ? .full : .denied }
        return accessState == .full
    }

    public func lists() -> [AppleList] { accessState == .full ? allLists : [] }

    /// The list Siri would use; set by tests.
    public var defaultListIdentifier: String?
    public func defaultListID() -> String? { defaultListIdentifier }

    public func createList(title: String) throws -> AppleList {
        guard accessState == .full else { throw AppleStoreError.noAccess }
        let list = AppleList(id: "L\(nextNumber())", title: title, account: "测试账户", writable: true)
        allLists.append(list)
        return list
    }

    public func fetchIncomplete(listIDs: [String]) async throws -> [AppleItem] {
        guard accessState == .full else { throw AppleStoreError.noAccess }
        return items.values.filter { listIDs.contains($0.listID) && !$0.fields.completed }.sorted { $0.id < $1.id }
    }

    public func item(withID id: String) -> AppleItem? { items[id] }

    public func items(withExternalID id: String) -> [AppleItem] { items.values.filter { $0.externalID == id } }

    public func create(_ new: AppleNewItem, inList listID: String) throws -> AppleItem {
        guard accessState == .full else { throw AppleStoreError.noAccess }
        guard !failWrites else { throw AppleStoreError.failed("模拟的写入失败") }
        guard allLists.contains(where: { $0.id == listID }) else { throw AppleStoreError.listMissing }
        let n = nextNumber()
        let item = AppleItem(id: "R\(n)", externalID: "E\(n)", listID: listID, fields: new.fields, completedAt: nil,
                             alarmDates: new.alarms, notes: new.notes, url: new.url, modifiedAt: clock())
        items[item.id] = item
        writes += 1
        return item
    }

    public func update(id: String, _ change: AppleChange) throws -> AppleItem {
        guard accessState == .full else { throw AppleStoreError.noAccess }
        guard !failWrites else { throw AppleStoreError.failed("模拟的写入失败") }
        guard var item = items[id] else { throw AppleStoreError.notFound(id) }
        var f = item.fields
        if let title = change.title { f.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        switch change.due {
        case .set(let date, let hasTime)?:
            f = AppleFields(title: f.title, due: date, hasTime: hasTime, completed: f.completed, calendar: calendar)
        case .clear?:
            f = AppleFields(title: f.title, due: nil, hasTime: false, completed: f.completed, calendar: calendar)
        case nil: break
        }
        if let done = change.completed {
            f.completed = done
            item.completedAt = done ? clock() : nil
        }
        item.alarmDates.removeAll { alarm in change.removeAlarms.contains { sameMinute($0, alarm) } }
        for alarm in change.addAlarms where !item.alarmDates.contains(where: { sameMinute($0, alarm) }) { item.alarmDates.append(alarm) }
        item.alarmOffsets.removeAll { offset in change.removeAlarmOffsets.contains { abs($0 - offset) < 1 } }
        for offset in change.addAlarmOffsets where !item.alarmOffsets.contains(where: { abs($0 - offset) < 1 }) { item.alarmOffsets.append(offset) }
        item.fields = f
        item.modifiedAt = clock()
        items[id] = item
        writes += 1
        return item
    }

    public func remove(id: String) throws {
        guard accessState == .full else { throw AppleStoreError.noAccess }
        guard !failWrites else { throw AppleStoreError.failed("模拟的写入失败") }
        if items.removeValue(forKey: id) != nil { writes += 1 }
    }

    // MARK: the person using the Reminders app

    @discardableResult
    public func userAdd(title: String, due: Date? = nil, hasTime: Bool = true, in listID: String, recurring: Bool = false) -> String {
        let n = nextNumber()
        let fields = AppleFields(title: title, due: due, hasTime: hasTime, completed: false, calendar: calendar)
        items["R\(n)"] = AppleItem(id: "R\(n)", externalID: "E\(n)", listID: listID, fields: fields, hasRecurrence: recurring,
                                   modifiedAt: clock())
        onChange?()
        return "R\(n)"
    }

    public func userSetTitle(_ id: String, _ title: String) {
        mutate(id) { $0.fields.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// `moveAlarms`: what the real Reminders app does, an alarm at the old time follows the new time.
    public func userSetDue(_ id: String, _ due: Date?, hasTime: Bool = true, moveAlarms: Bool = false) {
        mutate(id) {
            let old = $0.fields.due
            $0.fields = AppleFields(title: $0.fields.title, due: due, hasTime: hasTime, completed: $0.fields.completed, calendar: calendar)
            if moveAlarms, let old, let due {
                $0.alarmDates = $0.alarmDates.map { sameMinute($0, old) ? due : $0 }
            }
        }
    }

    public func userSetCompleted(_ id: String, _ completed: Bool) {
        mutate(id) {
            $0.fields.completed = completed
            $0.completedAt = completed ? clock() : nil
        }
    }

    public func userSetRecurring(_ id: String, _ recurring: Bool = true) { mutate(id) { $0.hasRecurrence = recurring } }

    public func userMove(_ id: String, to listID: String) { mutate(id) { $0.listID = listID } }

    public func userDelete(_ id: String) {
        items.removeValue(forKey: id)
        onChange?()
    }

    /// The database hands out a new identifier for the same reminder (what a full iCloud sync can do).
    @discardableResult
    public func userRekey(_ id: String) -> String? {
        guard var item = items.removeValue(forKey: id) else { return nil }
        let newID = "R\(nextNumber())"
        item.id = newID
        items[newID] = item
        onChange?()
        return newID
    }

    public func userRemoveList(_ id: String) {
        allLists.removeAll { $0.id == id }
        for (key, item) in items where item.listID == id { items.removeValue(forKey: key) }
        onChange?()
    }

    /// Adds a list as if it were made in the Reminders app.
    @discardableResult
    public func userAddList(_ title: String) -> AppleList {
        let list = AppleList(id: "L\(nextNumber())", title: title, account: "测试账户", writable: true)
        allLists.append(list)
        onChange?()
        return list
    }

    private func mutate(_ id: String, _ change: (inout AppleItem) -> Void) {
        guard var item = items[id] else { return }
        change(&item)
        item.modifiedAt = clock()
        items[id] = item
        onChange?()
    }

    private func sameMinute(_ a: Date, _ b: Date) -> Bool {
        Int(a.timeIntervalSince1970 / 60) == Int(b.timeIntervalSince1970 / 60)
    }
}
