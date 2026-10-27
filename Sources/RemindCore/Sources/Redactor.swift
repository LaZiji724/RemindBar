import Foundation

/// Removes secrets from text before it is written to a calibration file.
public enum Redactor {
    private static let sensitiveValue = try! NSRegularExpression(
        pattern: #"("[^"]*(?:token|password|passwd|pwd|secret|authorization|cookie|openid|unionid|phone|mobile|email|idcard|sfz)[^"]*"\s*:\s*)(?:"(?:[^"\\]|\\.)*"|\d+)"#,
        options: [.caseInsensitive])
    private static let bearer = try! NSRegularExpression(pattern: #"(?i)(bearer\s+)[A-Za-z0-9._\-]+"#)
    private static let queryToken = try! NSRegularExpression(pattern: #"(?i)([?&](?:token|access_token|key|sign)=)[^&\s"]+"#)

    public static func scrub(_ text: String) -> String {
        var out = text
        for (regex, template) in [(sensitiveValue, "$1\"<redacted>\""), (bearer, "$1<redacted>"), (queryToken, "$1<redacted>")] {
            out = regex.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length), withTemplate: template)
        }
        return out
    }
}
