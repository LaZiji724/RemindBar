import Foundation

public enum Prompts {
    /// Static on purpose: the identical prefix is served from DeepSeek's context cache. The moving parts go last.
    public static let parseSystem = """
    你是日程解析器。把用户的一句话整理成提醒事项，只输出 json，不要解释。
    json 格式：{"items":[{"title":"要做的事","date":"YYYY-MM-DD 或 null","time":"HH:mm 或 null","deadline":false}]}
    规则：
    1. title 只写要做的事，不含日期和时间，20 字以内。
    2. date、time 用 24 小时制。没说日期 date 填 null；没说具体时间 time 填 null。
    3. 带“前”“之前”“截止”“ddl”的是截止时间，deadline 填 true。
    4. 一句话里有几件事就输出几个 items，最多 5 个。
    5. 参考“现在”推算今天、明天、周几等相对日期。
    示例（假设现在是 2026-10-26 周一 21:05）：
    输入：明晚七点半去健身，周五之前交高数作业
    输出：{"items":[{"title":"去健身","date":"2026-10-27","time":"19:30","deadline":false},{"title":"交高数作业","date":"2026-10-30","time":null,"deadline":true}]}
    """

    public static let extractSystem = """
    你是作业提取器。下面是某个网课网页上新出现的文字行，找出其中的作业、任务或考试及其截止时间，只输出 json，不要解释。
    json 格式：{"items":[{"title":"作业名","course":"课程名或 null","due":"YYYY-MM-DD HH:mm 或 null"}]}
    规则：
    1. 只保留有明确截止时间的条目，没有截止时间的不要输出。
    2. title 20 字以内；due 用 24 小时制；只写了日期时 due 的时间填 23:59。
    3. 最多 8 条。参考“现在”推算年份。
    示例（假设现在是 2026-10-26 周一 21:05）：
    文字：
    数据库原理 实验四 截止 11月3日 23:59
    今天天气不错
    输出：{"items":[{"title":"实验四","course":"数据库原理","due":"2026-11-03 23:59"}]}
    """

    public static func extractUser(lines: [String], hint: String, now: Date, calendar: Calendar) -> String {
        var text = "现在：\(nowLine(now, calendar: calendar))\n"
        let clippedHint = String(hint.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !clippedHint.isEmpty { text += "用户要求：\(clippedHint)\n" }
        return text + "文字：\n" + lines.joined(separator: "\n")
    }

    private static let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]

    public static func nowLine(_ now: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: now)
        return String(format: "%04d-%02d-%02d %@ %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      weekdays[((c.weekday ?? 1) - 1 + 7) % 7], c.hour ?? 0, c.minute ?? 0)
    }

    public static func parseUser(text: String, now: Date, calendar: Calendar) -> String {
        "现在：\(nowLine(now, calendar: calendar))\n输入：\(text)"
    }
}

public struct AIReminderItem: Equatable, Sendable {
    public var title: String
    public var date: String?
    public var time: String?
    public var deadline: Bool

    public init(title: String, date: String?, time: String?, deadline: Bool) {
        self.title = title
        self.date = date
        self.time = time
        self.deadline = deadline
    }
}

/// AI proposes, this decides. Nothing from the model reaches a reminder without passing these checks.
public enum ResultValidator {
    public static func parseReminderItems(_ json: String, now: Date, calendar: Calendar) -> Result<[AIReminderItem], AIError> {
        guard let data = json.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.invalidJSON)
        }
        var rawItems: [[String: Any]] = []
        if let list = root["items"] as? [[String: Any]] {
            rawItems = list
        } else if root["title"] != nil {
            rawItems = [root]
        }
        guard !rawItems.isEmpty else { return .failure(.invalidAnswer("没有 items")) }

        var items: [AIReminderItem] = []
        var firstProblem = ""
        for raw in rawItems.prefix(AIPolicy.maxItemsPerAnswer) {
            switch validate(raw, now: now, calendar: calendar) {
            case .success(let item): items.append(item)
            case .failure(let error):
                if firstProblem.isEmpty, case .invalidAnswer(let detail) = error { firstProblem = detail }
            }
        }
        guard !items.isEmpty else { return .failure(.invalidAnswer(firstProblem.isEmpty ? "没有有效的条目" : firstProblem)) }
        return .success(items)
    }

    private static func validate(_ raw: [String: Any], now: Date, calendar: Calendar) -> Result<AIReminderItem, AIError> {
        guard let title = (raw["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return .failure(.invalidAnswer("标题为空"))
        }
        guard title.count <= 80 else { return .failure(.invalidAnswer("标题过长")) }

        var date: String?
        if let d = raw["date"] as? String, !d.isEmpty, d.lowercased() != "null" {
            guard isValidDate(d, now: now, calendar: calendar) else { return .failure(.invalidAnswer("日期不合法：\(d)")) }
            date = d
        }
        var time: String?
        if let t = raw["time"] as? String, !t.isEmpty, t.lowercased() != "null" {
            guard t.range(of: #"^([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil else {
                return .failure(.invalidAnswer("时间不合法：\(t)"))
            }
            time = t
        }
        let deadline = (raw["deadline"] as? Bool) ?? false
        return .success(AIReminderItem(title: title, date: date, time: time, deadline: deadline))
    }

    /// yyyy-MM-dd, a real calendar day, between yesterday and two years ahead.
    private static func isValidDate(_ s: String, now: Date, calendar: Calendar) -> Bool {
        guard s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        guard let date = calendar.date(from: c) else { return false }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == parts[0], back.month == parts[1], back.day == parts[2] else { return false }
        let today = calendar.startOfDay(for: now)
        guard let lower = calendar.date(byAdding: .day, value: -1, to: today),
              let upper = calendar.date(byAdding: .day, value: 730, to: today) else { return false }
        return date >= lower && date <= upper
    }

    /// Turns validated items into events, applying the same defaults as the local parser.
    public static func events(from items: [AIReminderItem], context ctx: ParseContext, original: String) -> [ParsedEvent] {
        let cal = ctx.calendar
        return items.map { item in
            var flags: ParseFlags = [.aiAssisted]
            var due: Date?
            var explicitDate = false
            var explicitTime = false
            var hour = 0, minute = 0
            if let t = item.time {
                let p = t.split(separator: ":").compactMap { Int($0) }
                hour = p[0]; minute = p[1]
                explicitTime = true
            } else if item.deadline {
                hour = ctx.deadlineHour; minute = ctx.deadlineMinute
                flags.insert(.defaultTime)
            } else {
                hour = ctx.defaultHour; minute = ctx.defaultMinute
                flags.insert(.defaultTime)
            }
            if let d = item.date {
                let p = d.split(separator: "-").compactMap { Int($0) }
                var c = DateComponents()
                c.year = p[0]; c.month = p[1]; c.day = p[2]; c.hour = hour; c.minute = minute
                due = cal.date(from: c)
                explicitDate = true
            } else if item.time != nil {
                var candidate = cal.date(bySettingHour: hour, minute: minute, second: 0, of: ctx.now)
                if let c = candidate, c <= ctx.now {
                    candidate = cal.date(byAdding: .day, value: 1, to: c)
                    flags.insert(.rolledForward)
                }
                due = candidate
            } else {
                flags.insert(.noDateTime)
                flags.remove(.defaultTime)
            }
            if let d = due, d < ctx.now { flags.insert(.past) }
            return ParsedEvent(title: item.title, due: due, hasExplicitDate: explicitDate, hasExplicitTime: explicitTime,
                               isDeadline: item.deadline, flags: flags, alternative: nil,
                               confidence: due == nil ? .low : .medium, sourceText: original)
        }
    }
}

public struct AIAssignment: Equatable, Sendable {
    public var title: String
    public var course: String?
    public var due: Date
}

public enum AIExtractOutcome: Equatable {
    case items([AIAssignment], cached: Bool)
    case skipped(AISkip)
    case failed(AIError)
}

extension ResultValidator {
    /// `{"items":[{"title","course","due":"YYYY-MM-DD HH:mm"}]}` → validated assignments (undated ones are dropped).
    public static func parseAssignments(_ json: String, now: Date, calendar: Calendar) -> Result<[AIAssignment], AIError> {
        guard let data = json.data(using: .utf8), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["items"] as? [[String: Any]] else { return .failure(.invalidJSON) }
        var out: [AIAssignment] = []
        for item in raw.prefix(8) {
            guard let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty, title.count <= 80,
                  let dueText = item["due"] as? String,
                  let due = parseDateTime(dueText, calendar: calendar),
                  due >= now.addingTimeInterval(-30 * 86_400), due <= now.addingTimeInterval(730 * 86_400) else { continue }
            let course = (item["course"] as? String).flatMap { $0.isEmpty || $0.lowercased() == "null" ? nil : String($0.prefix(60)) }
            out.append(AIAssignment(title: title, course: course, due: due))
        }
        return .success(out)
    }

    static func parseDateTime(_ s: String, calendar: Calendar) -> Date? {
        guard s.range(of: #"^\d{4}-\d{2}-\d{2} ([01]\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil else { return nil }
        let p = s.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == ":" }).compactMap { Int($0) }
        guard p.count == 5 else { return nil }
        var c = DateComponents()
        c.year = p[0]; c.month = p[1]; c.day = p[2]; c.hour = p[3]; c.minute = p[4]
        guard let date = calendar.date(from: c) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return (back.year == p[0] && back.month == p[1] && back.day == p[2] && back.hour == p[3] && back.minute == p[4]) ? date : nil
    }
}

public enum AIParseOutcome: Equatable {
    case events([ParsedEvent], cached: Bool)
    case skipped(AISkip)
    case failed(AIError)
}

@MainActor
public final class AIService {
    public let gate: AIGate

    public init(gate: AIGate) { self.gate = gate }

    /// Asks DeepSeek to read a sentence the local parser could not make sense of.
    public func parseReminders(_ text: String, context ctx: ParseContext, sourceID: String? = nil) async -> AIParseOutcome {
        let clipped = String(text.prefix(AIPolicy.maxInputCharacters))
        let day = Prompts.nowLine(ctx.now, calendar: ctx.calendar).prefix(10)
        let task = AITask(purpose: "parse", system: Prompts.parseSystem,
                          user: Prompts.parseUser(text: clipped, now: ctx.now, calendar: ctx.calendar),
                          maxTokens: AIPolicy.maxTokensParse, sourceID: sourceID,
                          cacheKey: "\(day)|\(clipped)")
        switch await gate.run(task) {
        case .skipped(let reason):
            return .skipped(reason)
        case .failed(let error):
            return .failed(error)
        case .cached(let json):
            return finish(json, ctx: ctx, original: text, cached: true)
        case .fresh(let json, _):
            return finish(json, ctx: ctx, original: text, cached: false)
        }
    }

    /// Reads homework out of new page lines. One call, input already clipped and pre-filtered by the caller.
    public func extractAssignments(lines: [String], hint: String, context ctx: ParseContext, sourceID: String) async -> AIExtractOutcome {
        let user = Prompts.extractUser(lines: lines, hint: hint, now: ctx.now, calendar: ctx.calendar)
        let day = String(Prompts.nowLine(ctx.now, calendar: ctx.calendar).prefix(10))
        let task = AITask(purpose: "extract", system: Prompts.extractSystem, user: user, maxTokens: AIPolicy.maxTokensBatch,
                          sourceID: sourceID, cacheKey: "\(day)|\(sourceID)|\(hint)|\(lines.joined(separator: "\n"))")
        switch await gate.run(task) {
        case .skipped(let reason): return .skipped(reason)
        case .failed(let error): return .failed(error)
        case .cached(let json): return mapAssignments(json, ctx: ctx, cached: true)
        case .fresh(let json, _): return mapAssignments(json, ctx: ctx, cached: false)
        }
    }

    private func mapAssignments(_ json: String, ctx: ParseContext, cached: Bool) -> AIExtractOutcome {
        switch ResultValidator.parseAssignments(json, now: ctx.now, calendar: ctx.calendar) {
        case .success(let items): return .items(items, cached: cached)
        case .failure(let error): return .failed(error)
        }
    }

    private func finish(_ json: String, ctx: ParseContext, original: String, cached: Bool) -> AIParseOutcome {
        switch ResultValidator.parseReminderItems(json, now: ctx.now, calendar: ctx.calendar) {
        case .success(let items):
            return .events(ResultValidator.events(from: items, context: ctx, original: original), cached: cached)
        case .failure(let error):
            return .failed(error)
        }
    }
}
