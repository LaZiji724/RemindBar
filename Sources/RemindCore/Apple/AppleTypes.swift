import Foundation

// The data model of the link with Apple's Reminders app. Nothing here touches EventKit, so the whole merge logic can be
// tested offline against `InMemoryAppleStore`.

public enum AppleAccess: Equatable, Sendable {
    case notDetermined, denied, restricted, writeOnly, full
}

public struct AppleList: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    /// The account the list lives in ("iCloud", "我的 Mac"…).
    public var account: String
    public var writable: Bool

    public init(id: String, title: String, account: String = "", writable: Bool = true) {
        self.id = id
        self.title = title
        self.account = account
        self.writable = writable
    }
}

/// The part of a reminder both apps share. Values are normalised on creation, so equal moments compare equal:
/// a time is cut to the minute (Apple stores no seconds), a date without a time is the start of its day.
public struct AppleFields: Codable, Equatable, Sendable {
    public var title: String
    public var due: Date?
    public var hasTime: Bool
    public var completed: Bool

    public init(title: String, due: Date?, hasTime: Bool, completed: Bool, calendar: Calendar) {
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let due {
            if hasTime {
                self.due = Date(timeIntervalSince1970: (due.timeIntervalSince1970 / 60).rounded(.down) * 60)
                self.hasTime = true
            } else {
                self.due = calendar.startOfDay(for: due)
                self.hasTime = false
            }
        } else {
            self.due = nil
            self.hasTime = false
        }
        self.completed = completed
    }

    /// Deadline and whether it carries a time of day, compared as one thing.
    var dueSpec: DueSpec { DueSpec(date: due, hasTime: hasTime) }
}

struct DueSpec: Equatable {
    var date: Date?
    var hasTime: Bool
}

/// A reminder as Apple's Reminders app holds it.
public struct AppleItem: Equatable, Sendable {
    public var id: String
    /// Server side identifier (same on all devices); used to find the item again if `id` changes.
    public var externalID: String?
    public var listID: String
    public var fields: AppleFields
    public var completedAt: Date?
    public var hasRecurrence: Bool
    /// Alarms that go off at a fixed moment.
    public var alarmDates: [Date]
    public var notes: String?
    public var url: String?
    public var modifiedAt: Date?

    public init(id: String, externalID: String? = nil, listID: String, fields: AppleFields, completedAt: Date? = nil,
                hasRecurrence: Bool = false, alarmDates: [Date] = [], notes: String? = nil, url: String? = nil,
                modifiedAt: Date? = nil) {
        self.id = id
        self.externalID = externalID
        self.listID = listID
        self.fields = fields
        self.completedAt = completedAt
        self.hasRecurrence = hasRecurrence
        self.alarmDates = alarmDates
        self.notes = notes
        self.url = url
        self.modifiedAt = modifiedAt
    }
}

public struct AppleNewItem: Equatable, Sendable {
    public var fields: AppleFields
    public var notes: String?
    public var url: String?
    /// Fixed-moment alarms (so the iPhone rings ahead of the deadline and at it).
    public var alarms: [Date]

    public init(fields: AppleFields, notes: String? = nil, url: String? = nil, alarms: [Date] = []) {
        self.fields = fields
        self.notes = notes
        self.url = url
        self.alarms = alarms
    }
}

/// What to change on an existing Apple reminder; nil fields are left alone.
public struct AppleChange: Equatable, Sendable {
    public enum Due: Equatable, Sendable {
        case set(Date, hasTime: Bool)
        case clear
    }
    public var title: String?
    public var due: Due?
    public var completed: Bool?
    /// Fixed-moment alarms to add.
    public var addAlarms: [Date] = []
    /// Fixed-moment alarms at these minutes are taken away.
    public var removeAlarms: [Date] = []

    public init() {}

    public var isEmpty: Bool {
        title == nil && due == nil && completed == nil && addAlarms.isEmpty && removeAlarms.isEmpty
    }
}

public enum AppleStoreError: Error, LocalizedError, Equatable {
    case noAccess
    case listMissing
    case notFound(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .noAccess: return "没有访问提醒事项的权限"
        case .listMissing: return "找不到提醒事项里的列表"
        case .notFound(let what): return "在提醒事项里找不到：\(what)"
        case .failed(let message): return message
        }
    }
}

/// Everything the merge needs from Apple's Reminders app. Implemented over EventKit by the app and in memory for tests.
@MainActor
public protocol AppleReminderStore: AnyObject {
    /// Called (on the main actor) when something changed in the Reminders database, ours included.
    var onChange: (() -> Void)? { get set }
    func access() -> AppleAccess
    /// Shows the system permission dialog the first time; true when the app may read and write reminders.
    func requestAccess() async -> Bool
    func lists() -> [AppleList]
    /// The list new reminders go to by default (what Siri and the Reminders app use), if there is one.
    func defaultListID() -> String?
    func createList(title: String) throws -> AppleList
    /// Incomplete reminders in the given lists.
    func fetchIncomplete(listIDs: [String]) async throws -> [AppleItem]
    /// Any reminder (also a completed one, or one in another list) by its identifier.
    func item(withID id: String) -> AppleItem?
    func items(withExternalID id: String) -> [AppleItem]
    func create(_ new: AppleNewItem, inList listID: String) throws -> AppleItem
    func update(id: String, _ change: AppleChange) throws -> AppleItem
    /// Removing something that is already gone is not an error.
    func remove(id: String) throws
}

// MARK: - what is stored in state.json

public enum AppleOrigin: String, Codable, Sendable {
    /// The Apple copy was made by this app.
    case app
    /// The reminder was made in Apple's Reminders app and imported.
    case apple
}

/// One reminder of ours and its twin in Apple's Reminders app.
public struct AppleLink: Codable, Equatable, Sendable {
    public var reminderID: UUID
    public var appleID: String?
    public var externalID: String?
    public var listID: String?
    /// The values both sides agreed on at the last sync (the base of the three-way merge).
    public var synced: AppleFields?
    public var origin: AppleOrigin
    /// The Apple copy was removed (or moved out of the synced lists) by the user: it is never created again.
    public var optOut: Bool

    public init(reminderID: UUID, appleID: String?, externalID: String?, listID: String?, synced: AppleFields?,
                origin: AppleOrigin, optOut: Bool = false) {
        self.reminderID = reminderID
        self.appleID = appleID
        self.externalID = externalID
        self.listID = listID
        self.synced = synced
        self.origin = origin
        self.optOut = optOut
    }
}

public struct AppleSyncConfig: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    /// The list this app creates its reminders in.
    public var managedListID: String?
    public var managedListTitle: String = "提醒条"
    /// Further lists whose reminders are imported and kept in sync (the managed list is always included).
    public var importListIDs: [String] = []
    /// Also mirror reminders that come from Canvas, 课堂派 and watched pages.
    public var includeWebsiteItems: Bool = true
    /// Give the copies in Apple's Reminders the same alarms this app rings (1 day ahead … the due time), so the iPhone rings too.
    public var alarms: Bool = true
    /// The default list was considered for import the first time the link was switched on.
    public var defaultListOffered: Bool = false
    public var lastSyncAt: Date?
    public var lastStatus: String?

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, managedListID, managedListTitle, importListIDs, includeWebsiteItems, alarms, defaultListOffered, lastSyncAt, lastStatus
    }

    // Every key is optional on read, so a state file keeps loading when a field is added later.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        managedListID = try c.decodeIfPresent(String.self, forKey: .managedListID)
        managedListTitle = try c.decodeIfPresent(String.self, forKey: .managedListTitle) ?? "提醒条"
        importListIDs = try c.decodeIfPresent([String].self, forKey: .importListIDs) ?? []
        includeWebsiteItems = try c.decodeIfPresent(Bool.self, forKey: .includeWebsiteItems) ?? true
        alarms = try c.decodeIfPresent(Bool.self, forKey: .alarms) ?? true
        defaultListOffered = try c.decodeIfPresent(Bool.self, forKey: .defaultListOffered) ?? false
        lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
        lastStatus = try c.decodeIfPresent(String.self, forKey: .lastStatus)
    }
}

public struct AppleSyncState: Codable, Equatable, Sendable {
    public var config = AppleSyncConfig()
    public var links: [AppleLink] = []

    public init() {}

    private enum CodingKeys: String, CodingKey { case config, links }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        config = try c.decodeIfPresent(AppleSyncConfig.self, forKey: .config) ?? AppleSyncConfig()
        links = try c.decodeIfPresent([AppleLink].self, forKey: .links) ?? []
    }
}
