import Foundation

/// Turns the visible text of a page into stable lines, finds what is new since the last visit and which of those
/// lines could possibly be about homework or deadlines. All local; no AI involved.
public enum PageText {
    private static let relativeTimes = try! NSRegularExpression(pattern: #"(\d+\s*(秒|分钟|小时|天)前|刚刚|昨天|前天)"#)
    private static let counters = try! NSRegularExpression(pattern: #"(共\s*\d+\s*(条|项|个|页)|浏览\s*\d+\s*次?|\d+\s*(人|次)\s*(浏览|查看|提交|已交|阅读))"#)
    private static let keywords = try! NSRegularExpression(
        pattern: #"作业|截止|提交|交付|到期|逾期|deadline|\bdue\b|ddl|考试|测验|测试|quiz|exam|实验|报告|论文|任务|assignment|homework|project|待办"#,
        options: [.caseInsensitive])

    public static func hasKeyword(_ line: String) -> Bool {
        keywords.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    /// Normalised, de-duplicated lines (volatile bits such as "5分钟前" or view counters removed so an unchanged
    /// page keeps the same fingerprint).
    public static func lines(from raw: String, maxLines: Int = 600) -> [String] {
        var out: [String] = []
        for rawLine in raw.components(separatedBy: .newlines) {
            var line = TextNormalizer.normalize(rawLine)
            for regex in [relativeTimes, counters] {
                line = regex.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length), withTemplate: "")
            }
            line = line.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            guard line.count >= 2 else { continue }
            if line.count > 300 { line = String(line.prefix(300)) }
            if out.last == line { continue }
            out.append(line)
            if out.count >= maxLines { break }
        }
        return out
    }

    public static func fingerprint(_ lines: [String]) -> String {
        AICache.key(lines.joined(separator: "\n"))
    }

    /// Lines that were not on the page last time (everything, on the first visit).
    public static func addedLines(old: [String]?, new: [String]) -> [String] {
        guard let old else { return new }
        let known = Set(old)
        return new.filter { !known.contains($0) }
    }

    /// A real date or clock time; a bare "今天" or "明天" alone does not make a line interesting.
    static func hasConcreteDate(_ line: String) -> Bool {
        Tokenizer.tokenize(line).contains { token in
            switch token.kind {
            case .clock, .absDate, .dayOfMonth, .monthDay, .monthEdge, .weekday: return true
            default: return false
            }
        }
    }

    /// Lines worth a closer look: they mention homework-ish words or contain a date/time, plus the neighbours of
    /// dated lines (the title is often on the line above or below the deadline).
    public static func candidates(_ lines: [String], maxCharacters: Int = AIPolicy.maxInputCharacters - 500) -> [String] {
        var picked = Set<Int>()
        for (i, line) in lines.enumerated() {
            let hasDate = hasConcreteDate(line)
            if hasKeyword(line) || hasDate { picked.insert(i) }
            if hasDate {
                if i > 0 { picked.insert(i - 1) }
                if i + 1 < lines.count { picked.insert(i + 1) }
            }
        }
        var out: [String] = []
        var total = 0
        for i in picked.sorted() {
            let line = lines[i]
            if total + line.count + 1 > maxCharacters { break }
            out.append(line)
            total += line.count + 1
        }
        return out
    }
}

public enum PageExtractor {
    /// Reads lines like "实验四 截止 11月3日 23:59" with the local parser. Returns what it understood and the
    /// homework-ish lines it could not (those may go to the AI).
    public static func localItems(from lines: [String], watcherID: String, context ctx: ParseContext) -> (items: [RemoteItem], remaining: [String]) {
        var items: [RemoteItem] = []
        var remaining: [String] = []
        var seen = Set<String>()
        for line in lines {
            guard PageText.hasKeyword(line) else { continue }
            if let event = NLParser.parse(line, context: ctx).first, let due = event.due,
               event.confidence != .low, event.title.count >= 2, !event.flags.contains(.past) || due > ctx.now.addingTimeInterval(-14 * 86_400) {
                let key = itemKey(watcherID: watcherID, title: event.title, due: due)
                if seen.insert(key).inserted {
                    items.append(RemoteItem(key: key, title: event.title, course: nil, due: due, url: nil, completed: false))
                }
            } else {
                remaining.append(line)
            }
        }
        return (items, remaining)
    }

    public static func itemKey(watcherID: String, title: String, due: Date) -> String {
        "web:\(watcherID.prefix(8)):" + String(AICache.key(title, String(Int(due.timeIntervalSince1970 / 60))).prefix(16))
    }
}
