import Foundation

enum TextNormalizer {
    /// Traditional variants that show up in dates and times; mapped to the simplified forms the parser expects.
    private static let variants: [(String, String)] = [
        ("點", "点"), ("號", "号"), ("週", "周"), ("禮", "礼"), ("後", "后"),
        ("時", "时"), ("鐘", "钟"), ("兩", "两"), ("鬧", "闹")
    ]

    /// NFKC (full-width digits/colon/comma -> half-width), traditional -> simplified, whitespace collapse.
    static func normalize(_ input: String) -> String {
        var t = input.precomposedStringWithCompatibilityMapping
        for (from, to) in variants { t = t.replacingOccurrences(of: from, with: to) }
        t = t.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        t = t.replacingOccurrences(of: "[ \\t\\u{00A0}\\u{3000}]+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum Rx {
    static func make(_ pattern: String, ci: Bool = false) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern, options: ci ? [.caseInsensitive] : [])
        } catch {
            preconditionFailure("Invalid regex \(pattern): \(error)")
        }
    }
}

extension NSRange {
    var end: Int { location + length }
    func overlaps(_ other: NSRange) -> Bool { location < other.end && other.location < end }
}
