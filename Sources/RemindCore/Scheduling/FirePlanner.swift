import Foundation

public struct Fire: Hashable, Sendable, Identifiable {
    public let reminderID: UUID
    public let at: Date
    /// Seconds before the due time; -1 marks a snooze alert.
    public let lead: Double

    public var id: String { "\(reminderID.uuidString)|\(Int(at.timeIntervalSince1970))" }

    public init(reminderID: UUID, at: Date, lead: Double) {
        self.reminderID = reminderID
        self.at = at
        self.lead = lead
    }
}

public enum FirePlanner {
    /// All alert instants of a reminder, including ones in the past.
    public static func allFires(for r: Reminder) -> [Fire] {
        guard r.status == .pending, !r.ignored else { return [] }
        var out: [Fire] = []
        if let due = r.due {
            for lead in Set(r.leadTimes) where lead >= 0 {
                out.append(Fire(reminderID: r.id, at: due.addingTimeInterval(-lead), lead: lead))
            }
        }
        if let s = r.snoozedUntil { out.append(Fire(reminderID: r.id, at: s, lead: -1)) }
        return out.sorted { $0.at < $1.at }
    }

    public static func fires(for r: Reminder, after now: Date) -> [Fire] {
        allFires(for: r).filter { $0.at > now }
    }

    /// The next `limit` alerts across all reminders (the system keeps at most 64 pending notifications).
    public static func plan(_ reminders: [Reminder], after now: Date, limit: Int = 60) -> [Fire] {
        let all = reminders.flatMap { fires(for: $0, after: now) }.sorted { $0.at < $1.at }
        return Array(all.prefix(limit))
    }

    /// Alerts with `from < at <= to`, used to catch up after the Mac slept.
    public static func missed(_ reminders: [Reminder], from: Date, to: Date) -> [Fire] {
        reminders.flatMap { allFires(for: $0) }
            .filter { $0.at > from && $0.at <= to }
            .sorted { $0.at < $1.at }
    }
}
