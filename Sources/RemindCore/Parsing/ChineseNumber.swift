import Foundation

/// Converts Arabic digits and Chinese numerals ("二十三", "十一", "二零二六", "两千零二十六") to `Int`.
enum ChineseNumber {
    private static let digits: [Character: Int] = [
        "零": 0, "〇": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9
    ]

    static func parse(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.allSatisfy({ $0.isASCII && $0.isNumber }) { return Int(s) }
        // Digit-by-digit reading: 二零二六 -> 2026, 零五 -> 5, 五 -> 5
        if s.allSatisfy({ digits[$0] != nil }) {
            return s.reduce(0) { $0 * 10 + (digits[$1] ?? 0) }
        }
        // Positional reading with 十 / 百 / 千
        var total = 0
        var current = 0
        for c in s {
            if let d = digits[c] {
                current = d
            } else if c == "十" {
                total += (current == 0 ? 1 : current) * 10
                current = 0
            } else if c == "百" {
                total += (current == 0 ? 1 : current) * 100
                current = 0
            } else if c == "千" {
                total += (current == 0 ? 1 : current) * 1000
                current = 0
            } else {
                return nil
            }
        }
        return total + current
    }
}
