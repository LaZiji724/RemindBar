import Foundation

public enum DayBucket: Int, CaseIterable, Sendable {
    case overdue, today, tomorrow, thisWeek, later, noDue

    public var title: String {
        switch self {
        case .overdue: return "已逾期"
        case .today: return "今天"
        case .tomorrow: return "明天"
        case .thisWeek: return "本周"
        case .later: return "之后"
        case .noDue: return "无截止"
        }
    }
}

public enum Urgency: Sendable {
    case overdue, soon, today, normal
}

/// Human readable strings shared by the panel, notifications and the menu bar title.
public enum DisplayFormat {
    private static let weekdayNames = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    public static func bucket(for r: Reminder, now: Date, calendar: Calendar) -> DayBucket {
        guard let due = r.due else { return .noDue }
        if due < now { return .overdue }
        let days = dayDistance(from: now, to: due, calendar: calendar)
        switch days {
        case ..<1: return .today
        case 1: return .tomorrow
        default:
            // Rest of the current Monday-based week; anything after is "later".
            let week = calendar.dateInterval(of: .weekOfYear, for: now)
            if let week, due < week.end { return .thisWeek }
            return .later
        }
    }

    /// Calendar days between two instants (0 = same day).
    public static func dayDistance(from a: Date, to b: Date, calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: a), to: calendar.startOfDay(for: b)).day ?? 0
    }

    public static func dayLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        switch dayDistance(from: now, to: date, calendar: calendar) {
        case 0: return "今天"
        case 1: return "明天"
        case 2: return "后天"
        case -1: return "昨天"
        case -2: return "前天"
        default:
            let c = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
            let weekday = weekdayNames[((c.weekday ?? 1) - 1 + 7) % 7]
            if c.year == calendar.component(.year, from: now) {
                return "\(c.month ?? 0)月\(c.day ?? 0)日 \(weekday)"
            }
            return "\(c.year ?? 0)年\(c.month ?? 0)月\(c.day ?? 0)日 \(weekday)"
        }
    }

    /// Like `dayLabel`, but near days also carry the calendar date: "今天 10月26日 周一".
    public static func fullDayLabel(_ date: Date, now: Date, calendar: Calendar) -> String {
        let label = dayLabel(date, now: now, calendar: calendar)
        guard (-2...2).contains(dayDistance(from: now, to: date, calendar: calendar)) else { return label }
        let c = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let weekday = weekdayNames[((c.weekday ?? 1) - 1 + 7) % 7]
        let datePart = c.year == calendar.component(.year, from: now)
            ? "\(c.month ?? 0)月\(c.day ?? 0)日 \(weekday)"
            : "\(c.year ?? 0)年\(c.month ?? 0)月\(c.day ?? 0)日 \(weekday)"
        return "\(label) \(datePart)"
    }

    public static func timeLabel(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// "今天 19:00", "10月30日 周五 23:59"
    public static func dueLabel(_ due: Date, now: Date, calendar: Calendar) -> String {
        "\(dayLabel(due, now: now, calendar: calendar)) \(timeLabel(due, calendar: calendar))"
    }

    /// "3小时后", "25分钟后", "已逾期 2小时", "现在"
    public static func countdown(to due: Date, now: Date) -> String {
        let diff = due.timeIntervalSince(now)
        if diff <= -60 { return "已逾期 \(span(-diff))" }
        if diff < 60 { return "现在" }
        return "\(span(diff))后"
    }

    private static func span(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(max(minutes, 1))分钟" }
        let hours = minutes / 60
        if minutes < 6 * 60 {
            let rest = minutes % 60
            return rest == 0 ? "\(hours)小时" : "\(hours)小时\(rest)分"
        }
        if minutes < 48 * 60 { return "\(hours)小时" }
        return "\(minutes / (24 * 60))天"
    }

    public static func urgency(of due: Date?, now: Date) -> Urgency {
        guard let due else { return .normal }
        let diff = due.timeIntervalSince(now)
        if diff < 0 { return .overdue }
        if diff < 3_600 { return .soon }
        if diff < 86_400 { return .today }
        return .normal
    }

    /// Body text of an alert, e.g. "还有3小时 · 课堂派 · 高等数学".
    public static func alertBody(for r: Reminder, lead: Double, now: Date, calendar: Calendar) -> String {
        var parts: [String] = []
        if lead < 0 {
            parts.append("稍后提醒")
        } else if lead == 0 {
            parts.append(r.isDeadline ? "已到截止时间" : "时间到")
        } else {
            parts.append("还有\(span(lead))\(r.isDeadline ? "截止" : "")")
        }
        if r.source != .manual { parts.append(r.source.displayName) }
        if let c = r.course, !c.isEmpty { parts.append(c) }
        if let due = r.due { parts.append(dueLabel(due, now: now, calendar: calendar)) }
        return parts.joined(separator: " · ")
    }
}
