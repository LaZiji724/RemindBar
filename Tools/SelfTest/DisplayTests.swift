import Foundation
import RemindCore

enum DisplayTests {
    static func run(_ h: Harness) {
        h.suite = "display"
        let cal = Fixture.calendar
        let now = Fixture.now // Mon 2026-10-26 21:05

        func label(_ s: String) -> String { DisplayFormat.dayLabel(Fixture.date(s), now: now, calendar: cal) }
        h.equal(label("2026-10-26 23:00"), "今天", "same day")
        h.equal(label("2026-10-27 08:00"), "明天", "next day")
        h.equal(label("2026-10-28 08:00"), "后天", "day after tomorrow")
        h.equal(label("2026-10-25 08:00"), "昨天", "yesterday")
        h.equal(label("2026-10-30 23:59"), "10月30日 周五", "same year")
        h.equal(label("2027-03-05 09:00"), "2027年3月5日 周五", "other year")
        h.equal(DisplayFormat.timeLabel(Fixture.date("2026-10-30 07:05"), calendar: cal), "07:05", "zero padded time")
        func full(_ s: String) -> String { DisplayFormat.fullDayLabel(Fixture.date(s), now: now, calendar: cal) }
        h.equal(full("2026-10-26 19:00"), "今天 10月26日 周一", "full label for today")
        h.equal(full("2026-10-27 19:00"), "明天 10月27日 周二", "full label for tomorrow")
        h.equal(full("2026-10-30 19:00"), "10月30日 周五", "full label far away equals the plain one")
        h.equal(DisplayFormat.dueLabel(Fixture.date("2026-10-27 19:00"), now: now, calendar: cal), "明天 19:00", "due label")

        func cd(_ s: String) -> String { DisplayFormat.countdown(to: Fixture.date(s), now: now) }
        h.equal(cd("2026-10-26 21:05"), "现在", "countdown now")
        h.equal(cd("2026-10-26 21:30"), "25分钟后", "minutes")
        h.equal(cd("2026-10-26 23:30"), "2小时25分后", "hours and minutes under 6h")
        h.equal(cd("2026-10-27 08:00"), "10小时后", "hours")
        h.equal(cd("2026-10-30 21:05"), "4天后", "days")
        h.equal(cd("2026-10-26 19:00"), "已逾期 2小时5分", "overdue hours")
        h.equal(cd("2026-10-26 20:50"), "已逾期 15分钟", "overdue minutes")

        func bucket(_ s: String?) -> DayBucket {
            let r = Reminder(title: "x", due: s.map(Fixture.date))
            return DisplayFormat.bucket(for: r, now: now, calendar: cal)
        }
        h.equal(bucket("2026-10-26 20:00"), .overdue, "past -> overdue")
        h.equal(bucket("2026-10-26 23:30"), .today, "later today")
        h.equal(bucket("2026-10-27 09:00"), .tomorrow, "tomorrow")
        h.equal(bucket("2026-10-30 09:00"), .thisWeek, "later this week")
        h.equal(bucket("2026-11-01 23:59"), .thisWeek, "Sunday is still this week")
        h.equal(bucket("2026-11-02 09:00"), .later, "next Monday starts a new week")
        h.equal(bucket(nil), .noDue, "no due date")

        h.equal(DisplayFormat.urgency(of: Fixture.date("2026-10-26 21:30"), now: now), .soon, "under an hour")
        h.equal(DisplayFormat.urgency(of: Fixture.date("2026-10-27 08:00"), now: now), .today, "under a day")
        h.equal(DisplayFormat.urgency(of: Fixture.date("2026-10-29 08:00"), now: now), .normal, "later")
        h.equal(DisplayFormat.urgency(of: Fixture.date("2026-10-26 20:00"), now: now), .overdue, "overdue")

        var r = Reminder(title: "交作业", due: Fixture.date("2026-10-28 20:00"), isDeadline: true)
        r.source = .canvas
        r.course = "数据库原理"
        h.equal(DisplayFormat.alertBody(for: r, lead: 10_800, now: now, calendar: cal),
                "还有3小时截止 · Canvas · 数据库原理 · 后天 20:00", "alert body with lead time")
        h.equal(DisplayFormat.alertBody(for: r, lead: 180, now: now, calendar: cal),
                "还有3分钟截止 · Canvas · 数据库原理 · 后天 20:00", "alert body three minutes ahead")
        h.equal(DisplayFormat.alertBody(for: r, lead: 0, now: now, calendar: cal),
                "已到截止时间 · Canvas · 数据库原理 · 后天 20:00", "alert body at the deadline")
    }
}
