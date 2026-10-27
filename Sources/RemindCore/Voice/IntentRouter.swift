import Foundation

public struct ConnectRequest: Equatable, Sendable {
    public var kind: SourceKind
    public var url: URL?
    /// What is left of the text once the platform name / URL is removed ("看看有没有新作业").
    public var hint: String

    public init(kind: SourceKind, url: URL?, hint: String) {
        self.kind = kind
        self.url = url
        self.hint = hint
    }
}

public enum Intent: Equatable, Sendable {
    case empty
    case reminder
    case connect(ConnectRequest)
}

/// Local, zero-token routing between "add a reminder" and "connect a monitoring source".
public enum IntentRouter {
    public static let canvasURL = URL(string: "https://canvas.tongji.edu.cn/")!
    public static let ketangpaiURL = URL(string: "https://www.ketangpai.com/#/main")!

    private static let urlRegex = Rx.make(#"https?://[^\s，。；！？、]+"#, ci: true)
    private static let watchVerbs = ["监控", "监看", "盯着", "盯", "关注", "同步", "连接", "接入", "绑定", "订阅",
                                     "看看", "查看", "检查", "有没有", "自动", "登录", "添加"]

    public static func route(_ text: String, context: ParseContext) -> Intent {
        let t = TextNormalizer.normalize(text)
        if t.isEmpty { return .empty }

        let hasDateTime = hasDateTimeTokens(t)
        let ns = t as NSString

        if let m = urlRegex.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)), !hasDateTime {
            let raw = ns.substring(with: m.range)
            let url = URL(string: raw)
            let rest = ns.replacingCharacters(in: m.range, with: " ")
            return .connect(ConnectRequest(kind: kind(forHost: url?.host), url: url, hint: tidy(rest)))
        }

        let lower = t.lowercased()
        let kind: SourceKind?
        var platformWord = ""
        if lower.contains("课堂派") { kind = .ketangpai; platformWord = "课堂派" }
        else if lower.contains("ketangpai") { kind = .ketangpai; platformWord = "ketangpai" }
        else if lower.contains("canvas") { kind = .canvas; platformWord = "canvas" }
        else { kind = nil }

        if let kind, !hasDateTime, watchVerbs.contains(where: { t.contains($0) }) {
            let rest = t.replacingOccurrences(of: platformWord, with: " ", options: .caseInsensitive)
            return .connect(ConnectRequest(kind: kind, url: kind == .canvas ? canvasURL : ketangpaiURL, hint: tidy(rest)))
        }
        return .reminder
    }

    public static func kind(forHost host: String?) -> SourceKind {
        guard let h = host?.lowercased() else { return .web }
        if h.hasSuffix("ketangpai.com") { return .ketangpai }
        if h.hasPrefix("canvas.") || h.contains(".canvas.") || h.hasSuffix("instructure.com") { return .canvas }
        return .web
    }

    private static func hasDateTimeTokens(_ normalized: String) -> Bool {
        Tokenizer.tokenize(normalized).contains { tok in
            switch tok.kind {
            case .filler, .deadlineMarker, .rangeEnd: return false
            default: return true
            }
        }
    }

    private static func tidy(_ s: String) -> String {
        s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ，,。.；;：:！!？?、"))
    }
}
