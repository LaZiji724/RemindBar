import Foundation

enum TitleExtractor {
    /// Leading phrases that carry no event content: instructions to the assistant and spoken fillers.
    private static let prefixes: [String] = [
        "千万不要忘记", "千万别忘了", "不要忘记", "不要忘了", "提醒我一下", "麻烦帮我", "请帮我", "提醒一下", "麻烦你",
        "别忘记", "别忘了", "就是说", "我需要", "我想要", "提醒我", "帮我", "给我", "替我", "记得", "记住", "我得", "我要",
        "需要", "那个", "就是", "对了", "好的", "那么", "所以", "嗯嗯", "提醒", "嗯", "呃", "额", "哦", "啊", "要", "得", "的",
        "的时候", "时候"
    ].sorted { $0.count > $1.count }

    private static let suffixes: [String] = [
        "提醒一下", "提醒我", "提醒", "谢谢", "拜托", "谢啦", "哦", "哈", "啊", "吧", "呀", "啦", "呢", "哇", "喔"
    ].sorted { $0.count > $1.count }

    private static let edgePunctuation = CharacterSet(charactersIn: " \t\n，,。.；;：:！!？?、~-—_·…")

    /// Returns `text` without `ranges`, tidied up. May be empty.
    static func extract(from text: String, removing ranges: [NSRange]) -> String {
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for r in ranges.sorted(by: { $0.location < $1.location }) {
            if r.location > cursor {
                out += ns.substring(with: NSRange(location: cursor, length: r.location - cursor))
            }
            out += " "
            cursor = max(cursor, r.end)
        }
        if cursor < ns.length { out += ns.substring(from: cursor) }
        return clean(out)
    }

    static func clean(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        t = trimEdges(t)
        var changed = true
        while changed {
            changed = false
            for p in prefixes where t.hasPrefix(p) {
                let rest = String(t.dropFirst(p.count))
                // "要" / "得" / "需要" are only fillers when something meaningful follows.
                if ["要", "得", "需要", "的", "时候", "的时候"].contains(p) && trimEdges(rest).count < 2 { continue }
                t = trimEdges(rest)
                // A title that was nothing but "提醒我" stays empty (the caller supplies a fallback).
                changed = !t.isEmpty
                break
            }
        }
        changed = true
        while changed {
            changed = false
            for s in suffixes where t.hasSuffix(s) {
                let rest = trimEdges(String(t.dropLast(s.count)))
                if rest.isEmpty { continue }
                t = rest
                changed = true
                break
            }
        }
        // A space between two Han characters is an artifact of removed tokens.
        t = t.replacingOccurrences(of: "(?<=\\p{Han}) +(?=\\p{Han})", with: "", options: .regularExpression)
        return restoreChinesePunctuation(trimEdges(t))
    }

    /// NFKC turns "，" into "," etc.; put the Chinese forms back where they sit next to Han characters.
    private static func restoreChinesePunctuation(_ s: String) -> String {
        let rules: [(String, String)] = [
            ("(?<=\\p{Han}),", "，"), (",(?=\\p{Han})", "，"),
            ("(?<=\\p{Han});", "；"), (";(?=\\p{Han})", "；"),
            ("(?<=\\p{Han})\\?", "？"), ("(?<=\\p{Han})!", "！"),
            ("(?<=\\p{Han}):", "："),
            ("\\((?=\\p{Han})", "（"), ("(?<=\\p{Han})\\)", "）")
        ]
        var t = s
        for (pattern, replacement) in rules {
            t = t.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return t
    }

    private static func trimEdges(_ s: String) -> String {
        s.trimmingCharacters(in: edgePunctuation)
    }
}
