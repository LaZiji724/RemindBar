import Foundation

/// Resolves the tokens of ONE event into a concrete moment, relative to `ctx.now`.
enum DateTimeParser {
    struct Output {
        var event: ParsedEvent
        /// Start of the day the event landed on; the next segment of the same utterance inherits it.
        var dateStart: Date?
    }

    private struct DateCand {
        var date: Date
        var priority: Int
        var bareWeekdayToday = false
    }

    /// "每周一", "每天", "每晚"…: recurring reminders are not supported yet, so the phrase is kept in the title and flagged.
    private static let recurrence = Rx.make(#"(每个?(?:周|星期|礼拜)[一二三四五六日天]|每个?(?:周|星期|礼拜|月|年|天|日|晚上|早上|早晨|中午|下午|晚|早)|天天|工作日|每逢[^，。,;；\s]{1,4}|每隔[^，。,;；\s]{1,4})"#)
    private static let leftover = Rx.make(#"(\d+\s*(?:[点时月:]|[号日](?![线楼院门口座馆厅室车机箱柜房仓库宿舍程常记期用报本语游内]))|[周星礼][期拜]?[一二三四五六日天]|今天|明天|后天|昨天|下周|本周|这周|上午|下午|晚上|早上|中午|凌晨|傍晚|月底|月初)"#)

    static func parse(segment: String, ctx: ParseContext, inheritDate: Date?) -> Output {
        let text = TextNormalizer.normalize(segment)
        let toks = Tokenizer.tokenize(text)
        return resolve(original: segment, text: text, toks: toks, ctx: ctx, inheritDate: inheritDate)
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private static func resolve(original: String, text: String, toks: [Tok], ctx: ParseContext, inheritDate: Date?) -> Output {
        let cal = ctx.calendar
        let now = ctx.now
        let today = cal.startOfDay(for: now)
        var flags: ParseFlags = []

        // MARK: calendar helpers
        func day(_ n: Int, _ d: Date) -> Date { cal.date(byAdding: .day, value: n, to: d) ?? d }
        func at(_ d: Date, _ h: Int, _ m: Int) -> Date {
            if h >= 24 { return cal.date(bySettingHour: 0, minute: m, second: 0, of: day(1, d)) ?? d }
            return cal.date(bySettingHour: h, minute: m, second: 0, of: d) ?? d
        }
        func isoWeekday(_ d: Date) -> Int { (cal.component(.weekday, from: d) + 5) % 7 + 1 }
        func weekStart(_ d: Date) -> Date { day(-(isoWeekday(d) - 1), cal.startOfDay(for: d)) }
        func firstOfMonth(_ d: Date) -> Date { cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d }
        func monthStart(offset: Int) -> Date { cal.date(byAdding: .month, value: offset, to: firstOfMonth(today)) ?? today }
        func build(_ y: Int, _ m: Int, _ d: Int) -> Date? {
            var c = DateComponents()
            c.year = y; c.month = m; c.day = d; c.hour = 0; c.minute = 0; c.second = 0
            guard let date = cal.date(from: c) else { return nil }
            let back = cal.dateComponents([.year, .month, .day], from: date)
            return (back.year == y && back.month == m && back.day == d) ? date : nil
        }
        func ym(_ d: Date) -> (Int, Int) {
            let c = cal.dateComponents([.year, .month], from: d)
            return (c.year ?? 1970, c.month ?? 1)
        }

        // MARK: date candidates
        var cands: [DateCand] = []
        for t in toks where t.isDate {
            switch t.kind {
            case .absDate(let y, let m, let d):
                if let y {
                    if let dt = build(y, m, d) { cands.append(DateCand(date: dt, priority: 0)) }
                } else {
                    let cy = cal.component(.year, from: today)
                    if let thisYear = build(cy, m, d) {
                        if thisYear >= day(-7, today) {
                            cands.append(DateCand(date: thisYear, priority: 0))
                        } else if let next = build(cy + 1, m, d) {
                            cands.append(DateCand(date: next, priority: 0))
                        } else {
                            cands.append(DateCand(date: thisYear, priority: 0))
                        }
                    } else if let next = build(cy + 1, m, d) {
                        cands.append(DateCand(date: next, priority: 0))
                    }
                }
            case .monthDay(let mo, let d):
                let (y, m) = ym(monthStart(offset: mo))
                if let dt = build(y, m, d) { cands.append(DateCand(date: dt, priority: 1)) }
            case .dayOfMonth(let d):
                for i in 0..<13 {
                    let (y, m) = ym(monthStart(offset: i))
                    if let dt = build(y, m, d), dt >= today {
                        cands.append(DateCand(date: dt, priority: 2))
                        break
                    }
                }
            case .monthEdge(let mo, let edge):
                switch edge {
                case .end:
                    let base = monthStart(offset: mo ?? 0)
                    let (y, m) = ym(base)
                    if let r = cal.range(of: .day, in: .month, for: base), let dt = build(y, m, r.count) {
                        cands.append(DateCand(date: dt, priority: 3))
                    }
                case .start:
                    cands.append(DateCand(date: monthStart(offset: mo ?? 1), priority: 3))
                case .mid:
                    var dt = day(14, monthStart(offset: mo ?? 0))
                    if mo == nil, dt < today { dt = day(14, monthStart(offset: 1)) }
                    cands.append(DateCand(date: dt, priority: 3))
                }
            case .weekday(let wo, let iso):
                let ws = weekStart(today)
                if let wo {
                    cands.append(DateCand(date: day(wo * 7 + iso - 1, ws), priority: 4))
                } else {
                    var d = day(iso - 1, ws)
                    if d < today { d = day(7, d) }
                    cands.append(DateCand(date: d, priority: 4, bareWeekdayToday: d == today))
                }
            case .weekend(let wo):
                let ws = weekStart(today)
                flags.insert(.weekGeneric)
                if let wo {
                    cands.append(DateCand(date: day(wo * 7 + 5, ws), priority: 5))
                } else {
                    cands.append(DateCand(date: isoWeekday(today) >= 6 ? today : day(5, ws), priority: 5))
                }
            case .weekGeneric(let wo):
                flags.insert(.weekGeneric)
                cands.append(DateCand(date: day(wo * 7, weekStart(today)), priority: 6))
            case .relDay(let n):
                cands.append(DateCand(date: day(n, today), priority: 7))
            default:
                break
            }
        }

        // MARK: offsets
        var exact: (unit: OffsetUnit, amount: Double)?
        for t in toks {
            guard case .offset(let unit, let amount) = t.kind else { continue }
            switch unit {
            case .second, .minute, .hour:
                if exact == nil { exact = (unit, amount) } else { flags.insert(.conflict) }
            case .day, .week, .month, .year:
                let n = Int(amount.rounded())
                let d: Date
                switch unit {
                case .day: d = day(n, today)
                case .week: d = day(7 * n, today)
                case .month: d = cal.date(byAdding: .month, value: n, to: today) ?? today
                default: d = cal.date(byAdding: .year, value: n, to: today) ?? today
                }
                cands.append(DateCand(date: d, priority: 5))
            }
        }

        if Set(cands.map { $0.date }).count > 1 { flags.insert(.conflict) }
        let chosen = cands.min { $0.priority < $1.priority }

        // MARK: clock / period / deadline marker
        var clockCount = 0
        var clock: (hour: Int, minute: Int, meridiem: Meridiem?, strict: Bool, loc: Int)?
        var periods: [(period: Period, loc: Int)] = []
        var isDeadline = false
        for t in toks {
            switch t.kind {
            case .clock(let h, let m, let mer, let strict):
                clockCount += 1
                if clock == nil { clock = (h, m, mer, strict, t.range.location) }
            case .period(let p):
                periods.append((p, t.range.location))
            case .deadlineMarker:
                isDeadline = true
            default:
                break
            }
        }
        if clockCount > 1 { flags.insert(.conflict) }
        var period: Period?
        if let c = clock {
            period = periods.last(where: { $0.loc < c.loc })?.period ?? periods.first(where: { $0.loc > c.loc })?.period
        } else {
            period = periods.first?.period
        }

        let hasDateTime = !cands.isEmpty || clock != nil || period != nil || exact != nil

        // MARK: compose
        var due: Date?
        var alt: Date?
        var explicitDate = false
        var explicitTime = false
        var ambiguous: Int?

        if hasDateTime {
            if let e = exact {
                let seconds: Double
                switch e.unit {
                case .second: seconds = e.amount
                case .minute: seconds = e.amount * 60
                default: seconds = e.amount * 3600
                }
                let target = now.addingTimeInterval(seconds)
                let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: target)
                due = cal.date(from: comps) ?? target
                explicitTime = true
                if !cands.isEmpty || clock != nil { flags.insert(.conflict) }
            } else {
                var start = today
                if let c = chosen {
                    start = c.date
                    explicitDate = true
                } else if let inherited = inheritDate, clock != nil || period != nil {
                    start = inherited
                    explicitDate = true
                    flags.insert(.dateInherited)
                }

                var hour24: Int?
                var minute = 0
                var shift = 0
                if let c = clock {
                    explicitTime = true
                    minute = c.minute
                    if let mer = c.meridiem {
                        switch mer {
                        case .am: hour24 = c.hour == 12 ? 0 : c.hour
                        case .pm: hour24 = c.hour < 12 ? c.hour + 12 : c.hour
                        }
                    } else if let p = period {
                        let r = applyPeriod(p, hour: c.hour)
                        hour24 = r.hour
                        shift = r.dayShift
                    } else if c.strict {
                        hour24 = c.hour
                    } else {
                        ambiguous = c.hour
                    }
                } else if let p = period {
                    let dt = defaultTime(for: p)
                    hour24 = dt.hour
                    minute = dt.minute
                    flags.insert(.periodDefaultTime)
                } else {
                    hour24 = isDeadline ? ctx.deadlineHour : ctx.defaultHour
                    minute = isDeadline ? ctx.deadlineMinute : ctx.defaultMinute
                    flags.insert(.defaultTime)
                }

                if let amb = ambiguous {
                    flags.insert(.ampmInferred)
                    let options: [Date] = amb == 12
                        ? [at(start, 12, minute), at(start, 24, minute)]
                        : [at(start, amb, minute), at(start, amb + 12, minute)]
                    let startIsToday = cal.isDate(start, inSameDayAs: today)
                    let heuristic = (amb != 12 && amb <= 5) ? 1 : 0
                    if startIsToday, let upcoming = options.filter({ $0 > now }).min() {
                        due = upcoming
                        let other = options.first { $0 != upcoming } ?? upcoming
                        alt = other > now ? other : day(1, other)
                    } else if startIsToday && !explicitDate {
                        // Both readings have passed today: tomorrow, using the waking-hours reading.
                        let tomorrow = options.map { day(1, $0) }
                        due = tomorrow[heuristic]
                        alt = tomorrow[1 - heuristic]
                        flags.insert(.rolledForward)
                    } else {
                        due = options[heuristic]
                        alt = options[1 - heuristic]
                    }
                } else if let h = hour24 {
                    due = at(shift == 0 ? start : day(shift, start), h, minute)
                }

                if let d = due {
                    if let c = chosen, c.bareWeekdayToday, d <= now {
                        // "周一" typed on a Monday after the time has passed means next week.
                        due = day(7, d)
                        alt = alt.map { day(7, $0) }
                    } else if !explicitDate, ambiguous == nil, d <= now {
                        due = day(1, d)
                        flags.insert(.rolledForward)
                    } else if explicitDate, !explicitTime, period == nil, ambiguous == nil, d < now, cal.isDate(d, inSameDayAs: today) {
                        // "今天交作业" typed in the evening: the default time has passed, use the end of today.
                        due = at(today, ctx.deadlineHour, ctx.deadlineMinute)
                    }
                }
            }
            if let d = due, d < now {
                flags.insert(.past)
                if explicitDate, cal.isDate(d, inSameDayAs: today) { alt = day(1, d) }
            }
        } else {
            flags.insert(.noDateTime)
        }

        // MARK: title
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let recurrenceRanges = recurrence.matches(in: text, range: whole).map { $0.range }
        if !recurrenceRanges.isEmpty { flags.insert(.recurrenceMentioned) }
        // Tokens that are part of "每周一" stay in the title so the user can still see what was meant.
        let removable = toks.map { $0.range }.filter { r in !recurrenceRanges.contains { $0.overlaps(r) } }
        var title = TitleExtractor.extract(from: text, removing: removable)
        if title.isEmpty {
            flags.insert(.emptyTitle)
            title = "提醒"
        } else if leftover.firstMatch(in: title, range: NSRange(location: 0, length: (title as NSString).length)) != nil {
            flags.insert(.leftoverDateWords)
        }

        // MARK: confidence
        var confidence: ParseConfidence = .high
        let mediumFlags: ParseFlags = [.ampmInferred, .defaultTime, .periodDefaultTime, .rolledForward, .past,
                                       .weekGeneric, .dateInherited, .recurrenceMentioned]
        let lowFlags: ParseFlags = [.conflict, .leftoverDateWords, .emptyTitle, .noDateTime]
        if !flags.isDisjoint(with: mediumFlags) { confidence = .medium }
        if !flags.isDisjoint(with: lowFlags) { confidence = .low }

        let event = ParsedEvent(title: title, due: due, hasExplicitDate: explicitDate, hasExplicitTime: explicitTime,
                                isDeadline: isDeadline, flags: flags, alternative: alt, confidence: confidence,
                                sourceText: original)
        return Output(event: event, dateStart: due.map { cal.startOfDay(for: $0) })
    }

    // MARK: - period handling

    /// Converts a 12-hour reading plus a period word into a 24-hour hour (and a day shift for small-hours-of-the-night).
    private static func applyPeriod(_ p: Period, hour h: Int) -> (hour: Int, dayShift: Int) {
        if h == 0 || h >= 13 { return (h, 0) }
        switch p {
        case .dawn: return (h == 12 ? 0 : h, 0)
        case .morning, .forenoon: return (h, 0)
        case .noon: return (h >= 10 ? h : h + 12, 0)
        case .afternoon, .dusk: return (h == 12 ? 12 : h + 12, 0)
        case .evening:
            if h == 12 { return (0, 1) }
            if h <= 4 { return (h, 1) }
            return (h + 12, 0)
        }
    }

    private static func defaultTime(for p: Period) -> (hour: Int, minute: Int) {
        switch p {
        case .dawn: return (6, 0)
        case .morning: return (8, 0)
        case .forenoon: return (9, 0)
        case .noon: return (12, 0)
        case .afternoon: return (15, 0)
        case .dusk: return (18, 0)
        case .evening: return (20, 0)
        }
    }
}
