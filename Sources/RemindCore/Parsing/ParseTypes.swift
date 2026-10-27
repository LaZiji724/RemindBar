import Foundation

public extension Calendar {
    /// Gregorian calendar in the current time zone, weeks start on Monday (Chinese convention).
    static var reminder: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        c.locale = Locale(identifier: "zh_CN")
        return c
    }
}

public struct ParseContext: Sendable {
    public var now: Date
    public var calendar: Calendar
    /// Time used when only a date is given ("明天交作业").
    public var defaultHour: Int
    public var defaultMinute: Int
    /// Time used when the text is a deadline ("周五前") and no clock time is given.
    public var deadlineHour: Int
    public var deadlineMinute: Int

    public init(now: Date = Date(),
                calendar: Calendar = .reminder,
                defaultHour: Int = 9, defaultMinute: Int = 0,
                deadlineHour: Int = 23, deadlineMinute: Int = 59) {
        self.now = now
        self.calendar = calendar
        self.defaultHour = defaultHour
        self.defaultMinute = defaultMinute
        self.deadlineHour = deadlineHour
        self.deadlineMinute = deadlineMinute
    }
}

public enum ParseConfidence: Int, Comparable, Sendable {
    case low = 0, medium = 1, high = 2
    public static func < (a: ParseConfidence, b: ParseConfidence) -> Bool { a.rawValue < b.rawValue }
}

public struct ParseFlags: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// "7点" without 上午/下午: AM/PM was guessed; `alternative` holds the other reading.
    public static let ampmInferred = ParseFlags(rawValue: 1 << 0)
    /// Only a date was given; the default (or deadline) time of day was used.
    public static let defaultTime = ParseFlags(rawValue: 1 << 1)
    /// Only a period word ("明天下午") was given; a typical time for that period was used.
    public static let periodDefaultTime = ParseFlags(rawValue: 1 << 2)
    /// A time-only phrase that already passed today was moved to tomorrow.
    public static let rolledForward = ParseFlags(rawValue: 1 << 3)
    /// The resolved moment is already in the past.
    public static let past = ParseFlags(rawValue: 1 << 4)
    /// "下周" without a weekday: Monday of that week was used.
    public static let weekGeneric = ParseFlags(rawValue: 1 << 5)
    /// Date taken from the previous event of the same utterance.
    public static let dateInherited = ParseFlags(rawValue: 1 << 6)
    /// "每天/每周…" was mentioned; recurring reminders are not supported yet.
    public static let recurrenceMentioned = ParseFlags(rawValue: 1 << 7)
    public static let emptyTitle = ParseFlags(rawValue: 1 << 8)
    /// Date/time looking words remained in the title (probably an invalid or unsupported phrase).
    public static let leftoverDateWords = ParseFlags(rawValue: 1 << 9)
    /// Two different dates/times were found in one event.
    public static let conflict = ParseFlags(rawValue: 1 << 10)
    public static let noDateTime = ParseFlags(rawValue: 1 << 11)
    /// The result came from DeepSeek (and passed validation) instead of the local parser.
    public static let aiAssisted = ParseFlags(rawValue: 1 << 12)
}

public struct ParsedEvent: Equatable, Sendable {
    public var title: String
    public var due: Date?
    public var hasExplicitDate: Bool
    public var hasExplicitTime: Bool
    public var isDeadline: Bool
    public var flags: ParseFlags
    /// The other plausible reading (AM/PM flip, or "tomorrow" for a time that has passed).
    public var alternative: Date?
    public var confidence: ParseConfidence
    public var sourceText: String

    public init(title: String, due: Date?, hasExplicitDate: Bool, hasExplicitTime: Bool, isDeadline: Bool,
                flags: ParseFlags, alternative: Date?, confidence: ParseConfidence, sourceText: String) {
        self.title = title
        self.due = due
        self.hasExplicitDate = hasExplicitDate
        self.hasExplicitTime = hasExplicitTime
        self.isDeadline = isDeadline
        self.flags = flags
        self.alternative = alternative
        self.confidence = confidence
        self.sourceText = sourceText
    }
}
