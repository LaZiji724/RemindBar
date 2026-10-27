import Foundation

/// Canvas LMS (e.g. https://canvas.tongji.edu.cn). Everything comes from the documented REST API using the
/// browser session, so reading assignments costs no AI tokens.
public enum CanvasAPI {
    public static let types: Set<String> = ["assignment", "quiz", "discussion_topic"]

    /// https://host from any URL on the site.
    public static func base(from urlString: String) -> URL? {
        guard let url = URL(string: urlString), let scheme = url.scheme, let host = url.host else { return nil }
        return URL(string: "\(scheme)://\(host)")
    }

    /// Planner items from two weeks ago to 180 days ahead, 100 per page. Completed items are included so that
    /// submissions made elsewhere can mark our reminder done.
    public static func plannerURL(base: URL, now: Date, calendar: Calendar) -> URL {
        let start = calendar.date(byAdding: .day, value: -14, to: now) ?? now
        let end = calendar.date(byAdding: .day, value: 180, to: now) ?? now
        func day(_ d: Date) -> String {
            let c = calendar.dateComponents([.year, .month, .day], from: d)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.path = "/api/v1/planner/items"
        comps.queryItems = [
            URLQueryItem(name: "start_date", value: day(start)),
            URLQueryItem(name: "end_date", value: day(end)),
            URLQueryItem(name: "per_page", value: "100")
        ]
        return comps.url!
    }

    public static func selfURL(base: URL) -> URL {
        base.appendingPathComponent("api/v1/users/self")
    }

    /// Runs inside the page (same origin, session cookies attached). Follows `Link: rel="next"` and returns
    /// `{status, body}` where `body` is one JSON array of all pages.
    public static func pagedScript(startURL: URL, maxPages: Int = 10) -> String {
        """
        const headers = {'Accept': 'application/json+canvas-string-ids, application/json'};
        let url = \(jsString(startURL.absoluteString));
        const all = [];
        for (let page = 0; url && page < \(maxPages); page++) {
          const response = await fetch(url, {credentials: 'same-origin', headers, cache: 'no-store'});
          if (!response.ok) { return JSON.stringify({status: response.status, body: ''}); }
          const data = await response.json();
          if (Array.isArray(data)) { all.push(...data); } else { all.push(data); }
          const link = response.headers.get('Link') || '';
          const next = link.match(/<([^>]+)>;\\s*rel="next"/);
          url = next ? next[1] : null;
        }
        return JSON.stringify({status: 200, body: JSON.stringify(all)});
        """
    }

    /// Single request, used for the "am I logged in" check.
    public static func singleScript(url: URL) -> String {
        """
        const response = await fetch(\(jsString(url.absoluteString)), {credentials: 'same-origin', headers: {'Accept': 'application/json'}, cache: 'no-store'});
        const text = response.ok ? await response.text() : '';
        return JSON.stringify({status: response.status, body: text});
        """
    }

    private static func jsString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
    }

    // MARK: parsing

    public static func parsePlanner(_ data: Data, base: URL) throws -> [RemoteItem] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw SourceError.badResponse("planner/items 不是数组")
        }
        var seen = Set<String>()
        var items: [RemoteItem] = []
        for raw in array {
            guard let type = raw["plannable_type"] as? String, types.contains(type) else { continue }
            let plannable = raw["plannable"] as? [String: Any] ?? [:]
            guard let id = idString(raw["plannable_id"]) ?? idString(plannable["id"]) else { continue }
            let title = (plannable["title"] as? String) ?? (plannable["name"] as? String) ?? ""
            guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            // Undated items cannot be reminded about.
            guard let due = parseDate((plannable["due_at"] as? String) ?? (raw["plannable_date"] as? String)) else { continue }

            let submissions = raw["submissions"] as? [String: Any]
            let override = raw["planner_override"] as? [String: Any]
            let completed = (submissions?["submitted"] as? Bool ?? false)
                || (submissions?["excused"] as? Bool ?? false)
                || (override?["marked_complete"] as? Bool ?? false)

            let key = "canvas:\(type):\(id)"
            guard seen.insert(key).inserted else { continue }
            items.append(RemoteItem(key: key, title: title, course: raw["context_name"] as? String, due: due,
                                    url: absolute(raw["html_url"] as? String, base: base), completed: completed))
        }
        return items
    }

    private static func idString(_ any: Any?) -> String? {
        if let s = any as? String, !s.isEmpty { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return nil
    }

    private static func absolute(_ path: String?, base: URL) -> String? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return path }
        return URL(string: path, relativeTo: base)?.absoluteString
    }

    static func parseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: s) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: s)
    }

    /// For developer tools outside this module.
    public static func parseDateForTools(_ s: String?) -> Date? { parseDate(s) }

    /// Decodes the `{status, body}` envelope produced by the scripts above.
    public static func decodeEnvelope(_ text: String) throws -> WebFetchResult {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["status"] as? Int else {
            throw SourceError.script("脚本返回格式不对")
        }
        return WebFetchResult(status: status, body: obj["body"] as? String ?? "")
    }
}

/// Reads the user's open assignments from a Canvas site.
@MainActor
public final class CanvasSource {
    private let session: WebSessionFetching
    public let base: URL
    private let calendar: Calendar
    private let clock: () -> Date
    /// Receives the raw planner JSON of every successful fetch (only set while calibrating).
    public var onRawResponse: ((String) -> Void)?

    public init(session: WebSessionFetching, base: URL, calendar: Calendar = .reminder, clock: @escaping () -> Date = Date.init) {
        self.session = session
        self.base = base
        self.calendar = calendar
        self.clock = clock
    }

    public func isLoggedIn() async -> Bool {
        do {
            let result = try await session.fetch(script: CanvasAPI.singleScript(url: CanvasAPI.selfURL(base: base)), baseURL: base)
            return result.status == 200
        } catch {
            return false
        }
    }

    public func fetchItems() async throws -> [RemoteItem] {
        let url = CanvasAPI.plannerURL(base: base, now: clock(), calendar: calendar)
        let result = try await session.fetch(script: CanvasAPI.pagedScript(startURL: url), baseURL: base)
        switch result.status {
        case 200:
            onRawResponse?(result.body)
            return try CanvasAPI.parsePlanner(Data(result.body.utf8), base: base)
        case 401, 403: throw SourceError.notLoggedIn
        default: throw SourceError.http(result.status)
        }
    }
}
