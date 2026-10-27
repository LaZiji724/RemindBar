import Foundation
import RemindCore

private struct Case {
    let input: String
    let title: String
    let due: String?
    var has: ParseFlags = []
    var hasNot: ParseFlags = []
    var conf: ParseConfidence?
    var alt: String?
    var deadline: Bool?
}

private func c(_ input: String, _ title: String, _ due: String?,
               has: ParseFlags = [], hasNot: ParseFlags = [], conf: ParseConfidence? = nil,
               alt: String? = nil, deadline: Bool? = nil) -> Case {
    Case(input: input, title: title, due: due, has: has, hasNot: hasNot, conf: conf, alt: alt, deadline: deadline)
}

enum ParserTests {
    static func run(_ h: Harness) {
        h.suite = "parser"
        single(h)
        multi(h)
        equivalentFormats(h)
    }

    // MARK: single events

    private static let cases: [Case] = [
        // The user's own examples (now = Mon 2026-10-26 21:05)
        c("去睡觉，今晚19点", "去睡觉", "2026-10-26 19:00", has: [.past], conf: .medium, alt: "2026-10-27 19:00"),
        c("去睡觉，今晚23点", "去睡觉", "2026-10-26 23:00", hasNot: [.past], conf: .high),
        c("今晚11点去睡觉", "去睡觉", "2026-10-26 23:00", conf: .high),
        c("19:00 开会", "开会", "2026-10-27 19:00", has: [.rolledForward]),
        c("19：00 开会", "开会", "2026-10-27 19:00", has: [.rolledForward]),
        c("下午7点开会", "开会", "2026-10-27 19:00", has: [.rolledForward]),
        c("明天下午7点开会", "开会", "2026-10-27 19:00", conf: .high),
        c("明天19:00开会", "开会", "2026-10-27 19:00", conf: .high),
        c("明天晚上七点半吃饭", "吃饭", "2026-10-27 19:30", conf: .high),
        c("明晚8点打球", "打球", "2026-10-27 20:00", conf: .high),
        c("明早8点跑步", "跑步", "2026-10-27 08:00", conf: .high),
        c("明天早上八点一刻起床", "起床", "2026-10-27 08:15", conf: .high),
        c("后天中午12点半吃饭", "吃饭", "2026-10-28 12:30"),
        c("大后天凌晨2点起床", "起床", "2026-10-29 02:00"),
        c("今晚12点睡觉", "睡觉", "2026-10-27 00:00", conf: .high),
        c("今天晚上十点半睡觉", "睡觉", "2026-10-26 22:30"),
        c("明天上午10点考试", "考试", "2026-10-27 10:00", conf: .high),
        // AM/PM inference
        c("明天10点开会", "开会", "2026-10-27 10:00", has: [.ampmInferred], conf: .medium, alt: "2026-10-27 22:00"),
        c("明天3点开会", "开会", "2026-10-27 15:00", has: [.ampmInferred], alt: "2026-10-27 03:00"),
        c("7点起床", "起床", "2026-10-27 07:00", has: [.ampmInferred, .rolledForward], alt: "2026-10-27 19:00"),
        c("10点睡觉", "睡觉", "2026-10-26 22:00", has: [.ampmInferred], alt: "2026-10-27 10:00"),
        c("12点吃饭", "吃饭", "2026-10-27 00:00", has: [.ampmInferred], alt: "2026-10-27 12:00"),
        c("明天8:30 开会", "开会", "2026-10-27 08:30", has: [.ampmInferred], alt: "2026-10-27 20:30"),
        c("明天08:30开会", "开会", "2026-10-27 08:30", hasNot: [.ampmInferred], conf: .high),
        c("明天7pm聚餐", "聚餐", "2026-10-27 19:00", conf: .high),
        c("周五下午3:30开会", "开会", "2026-10-30 15:30", conf: .high),
        c("晚上7点", "提醒", "2026-10-27 19:00", has: [.emptyTitle], conf: .low),
        // Dates
        c("10月30日交报告", "交报告", "2026-10-30 09:00", has: [.defaultTime], conf: .medium),
        c("10月30号 23:59 交作业", "交作业", "2026-10-30 23:59", conf: .high),
        c("2026-11-05 18:30 开会", "开会", "2026-11-05 18:30", conf: .high),
        c("2026年11月5日下午6点半开会", "开会", "2026-11-05 18:30", conf: .high),
        c("11/3 12:00 午饭", "午饭", "2026-11-03 12:00", conf: .high),
        c("30号交房租", "交房租", "2026-10-30 09:00", has: [.defaultTime]),
        c("5号交房租", "交房租", "2026-11-05 09:00"),
        c("月底前交论文", "交论文", "2026-10-31 23:59", deadline: true),
        c("下个月5号开会", "开会", "2026-11-05 09:00"),
        c("二零二六年十一月五号下午六点半开会", "开会", "2026-11-05 18:30", conf: .high),
        c("十月三十日晚上八点", "提醒", "2026-10-30 20:00", has: [.emptyTitle], conf: .low),
        c("10月20日交作业", "交作业", "2026-10-20 09:00", has: [.past, .defaultTime], conf: .medium),
        c("3月5日生日", "生日", "2027-03-05 09:00"),
        c("十二月二十五号下午两点半", "提醒", "2026-12-25 14:30", has: [.emptyTitle], conf: .low),
        // Weekdays
        c("周五前交作业", "交作业", "2026-10-30 23:59", deadline: true),
        c("周五晚上8点健身", "健身", "2026-10-30 20:00", conf: .high),
        c("下周三晚上8点半健身", "健身", "2026-11-04 20:30", conf: .high),
        c("下下周一开会", "开会", "2026-11-09 09:00"),
        c("这周日聚餐", "聚餐", "2026-11-01 09:00"),
        c("周日聚餐", "聚餐", "2026-11-01 09:00"),
        c("周一开会", "开会", "2026-11-02 09:00"),
        c("周末爬山", "爬山", "2026-10-31 09:00", has: [.weekGeneric], conf: .medium),
        c("星期三下午三点上课", "上课", "2026-10-28 15:00", conf: .high),
        c("礼拜三下午三点上课", "上课", "2026-10-28 15:00", conf: .high),
        c("下周交作业", "交作业", "2026-11-02 09:00", has: [.weekGeneric]),
        c("下周三上午十点钟交作业", "交作业", "2026-11-04 10:00", conf: .high),
        // Offsets
        c("半小时后喝水", "喝水", "2026-10-26 21:35", conf: .high),
        c("两小时后开会", "开会", "2026-10-26 23:05"),
        c("一个半小时后关火", "关火", "2026-10-26 22:35"),
        c("10分钟后提醒我关火", "关火", "2026-10-26 21:15"),
        c("3天后交作业", "交作业", "2026-10-29 09:00"),
        c("两周后考试", "考试", "2026-11-09 09:00"),
        c("一个月后续费", "续费", "2026-11-26 09:00"),
        c("3天后晚上8点聚会", "聚会", "2026-10-29 20:00", conf: .high),
        // Deadline semantics
        c("明天之前交作业", "交作业", "2026-10-27 23:59", deadline: true),
        c("截止周五 18:00 提交报告", "提交报告", "2026-10-30 18:00", deadline: true),
        c("ddl 11月3日 实验报告", "实验报告", "2026-11-03 23:59", deadline: true),
        c("今晚十点前把作业交了", "把作业交了", "2026-10-26 22:00", deadline: true),
        // Filler / instruction phrases
        c("提醒我明天下午3点开会", "开会", "2026-10-27 15:00", conf: .high),
        c("记得明晚8点给妈妈打电话", "给妈妈打电话", "2026-10-27 20:00"),
        c("别忘了周五交作业", "交作业", "2026-10-30 09:00"),
        c("明天下午3点开会哦", "开会", "2026-10-27 15:00"),
        c("嗯那个明天下午三点开会", "开会", "2026-10-27 15:00"),
        c("提醒我明天下午三点钟去开会", "去开会", "2026-10-27 15:00"),
        c("那个后天晚上七点半要和同学吃饭", "和同学吃饭", "2026-10-28 19:30"),
        c("明天早上六点起床跑步", "起床跑步", "2026-10-27 06:00", conf: .high),
        c("明天大概晚上8点左右健身", "健身", "2026-10-27 20:00"),
        // Ranges: only the start counts
        c("明天19:00-21:00开会", "开会", "2026-10-27 19:00"),
        c("明天下午3点到5点开会", "开会", "2026-10-27 15:00"),
        // Night-time edge cases
        c("半夜2点起床", "起床", "2026-10-27 02:00"),
        c("明天凌晨12点起床", "起床", "2026-10-27 00:00"),
        c("今天交作业", "交作业", "2026-10-26 23:59", has: [.defaultTime]),
        c("明天", "提醒", "2026-10-27 09:00", has: [.emptyTitle], conf: .low),
        // No usable date/time, or something that must NOT be read as a time
        c("买牛奶", "买牛奶", nil, has: [.noDateTime], conf: .low),
        c("春节回家", "春节回家", nil, has: [.noDateTime], conf: .low),
        c("每天晚上10点吃药", "每天吃药", "2026-10-26 22:00", has: [.recurrenceMentioned], conf: .medium),
        c("每晚10点吃药", "每晚吃药", "2026-10-26 22:00", has: [.recurrenceMentioned], conf: .medium),
        c("每周一早上9点开例会", "每周一开例会", "2026-11-02 09:00", has: [.recurrenceMentioned]),
        c("下周一到周五每天打卡", "每天打卡", "2026-11-02 09:00", has: [.recurrenceMentioned]),
        c("两点开会", "开会", "2026-10-27 14:00", has: [.ampmInferred, .rolledForward], alt: "2026-10-27 02:00"),
        c("后天8点半有课", "有课", "2026-10-28 08:30", has: [.ampmInferred]),
        c("明天零点提醒我", "提醒", "2026-10-27 00:00", has: [.emptyTitle]),
        c("这个月底交房租", "交房租", "2026-10-31 09:00"),
        c("下个月底交论文", "交论文", "2026-11-30 09:00"),
        c("5月1号到5月5号放假", "放假", "2027-05-01 09:00", hasNot: [.conflict]),
        c("再过十分钟提醒我", "提醒", "2026-10-26 21:15", has: [.emptyTitle]),
        c("过半小时关火", "关火", "2026-10-26 21:35"),
        c("提醒我二十分钟后去拿快递", "去拿快递", "2026-10-26 21:25", conf: .high),
        c("明天一早起床", "起床", "2026-10-27 08:00", has: [.periodDefaultTime]),
        c("周六日加班", "加班", "2026-10-31 09:00"),
        c("下周五截止的高数作业", "高数作业", "2026-11-06 23:59", deadline: true),
        c("周三之前提交作业", "提交作业", "2026-10-28 23:59", deadline: true),
        c("晚上 8 点 半 健身", "健身", "2026-10-27 20:30"),
        c("今晚1点关机", "关机", "2026-10-27 01:00"),
        c("明天下午3点，开会。", "开会", "2026-10-27 15:00", conf: .high),
        c("提醒我，后天晚上7点，去看电影。", "去看电影", "2026-10-28 19:00", conf: .high),
        c("我要在周五之前把作业交了", "把作业交了", "2026-10-30 23:59", deadline: true),
        c("把实验报告在11月3号之前交给老师", "把实验报告交给老师", "2026-11-03 23:59", deadline: true),
        c("11月3号23点59分之前提交", "提交", "2026-11-03 23:59", conf: .high, deadline: true),
        c("高等数学第三章作业 十月三十日晚上十一点五十九截止", "高等数学第三章作业", "2026-10-30 23:59", conf: .high, deadline: true),
        c("高等数学作业 截止时间 2026-10-30 23:59", "高等数学作业", "2026-10-30 23:59", conf: .high, deadline: true),
        c("周一的早上8点开会", "开会", "2026-11-02 08:00", conf: .high),
        c("3月10号下午三点半在图书馆自习", "在图书馆自习", "2027-03-10 15:30", conf: .high),
        c("后天早上七点的飞机", "飞机", "2026-10-28 07:00", conf: .high),
        c("晚上九点五十睡觉", "睡觉", "2026-10-26 21:50", conf: .high),
        c("夜里11点半关灯", "关灯", "2026-10-26 23:30", conf: .high),
        c("半小时以后叫我", "叫我", "2026-10-26 21:35"),
        c("1小时30分钟后关火", "关火", "2026-10-26 22:35"),
        c("两小时三十分钟后开会", "开会", "2026-10-26 23:35"),
        c("每月5号交房租", "每月交房租", "2026-11-05 09:00", has: [.recurrenceMentioned]),
        c("工作日早上7点半起床", "工作日起床", "2026-10-27 07:30", has: [.recurrenceMentioned]),
        c("今晚8点半以后", "提醒", "2026-10-26 20:30", has: [.emptyTitle, .past]),
        c("后天下午5点之前交实验报告和实习报告", "交实验报告和实习报告", "2026-10-28 17:00", deadline: true),
        c("10月31日 周六 18:00", "提醒", "2026-10-31 18:00", has: [.emptyTitle], hasNot: [.conflict]),
        c("10月30日周六18:00开会", "开会", "2026-10-30 18:00", has: [.conflict], conf: .low),
        c("2026/11/05 14:30 答辩", "答辩", "2026-11-05 14:30", conf: .high),
        c("11.5日交作业", "交作业", "2026-11-05 09:00"),
        c("五月二十日交论文", "交论文", "2027-05-20 09:00"),
        c("提醒我明早7点30分起床", "起床", "2026-10-27 07:30", conf: .high),
        c("明天凌晨5点起床赶飞机", "起床赶飞机", "2026-10-27 05:00", conf: .high),
        c("下周三上午8点到10点高数课", "高数课", "2026-11-04 08:00", conf: .high),
        // What Apple's on-device recognizer actually returns for dictated sentences (captured with --voice-file-test)
        c("明天下午3:00开会", "开会", "2026-10-27 15:00", conf: .high),
        c("提醒我今晚10:30睡觉", "睡觉", "2026-10-26 22:30", conf: .high),
        c("后天上午9:00交实验报告", "交实验报告", "2026-10-28 09:00", conf: .high),
        c("周五晚上8:00去健身", "去健身", "2026-10-30 20:00", conf: .high),
        c("10月30日晚上11:59截止提交作业", "提交作业", "2026-10-30 23:59", conf: .high, deadline: true),
        c("下周三上午10:00交高等数学作业", "交高等数学作业", "2026-11-04 10:00", conf: .high),
        c("晚点提醒我", "晚点", nil, has: [.noDateTime], conf: .low),
        c("马上", "马上", nil, conf: .low),
        c("2月30日开会", "2月30日开会", nil, has: [.noDateTime], conf: .low),
        c("99点开会", "99点开会", nil, conf: .low),
        c("我有一点累", "我有一点累", nil, conf: .low),
        c("3号线地铁明天8点", "3号线地铁", "2026-10-27 08:00", has: [.ampmInferred]),
        c("7点10个人聚餐", "10个人聚餐", "2026-10-27 07:00", has: [.ampmInferred])
    ]

    private static func single(_ h: Harness) {
        for tc in cases {
            let events = NLParser.parse(tc.input, context: Fixture.context)
            guard events.count == 1, let e = events.first else {
                h.check(false, "「\(tc.input)」", "expected exactly 1 event, got \(events.count): \(events.map { $0.title })")
                continue
            }
            h.equal(e.title, tc.title, "「\(tc.input)」title")
            h.equal(Fixture.format(e.due), tc.due, "「\(tc.input)」due")
            h.check(e.flags.isSuperset(of: tc.has), "「\(tc.input)」flags", "missing \(tc.has.subtracting(e.flags)) in \(e.flags)")
            h.check(e.flags.isDisjoint(with: tc.hasNot), "「\(tc.input)」unexpected flags", "\(e.flags.intersection(tc.hasNot))")
            if let conf = tc.conf { h.equal(e.confidence, conf, "「\(tc.input)」confidence") }
            if let alt = tc.alt { h.equal(Fixture.format(e.alternative), alt, "「\(tc.input)」alternative") }
            if let dl = tc.deadline { h.equal(e.isDeadline, dl, "「\(tc.input)」isDeadline") }
        }
    }

    // MARK: several events in one utterance

    private static func multi(_ h: Harness) {
        let tests: [(String, [(String, String?)])] = [
            ("后天上午十点交实验报告然后周五晚上八点健身",
             [("交实验报告", "2026-10-28 10:00"), ("健身", "2026-10-30 20:00")]),
            ("明天上午九点开会，后天下午三点交作业，周五晚上八点健身",
             [("开会", "2026-10-27 09:00"), ("交作业", "2026-10-28 15:00"), ("健身", "2026-10-30 20:00")]),
            ("明天19点吃饭，20点跑步",
             [("吃饭", "2026-10-27 19:00"), ("跑步", "2026-10-27 20:00")]),
            ("明天开会，后天考试",
             [("开会", "2026-10-27 09:00"), ("考试", "2026-10-28 09:00")]),
            ("10月30日，下午3点，开会",
             [("开会", "2026-10-30 15:00")]),
            ("去睡觉，今晚23点",
             [("去睡觉", "2026-10-26 23:00")]),
            ("今晚23点，去睡觉",
             [("去睡觉", "2026-10-26 23:00")]),
            ("明天开会，讨论预算",
             [("开会，讨论预算", "2026-10-27 09:00")]),
            ("买牛奶，鸡蛋，明天",
             [("买牛奶，鸡蛋", "2026-10-27 09:00")]),
            ("明天早上7:00起床，然后晚上8:30看电影",
             [("起床", "2026-10-27 07:00"), ("看电影", "2026-10-27 20:30")])
        ]
        for (input, expected) in tests {
            let events = NLParser.parse(input, context: Fixture.context)
            h.equal(events.count, expected.count, "「\(input)」event count")
            for (e, x) in zip(events, expected) {
                h.equal(e.title, x.0, "「\(input)」title")
                h.equal(Fixture.format(e.due), x.1, "「\(input)」due of \(x.0)")
            }
        }
    }

    // MARK: every spelling of the same time must give the same moment

    private static let hanDigits = ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九", "十", "十一", "十二"]

    private static func equivalentFormats(_ h: Harness) {
        func pad(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }
        func period(_ hour: Int) -> (word: String, twelve: Int) {
            switch hour {
            case 0: return ("凌晨", 12)
            case 1...5: return ("凌晨", hour)
            case 6...11: return ("上午", hour)
            case 12: return ("中午", 12)
            case 13...17: return ("下午", hour - 12)
            default: return ("晚上", hour - 12)
            }
        }
        for hour in 0...23 {
            for minute in [0, 15, 30, 45] {
                let expected = "2026-10-27 \(pad(hour)):\(pad(minute))"
                let p = period(hour)
                let minuteWords: [String] = {
                    switch minute {
                    case 0: return ["", "整"]
                    case 15: return ["一刻", "15分", "15"]
                    case 30: return ["半", "30分", "30"]
                    default: return ["三刻", "45分", "45"]
                    }
                }()
                var inputs = [
                    "明天\(pad(hour)):\(pad(minute))开会",
                    "明天\(pad(hour))：\(pad(minute))开会"
                ]
                for mw in minuteWords {
                    inputs.append("明天\(p.word)\(p.twelve)点\(mw)开会")
                    inputs.append("明天\(p.word)\(hanDigits[p.twelve])点\(mw)开会")
                }
                if hour >= 13 {
                    inputs.append("明天\(hour)点\(minute == 0 ? "整" : "\(minute)分")开会")
                }
                for input in inputs {
                    let events = NLParser.parse(input, context: Fixture.context)
                    h.check(events.count == 1 && events[0].title == "开会" && Fixture.format(events[0].due) == expected,
                            "equivalent「\(input)」",
                            "expected 开会 @ \(expected), got \(events.map { "\($0.title) @ \(Fixture.format($0.due) ?? "nil")" })")
                }
            }
        }
    }
}
