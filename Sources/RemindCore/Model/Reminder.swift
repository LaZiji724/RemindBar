import Foundation

public enum SourceKind: String, Codable, Sendable, CaseIterable {
    case manual, canvas, ketangpai, web
    /// Created in Apple's Reminders app (imported by the Reminders link).
    case apple

    public var displayName: String {
        switch self {
        case .manual: return "手动"
        case .canvas: return "Canvas"
        case .ketangpai: return "课堂派"
        case .web: return "网页"
        case .apple: return "提醒事项"
        }
    }

    /// Sites whose completion state the app reads itself. Their items have no manual "done": a refresh shows what the
    /// site says. (Generic web pages cannot report completion, so those items can still be ticked off by hand.)
    public var completionFollowsSite: Bool {
        self == .canvas || self == .ketangpai
    }

    public var symbolName: String {
        switch self {
        case .manual: return "bell"
        case .canvas: return "graduationcap"
        case .ketangpai: return "book.closed"
        case .web: return "globe"
        case .apple: return "checklist"
        }
    }
}

public enum ReminderStatus: String, Codable, Sendable {
    case pending, done
}

public enum LeadTimes {
    /// Plain reminders only fire at the due time.
    public static let manual: [Double] = [0]
    /// Deadlines warn 1 day, 3 hours, 30 minutes ahead and at the deadline.
    public static let deadline: [Double] = [86_400, 10_800, 1_800, 0]
}

public struct Reminder: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var due: Date?
    public var hasExplicitTime: Bool
    public var isDeadline: Bool
    public var source: SourceKind
    public var watcherID: String?
    /// Stable id from the remote site, used to de-duplicate on every sync, e.g. "canvas:assignment:123".
    public var externalKey: String?
    public var course: String?
    public var url: String?
    public var notes: String?
    /// Seconds before `due` at which to alert; 0 means exactly at the due time.
    public var leadTimes: [Double]
    public var status: ReminderStatus
    public var snoozedUntil: Date?
    public var createdAt: Date
    public var completedAt: Date?
    /// Reserved for recurring reminders (not implemented yet).
    public var repeatRule: String?
    /// The user chose not to be reminded about this item (offered for Canvas / 课堂派 items only). It stays tracked, so the
    /// website still decides when it is done. Stored as an optional so that state files written before it existed decode.
    public var ignoredFlag: Bool?
    public var ignored: Bool {
        get { ignoredFlag ?? false }
        set { ignoredFlag = newValue ? true : nil }
    }

    public init(id: UUID = UUID(), title: String, due: Date?, hasExplicitTime: Bool = true, isDeadline: Bool = false,
                source: SourceKind = .manual, watcherID: String? = nil, externalKey: String? = nil,
                course: String? = nil, url: String? = nil, notes: String? = nil, leadTimes: [Double]? = nil,
                status: ReminderStatus = .pending, snoozedUntil: Date? = nil, createdAt: Date = Date(),
                completedAt: Date? = nil, repeatRule: String? = nil) {
        self.id = id
        self.title = title
        self.due = due
        self.hasExplicitTime = hasExplicitTime
        self.isDeadline = isDeadline
        self.source = source
        self.watcherID = watcherID
        self.externalKey = externalKey
        self.course = course
        self.url = url
        self.notes = notes
        self.leadTimes = leadTimes ?? (isDeadline ? LeadTimes.deadline : LeadTimes.manual)
        self.status = status
        self.snoozedUntil = snoozedUntil
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.repeatRule = repeatRule
    }

    /// True when the site decides whether this item is done (see `SourceKind.completionFollowsSite`).
    public var completionFollowsSite: Bool { source.completionFollowsSite }

    public init(from event: ParsedEvent, now: Date = Date()) {
        self.init(title: event.title, due: event.due, hasExplicitTime: event.hasExplicitTime,
                  isDeadline: event.isDeadline, source: .manual, createdAt: now)
    }
}

public struct WatcherConfig: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: SourceKind
    public var name: String
    public var url: String
    /// Free-text request typed or dictated by the user ("只关注作业和截止时间").
    public var hint: String
    public var intervalMinutes: Int
    public var enabled: Bool
    public var lastSyncAt: Date?
    public var lastStatus: String?
    public var needsLogin: Bool
    public var initialSyncDone: Bool
    /// Generic web watcher: hash of the last normalised page text.
    public var pageHash: String?
    /// Generic web watcher: last normalised page lines (for diffing).
    public var pageLines: [String]?
    /// Keys of items the user deleted by hand; a sync never brings them back.
    public var deletedKeys: [String] = []
    /// Generic web watcher: how many AI reads in a row found nothing new, and when AI use resumes.
    public var aiEmptyStreak: Int = 0
    public var aiPausedUntil: Date?

    public init(id: String = UUID().uuidString, kind: SourceKind, name: String, url: String, hint: String = "",
                intervalMinutes: Int = 30, enabled: Bool = true, lastSyncAt: Date? = nil, lastStatus: String? = nil,
                needsLogin: Bool = false, initialSyncDone: Bool = false, pageHash: String? = nil, pageLines: [String]? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.url = url
        self.hint = hint
        self.intervalMinutes = intervalMinutes
        self.enabled = enabled
        self.lastSyncAt = lastSyncAt
        self.lastStatus = lastStatus
        self.needsLogin = needsLogin
        self.initialSyncDone = initialSyncDone
        self.pageHash = pageHash
        self.pageLines = pageLines
    }
}

public struct AppState: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var reminders: [Reminder] = []
    public var watchers: [WatcherConfig] = []
    /// Fires up to this instant have already been delivered (used to catch up after sleep).
    public var lastFireCheck: Date?
    /// The link with Apple's Reminders app (nil until the user turns it on).
    public var apple: AppleSyncState?

    public init() {}
}
