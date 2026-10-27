import Foundation

enum Meridiem { case am, pm }
enum Period { case dawn, morning, forenoon, noon, afternoon, dusk, evening }
enum OffsetUnit { case second, minute, hour, day, week, month, year }
enum MonthEdge { case start, mid, end }

struct Tok {
    enum Kind {
        case absDate(y: Int?, m: Int, d: Int)
        case dayOfMonth(Int)
        case relDay(Int)
        case weekday(weekOffset: Int?, iso: Int)
        case weekend(weekOffset: Int?)
        case weekGeneric(weekOffset: Int)
        case monthDay(monthOffset: Int, day: Int)
        case monthEdge(monthOffset: Int?, edge: MonthEdge)
        case offset(unit: OffsetUnit, amount: Double)
        case clock(hour: Int, minute: Int, meridiem: Meridiem?, strict24: Bool)
        case period(Period)
        case deadlineMarker
        case rangeEnd
        case filler
    }

    var kind: Kind
    var range: NSRange

    var isDate: Bool {
        switch kind {
        case .absDate, .dayOfMonth, .relDay, .weekday, .weekend, .weekGeneric, .monthDay, .monthEdge: return true
        default: return false
        }
    }
    var isClock: Bool { if case .clock = kind { return true } else { return false } }
    var isPeriod: Bool { if case .period = kind { return true } else { return false } }
}

enum Pat {
    /// Arabic digits or Chinese numerals, possessive so that "10" is never split into "1" + "0".
    static let N = "[0-9零〇一二两三四五六七八九十百]++"
    /// A number must start at its first digit, never in the middle of "99".
    static let NB = "(?<![0-9零〇一二两三四五六七八九十百])"

    static let ymdCN = Rx.make(#"(?<![0-9])(\d{4}|[零〇一二三四五六七八九]{4})\s*年\s*(\#(N))\s*月\s*(\#(N))\s*[日号]?"#)
    static let ymdSep = Rx.make(#"(?<![\d.\-/])(\d{4})\s*[-/.]\s*(\d{1,2})\s*[-/.]\s*(\d{1,2})(?![\d])"#)
    static let mdCN = Rx.make(#"\#(NB)(\#(N))\s*月\s*(\#(N))\s*[日号]?"#)
    static let mdDot = Rx.make(#"(?<![\d.])(\d{1,2})\.(\d{1,2})\s*[日号](?![\d])"#)
    static let mdSlash = Rx.make(#"(?<![\d/.\-])(\d{1,2})\s*/\s*(\d{1,2})(?![\d/])"#)
    static let monthRelDay = Rx.make(#"(下个月|下月|本月|这个月|这月|该月|上个月|上月)\s*(\#(N))\s*[日号]"#)
    static let monthEdge = Rx.make(#"(下个|下|上个|上|本|这个|这|该)?\s*(月底|月末|月尾|月初|月头|月中旬|月中)"#)

    /// "过十分钟" / "再过半小时": relative to now, without a trailing 后.
    static let offGuo = Rx.make(#"(?:再)?过\s*(?:(\#(N))|(半))\s*个?\s*(小时|钟头|分钟|天)(?!前|之前)(?:\s*(?:之后|以后|后))?"#)
    static let offHalf = Rx.make(#"半\s*个?\s*(小时|钟头)\s*(?:之后|以后|过后|后)"#)
    static let offNHalf = Rx.make(#"\#(NB)(\#(N))\s*个半\s*(小时|钟头)\s*(?:之后|以后|过后|后)"#)
    static let offHM = Rx.make(#"\#(NB)(\#(N))\s*个?\s*(?:小时|钟头)\s*(?:(\#(N))|(半))\s*(?:分钟|分)?\s*(?:之后|以后|过后|后)"#)
    static let offQuarter = Rx.make(#"一刻钟\s*(?:之后|以后|过后|后)"#)
    static let offN = Rx.make(#"\#(NB)(\#(N))\s*个?\s*(小时|钟头|分钟|秒钟|秒|天|日|周|星期|礼拜|月|年)\s*(?:之后|以后|过后|后)"#)

    /// "周六日" (Saturday and Sunday) is read as Saturday.
    static let weekday = Rx.make(#"(下下个?|下个?|上上个?|上个?|这个?|本|该)?\s*(?:周|星期|礼拜)\s*([一二三四五六日天]|[1-7](?![0-9]))(?:(?<=六)[日天])?"#)
    static let weekend = Rx.make(#"(下下个?|下个?|上个?|这个?|本)?\s*周末"#)
    static let weekGen = Rx.make(#"(下下个?|下个?|上个?|这个?|本)\s*(?:周|星期|礼拜)(?![一二三四五六日天末1-7])"#)

    static let relDay = Rx.make(#"(大后天|后天|明天|明日|今天|今日|昨天|昨日|大前天|前天|(?:今晚|今夜|今早|今晨|明晚|明早|明晨|昨晚)(?:上|间)?)"#)
    static let dom = Rx.make(#"\#(NB)(?<![0-9零〇一二两三四五六七八九十百]月)(\#(N))\s*[日号](?![线楼院门口座馆厅室车机箱柜房仓库宿舍程常记期用报本语游内])"#)

    static let clockColon = Rx.make(#"(?<![\d:.])(\d{1,2}):(\d{2})(?::\d{2})?(?![\d:])(?:\s*(a\.?m\.?|p\.?m\.?)(?![a-z]))?"#, ci: true)
    static let clockApm = Rx.make(#"(?<![\d:.])(\d{1,2})\s*(a\.?m\.?|p\.?m\.?)(?![a-z])"#, ci: true)
    static let clockDian = Rx.make(#"(?<!第)\#(NB)(\#(N))\s*点钟?(?![儿点击名餐菜评赞心])(?:\s*(半|整|一刻|三刻|(?:零|〇)?(\#(N))(?:\s*分(?!钟)|(?![个人位份条本张次件页道题节门科周天号岁元块分]))))?"#)

    static let period = Rx.make(#"(凌晨|清晨|一大早|大清早|清早|一早|早晨|早上|早间|上午|午前|中午|正午|午间|下午|午后|傍晚|晚上|晚间|夜里|夜晚|夜间|半夜|深夜)"#)
    static let periodShort = Rx.make(#"(早|晚)(?=\s*(?:\#(N))\s*(?:点|:))"#)

    static let deadlineKeyword = Rx.make(#"(截止日期|截止时间|截止|截至|最晚|最迟|不晚于|\bdeadline\b|\bddl\b|\bdue\b)(?:\s*(?:到|于|是|在|为|:))?"#, ci: true)
    static let beforeWord = Rx.make(#"(之前|以前|前)"#)
    static let fillerAfter = Rx.make(#"^\s*(左右|前后|上下|以后|之后)"#)
    static let fillerBefore = Rx.make(#"(大概|大约|差不多|约|在|于|到|至|从|由|自)\s*$"#)
}

enum Tokenizer {
    // swiftlint:disable:next function_body_length
    static func tokenize(_ text: String) -> [Tok] {
        let ns = text as NSString
        var toks: [Tok] = []
        var claimed: [NSRange] = []

        func isFree(_ r: NSRange) -> Bool { !claimed.contains { $0.overlaps(r) } }
        @discardableResult
        func add(_ kinds: [Tok.Kind], _ r: NSRange) -> Bool {
            guard isFree(r) else { return false }
            claimed.append(r)
            for k in kinds { toks.append(Tok(kind: k, range: r)) }
            return true
        }
        func group(_ m: NSTextCheckingResult, _ i: Int) -> String? {
            guard i < m.numberOfRanges else { return nil }
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        func number(_ m: NSTextCheckingResult, _ i: Int) -> Int? {
            group(m, i).flatMap { ChineseNumber.parse($0) }
        }
        /// Visits matches left to right. A match the body rejects (returns false) restarts the search one character
        /// later, so a rejected overlap can never shadow a valid match that begins inside it.
        func scan(_ re: NSRegularExpression, _ body: (NSTextCheckingResult) -> Bool) {
            var loc = 0
            while loc < ns.length {
                let range = NSRange(location: loc, length: ns.length - loc)
                guard let m = re.firstMatch(in: text, options: [.withTransparentBounds, .withoutAnchoringBounds], range: range) else { break }
                if body(m), m.range.length > 0 {
                    loc = m.range.end
                } else {
                    loc = m.range.location + 1
                }
            }
        }

        // 1. Absolute dates -------------------------------------------------------------
        scan(Pat.ymdCN) { m in
            guard let y = number(m, 1), let mo = number(m, 2), let d = number(m, 3), validDate(y, mo, d) else { return false }
            return add([.absDate(y: y, m: mo, d: d)], m.range)
        }
        scan(Pat.ymdSep) { m in
            guard let y = number(m, 1), let mo = number(m, 2), let d = number(m, 3), validDate(y, mo, d) else { return false }
            return add([.absDate(y: y, m: mo, d: d)], m.range)
        }
        scan(Pat.mdCN) { m in
            guard let mo = number(m, 1), let d = number(m, 2), validDate(nil, mo, d) else { return false }
            return add([.absDate(y: nil, m: mo, d: d)], m.range)
        }
        scan(Pat.mdDot) { m in
            guard let mo = number(m, 1), let d = number(m, 2), validDate(nil, mo, d) else { return false }
            return add([.absDate(y: nil, m: mo, d: d)], m.range)
        }
        scan(Pat.mdSlash) { m in
            guard let mo = number(m, 1), let d = number(m, 2), validDate(nil, mo, d) else { return false }
            return add([.absDate(y: nil, m: mo, d: d)], m.range)
        }

        // 2. Month relative -------------------------------------------------------------
        scan(Pat.monthRelDay) { m in
            guard let d = number(m, 2), (1...31).contains(d) else { return false }
            return add([.monthDay(monthOffset: monthOffset(group(m, 1)) ?? 0, day: d)], m.range)
        }
        scan(Pat.monthEdge) { m in
            guard let word = group(m, 2) else { return false }
            let edge: MonthEdge
            switch word {
            case "月底", "月末", "月尾": edge = .end
            case "月初", "月头": edge = .start
            default: edge = .mid
            }
            return add([.monthEdge(monthOffset: monthOffset(group(m, 1)), edge: edge)], m.range)
        }

        // 3. Offsets ("半小时后", "3天后", "过十分钟") ---------------------------------------------
        // "过十分钟" first, so its "十分钟" is not claimed as an offset that lacks 后.
        scan(Pat.offGuo) { m in
            guard let unitWord = group(m, 3) else { return false }
            if group(m, 2) != nil {
                guard unitWord == "小时" || unitWord == "钟头" else { return false }
                return add([.offset(unit: .minute, amount: 30)], m.range)
            }
            guard let n = number(m, 1) else { return false }
            switch unitWord {
            case "小时", "钟头": return add([.offset(unit: .hour, amount: Double(n))], m.range)
            case "分钟": return add([.offset(unit: .minute, amount: Double(n))], m.range)
            default: return add([.offset(unit: .day, amount: Double(n))], m.range)
            }
        }
        // "一个半小时后" must be claimed before its tail "半小时后".
        scan(Pat.offNHalf) { m in
            guard let n = number(m, 1) else { return false }
            return add([.offset(unit: .minute, amount: Double(n) * 60 + 30)], m.range)
        }
        scan(Pat.offHalf) { m in
            add([.offset(unit: .minute, amount: 30)], m.range)
        }
        scan(Pat.offHM) { m in
            guard let h = number(m, 1) else { return false }
            let minutes = group(m, 3) != nil ? 30 : (number(m, 2) ?? 0)
            guard minutes < 60 else { return false }
            return add([.offset(unit: .minute, amount: Double(h * 60 + minutes))], m.range)
        }
        scan(Pat.offQuarter) { m in
            add([.offset(unit: .minute, amount: 15)], m.range)
        }
        scan(Pat.offN) { m in
            guard let n = number(m, 1), let unitWord = group(m, 2) else { return false }
            let unit: OffsetUnit
            switch unitWord {
            case "小时", "钟头": unit = .hour
            case "分钟": unit = .minute
            case "秒钟", "秒": unit = .second
            case "天", "日": unit = .day
            case "周", "星期", "礼拜": unit = .week
            case "月": unit = .month
            default: unit = .year
            }
            return add([.offset(unit: unit, amount: Double(n))], m.range)
        }

        // 4. Weekdays ---------------------------------------------------------------------
        scan(Pat.weekday) { m in
            guard let w = group(m, 2), let iso = isoWeekday(w) else { return false }
            return add([.weekday(weekOffset: weekOffset(group(m, 1)), iso: iso)], m.range)
        }
        scan(Pat.weekend) { m in
            add([.weekend(weekOffset: weekOffset(group(m, 1)))], m.range)
        }
        scan(Pat.weekGen) { m in
            guard let wo = weekOffset(group(m, 1)) else { return false }
            return add([.weekGeneric(weekOffset: wo)], m.range)
        }

        // 5. Relative days (and 今晚 / 明早 style combos) ---------------------------------------
        scan(Pat.relDay) { m in
            guard let w = group(m, 1), let info = relDayInfo(w) else { return false }
            var kinds: [Tok.Kind] = [.relDay(info.offset)]
            if let p = info.period { kinds.append(.period(p)) }
            return add(kinds, m.range)
        }

        // 6. Day of month ("30号") -----------------------------------------------------------
        scan(Pat.dom) { m in
            guard let d = number(m, 1), (1...31).contains(d) else { return false }
            return add([.dayOfMonth(d)], m.range)
        }

        // 7. Clock times ----------------------------------------------------------------------
        scan(Pat.clockColon) { m in
            guard let hText = group(m, 1), let mText = group(m, 2),
                  let h = Int(hText), let mi = Int(mText), h <= 24, mi <= 59, h < 24 || mi == 0 else { return false }
            let mer: Meridiem? = group(m, 3).map { $0.lowercased().hasPrefix("a") ? .am : .pm }
            let leadingZero = hText.count == 2 && hText.hasPrefix("0")
            let strict = mer == nil && (h == 0 || h >= 10 || leadingZero)
            return add([.clock(hour: h, minute: mi, meridiem: mer, strict24: strict)], m.range)
        }
        scan(Pat.clockApm) { m in
            guard let hText = group(m, 1), let h = Int(hText), (1...12).contains(h), let tag = group(m, 2) else { return false }
            return add([.clock(hour: h, minute: 0, meridiem: tag.lowercased().hasPrefix("a") ? .am : .pm, strict24: false)], m.range)
        }
        scan(Pat.clockDian) { m in
            guard let hText = group(m, 1), let h = ChineseNumber.parse(hText), h <= 24 else { return false }
            if isColloquialYiDian(ns, m.range, hourText: hText) { return false }
            var mi = 0
            if let suffix = group(m, 2) {
                switch suffix {
                case "半": mi = 30
                case "整": mi = 0
                case "一刻": mi = 15
                case "三刻": mi = 45
                default: mi = number(m, 3) ?? 0
                }
            }
            guard mi <= 59, h < 24 || mi == 0 else { return false }
            let leadingZero = hText.count == 2 && hText.hasPrefix("0")
            return add([.clock(hour: h, minute: mi, meridiem: nil, strict24: h == 0 || h >= 13 || leadingZero)], m.range)
        }

        // 8. Period words -----------------------------------------------------------------------
        scan(Pat.period) { m in
            guard let w = group(m, 1) else { return false }
            return add([.period(periodOf(w))], m.range)
        }
        scan(Pat.periodShort) { m in
            guard let w = group(m, 1) else { return false }
            return add([.period(periodOf(w))], m.range)
        }

        // 9. Deadline markers ---------------------------------------------------------------------
        scan(Pat.deadlineKeyword) { m in
            add([.deadlineMarker], m.range)
        }
        scan(Pat.beforeWord) { m in
            guard isFree(m.range) else { return false }
            var pos = m.range.location
            while pos > 0, ns.character(at: pos - 1) == 0x20 { pos -= 1 }
            guard toks.contains(where: { ($0.isDate || $0.isClock) && $0.range.end == pos }) else { return false }
            return add([.deadlineMarker], m.range)
        }

        // 10. Approximation words around date/time tokens ----------------------------------------------
        let snapshot = toks.filter { $0.isDate || $0.isClock || $0.isPeriod }
        for t in snapshot {
            let afterStart = t.range.end
            let afterLen = min(4, ns.length - afterStart)
            if afterLen > 0 {
                let sub = ns.substring(with: NSRange(location: afterStart, length: afterLen)) as NSString
                if let m = Pat.fillerAfter.firstMatch(in: sub as String, range: NSRange(location: 0, length: sub.length)) {
                    add([.filler], NSRange(location: afterStart + m.range.location, length: m.range.length))
                }
            }
            let beforeEnd = t.range.location
            let beforeStart = max(0, beforeEnd - 6)
            if beforeEnd > beforeStart {
                let sub = ns.substring(with: NSRange(location: beforeStart, length: beforeEnd - beforeStart)) as NSString
                if let m = Pat.fillerBefore.firstMatch(in: sub as String, range: NSRange(location: 0, length: sub.length)) {
                    add([.filler], NSRange(location: beforeStart + m.range.location, length: m.range.length))
                }
            }
        }

        toks.sort { $0.range.location < $1.range.location }

        // 11. Time ranges ("19:00-21:00", "下午3点到5点"): only the start counts ------------------------------
        let clockIdx = toks.indices.filter { toks[$0].isClock }
        for (a, b) in zip(clockIdx, clockIdx.dropFirst()) {
            let gapStart = toks[a].range.end
            let gapLen = toks[b].range.location - gapStart
            guard gapLen >= 0, gapLen <= 8 else { continue }
            var gap = ns.substring(with: NSRange(location: gapStart, length: gapLen))
            gap = gap.replacingOccurrences(of: Pat.period.pattern, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            guard ["-", "~", "—", "–", "到", "至"].contains(gap) else { continue }
            // The whole "到5点" tail (connector included) is dropped from the title.
            let secondEnd = toks[b].range.end
            for i in toks.indices where toks[i].isPeriod && toks[i].range.location >= gapStart && toks[i].range.location < toks[b].range.location {
                toks[i].kind = .filler
            }
            toks[b].kind = .rangeEnd
            toks[b].range = NSRange(location: gapStart, length: secondEnd - gapStart)
        }

        // Date ranges ("5月1号到5月5号", "下周一到周五"): only the start counts as well.
        let dateIdx = toks.indices.filter { toks[$0].isDate }
        for (a, b) in zip(dateIdx, dateIdx.dropFirst()) {
            let gapStart = toks[a].range.end
            let gapLen = toks[b].range.location - gapStart
            guard gapLen >= 0, gapLen <= 4 else { continue }
            let gap = ns.substring(with: NSRange(location: gapStart, length: gapLen)).trimmingCharacters(in: .whitespaces)
            guard ["-", "~", "—", "–", "到", "至"].contains(gap) else { continue }
            let secondEnd = toks[b].range.end
            toks[b].kind = .rangeEnd
            toks[b].range = NSRange(location: gapStart, length: secondEnd - gapStart)
        }
        return toks
    }

    // MARK: - helpers

    private static func daysIn(_ month: Int, year: Int?) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2:
            guard let y = year else { return 29 }
            return ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0) ? 29 : 28
        default: return 0
        }
    }

    private static func validDate(_ year: Int?, _ month: Int, _ day: Int) -> Bool {
        (1...12).contains(month) && day >= 1 && day <= daysIn(month, year: year)
    }

    private static func weekOffset(_ prefix: String?) -> Int? {
        guard let p = prefix, !p.isEmpty else { return nil }
        if p.hasPrefix("下下") { return 2 }
        if p.hasPrefix("下") { return 1 }
        if p.hasPrefix("上上") { return -2 }
        if p.hasPrefix("上") { return -1 }
        return 0
    }

    private static func monthOffset(_ prefix: String?) -> Int? {
        guard let p = prefix, !p.isEmpty else { return nil }
        if p.hasPrefix("下") { return 1 }
        if p.hasPrefix("上") { return -1 }
        return 0
    }

    private static func isoWeekday(_ s: String) -> Int? {
        switch s {
        case "一", "1": return 1
        case "二", "2": return 2
        case "三", "3": return 3
        case "四", "4": return 4
        case "五", "5": return 5
        case "六", "6": return 6
        case "日", "天", "7": return 7
        default: return nil
        }
    }

    private static func relDayInfo(_ w: String) -> (offset: Int, period: Period?)? {
        if w.hasPrefix("大后天") { return (3, nil) }
        if w.hasPrefix("后天") { return (2, nil) }
        if w.hasPrefix("明天") || w.hasPrefix("明日") { return (1, nil) }
        if w.hasPrefix("今天") || w.hasPrefix("今日") { return (0, nil) }
        if w.hasPrefix("昨天") || w.hasPrefix("昨日") { return (-1, nil) }
        if w.hasPrefix("大前天") { return (-3, nil) }
        if w.hasPrefix("前天") { return (-2, nil) }
        if w.hasPrefix("今晚") || w.hasPrefix("今夜") { return (0, .evening) }
        if w.hasPrefix("今早") || w.hasPrefix("今晨") { return (0, .morning) }
        if w.hasPrefix("明晚") { return (1, .evening) }
        if w.hasPrefix("明早") || w.hasPrefix("明晨") { return (1, .morning) }
        if w.hasPrefix("昨晚") { return (-1, .evening) }
        return nil
    }

    private static func periodOf(_ w: String) -> Period {
        switch w {
        case "凌晨": return .dawn
        case "清晨", "早晨", "早上", "早间", "一大早", "大清早", "清早", "一早", "早": return .morning
        case "上午", "午前": return .forenoon
        case "中午", "正午", "午间": return .noon
        case "下午", "午后": return .afternoon
        case "傍晚": return .dusk
        default: return .evening
        }
    }

    private static func char(_ ns: NSString, _ i: Int) -> Character? {
        guard i >= 0, i < ns.length, let u = UnicodeScalar(ns.character(at: i)) else { return nil }
        return Character(u)
    }

    /// "我有一点累" / "早一点" / "好一点" are not 1 o'clock.
    private static func isColloquialYiDian(_ ns: NSString, _ r: NSRange, hourText: String) -> Bool {
        guard hourText == "一" else { return false }
        let badBefore: Set<Character> = ["有", "差", "早", "晚", "多", "少", "快", "慢", "好", "再", "稍", "过", "这", "那", "每",
                                         "就", "只", "仅", "贪", "懒", "大", "小", "高", "低", "远", "近", "长", "短", "深", "浅", "重", "轻", "难", "易"]
        let badAfter: Set<Character> = ["也", "都", "不", "没", "累", "困", "饿", "冷", "热", "怕", "慢", "快", "多", "少", "贵",
                                        "便", "小", "大", "难", "痛", "疼", "晕", "烦", "吃", "喝", "东", "事", "了"]
        if let b = char(ns, r.location - 1), badBefore.contains(b) { return true }
        if let a = char(ns, r.end), badAfter.contains(a) { return true }
        return false
    }
}
