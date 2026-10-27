import Foundation
import RemindCore

/// Minimal assertion collector (the machine has no XCTest; same approach as the sibling project's self-test tool).
final class Harness {
    private(set) var passed = 0
    private(set) var failures: [String] = []
    var suite = ""

    func check(_ ok: Bool, _ name: @autoclosure () -> String, _ detail: @autoclosure () -> String = "") {
        if ok {
            passed += 1
        } else {
            let d = detail()
            failures.append("[\(suite)] \(name())" + (d.isEmpty ? "" : "\n      \(d)"))
        }
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ name: @autoclosure () -> String) {
        check(actual == expected, name(), "expected: \(expected)\n      actual:   \(actual)")
    }

    func report() -> Int32 {
        print("")
        if failures.isEmpty {
            print("✅ \(passed) checks passed")
            return 0
        }
        print("❌ \(failures.count) failed, \(passed) passed\n")
        for f in failures { print(" • \(f)") }
        return 1
    }
}

/// Fixed clock used by every parser test: Monday 2026-10-26 21:05 in Shanghai.
enum Fixture {
    static let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = timeZone
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        c.locale = Locale(identifier: "zh_CN")
        return c
    }

    static var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 21, minute: 5))!
    }

    static var context: ParseContext { ParseContext(now: now, calendar: calendar) }

    static func format(_ d: Date?) -> String? {
        guard let d else { return nil }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    static func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }
}
