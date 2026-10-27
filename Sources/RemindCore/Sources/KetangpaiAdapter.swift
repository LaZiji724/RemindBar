import Foundation

/// 课堂派 (www.ketangpai.com). Its web app is a Vue single-page app that calls `https://openapiv5.ketangpai.com/` with an
/// HTTP header `token` (the value of the `token` cookie). Calibrated against the site's own traffic:
///  - `/Futurev2/Todo/getTodoList` lists what the student still has to do. Its `endtime` is usually 0 for homework.
///  - `/FutureV2/CourseMeans/getCourseContent` with `contenttype: 4` lists a course's homework including the real
///    deadline (`endtime`, epoch seconds).
/// Both are read-only queries. Anything that writes (`tagFinishedTodo`, `ignoreTodo`, `submitHomework`…) is deliberately
/// absent: the scripts below may only call the paths in `allowedPaths`, and the self-test checks that.
public enum KetangpaiAPI {
    public static let pageBase = URL(string: "https://www.ketangpai.com/")!
    public static let apiBase = URL(string: "https://openapiv5.ketangpai.com/")!
    public static let todoPage = "https://www.ketangpai.com/#/main/todo"

    public static let todoPath = "/Futurev2/Todo/getTodoList"
    public static let courseContentPath = "/FutureV2/CourseMeans/getCourseContent"

    /// The only API paths this app may ever call.
    public static let allowedPaths: Set<String> = [todoPath, courseContentPath]

    public static func isAllowed(path: String) -> Bool {
        allowedPaths.contains(path)
    }

    /// Shared prelude: reads the session token like the web app does and defines `call(path, payload)`.
    private static let prelude = """
    const API = '\(apiBase.absoluteString)';
    function readToken() {
      const part = document.cookie.split(';').map(s => s.trim()).find(s => s.startsWith('token=') && s.length > 6);
      if (part) { try { return decodeURIComponent(part.slice(6)); } catch (e) { return part.slice(6); } }
      return localStorage.getItem('token') || '';
    }
    const token = readToken();
    if (!token) { return JSON.stringify({status: 401, body: ''}); }
    async function call(path, payload) {
      const response = await fetch(API + path, {
        method: 'POST',
        cache: 'no-store',
        headers: {'Content-Type': 'application/json', 'token': token},
        body: JSON.stringify(Object.assign({}, payload, {reqtimestamp: Date.now()}))
      });
      if (!response.ok) { throw {http: response.status}; }
      return await response.json();
    }
    function sessionExpired(json) {
      return json && json.status !== 1 && /登录|token|login/i.test(String(json.message || ''));
    }
    """

    /// Valid only when the token really works: one tiny to-do request must succeed.
    public static let loginCheckScript = prelude + """

    try {
      const json = await call('\(todoPath)', {page: 1, limit: 1, type: '', classid: ''});
      return JSON.stringify({status: json && json.status === 1 ? 200 : 401, body: ''});
    } catch (e) {
      return JSON.stringify({status: (e && e.http) || 599, body: ''});
    }
    """

    /// To-do list (all pages) plus the homework list of every course that has a homework item in it.
    public static let fetchScript = prelude + """

    try {
      const todo = [];
      for (let page = 1; page <= 10; page++) {
        const json = await call('\(todoPath)', {page: page, limit: 20, type: '', classid: ''});
        if (sessionExpired(json)) { return JSON.stringify({status: 401, body: ''}); }
        if (!json || json.status !== 1) { return JSON.stringify({status: 502, body: String(json && json.message || '')}); }
        const list = (json.data && json.data.list) || [];
        todo.push(...list);
        const pages = Number((json.data && json.data.pageTotal) || 1);
        if (page >= pages || list.length === 0) { break; }
      }
      const courses = [...new Set(todo.filter(t => String(t.contenttype) === '4').map(t => t.courseid))];
      const homework = {};
      for (const courseid of courses) {
        homework[courseid] = [];
        for (let page = 1; page <= 5; page++) {
          const json = await call('\(courseContentPath)', {courseid: courseid, contenttype: 4, dirid: 0, lessonlink: [], sort: [], page: page, limit: 50, desc: 3, courserole: 0, vtr_type: ''});
          if (!json || json.status !== 1) { break; }
          const list = (json.data && json.data.list) || [];
          homework[courseid].push(...list);
          const pages = Number((json.data && json.data.pageTotal) || 1);
          if (page >= pages || list.length === 0) { break; }
        }
      }
      return JSON.stringify({status: 200, body: JSON.stringify({todo: todo, homework: homework})});
    } catch (e) {
      return JSON.stringify({status: (e && e.http) || 599, body: String((e && e.message) || '')});
    }
    """

    /// Every `call('<path>'` the scripts contain (used by the self-test to prove nothing outside the allow-list is called).
    public static var pathsCalledByScripts: Set<String> {
        let text = loginCheckScript + fetchScript
        let regex = try! NSRegularExpression(pattern: #"call\('([^']+)'"#)
        let ns = text as NSString
        return Set(regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) })
    }

    // MARK: parsing

    /// Seconds since 1970 (as a string or a number); 0 / empty means "no deadline". Milliseconds are tolerated.
    static func epoch(_ any: Any?) -> Date? {
        let number: Double?
        if let s = any as? String { number = Double(s) }
        else if let n = any as? NSNumber { number = n.doubleValue }
        else { number = nil }
        guard var value = number, value > 0 else { return nil }
        if value > 100_000_000_000 { value /= 1_000 }
        return Date(timeIntervalSince1970: value)
    }

    /// For developer tools outside this module.
    public static func epochForTools(_ any: Any?) -> Date? { epoch(any) }

    private static func text(_ any: Any?) -> String {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }

    /// `body` is `{"todo":[…], "homework":{"<courseid>":[…]}}` as produced by `fetchScript`.
    public static func parse(body: String) throws -> [RemoteItem] {
        guard let data = body.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SourceError.badResponse("待办数据不是 JSON 对象")
        }
        let todo = root["todo"] as? [[String: Any]] ?? []
        let homework = root["homework"] as? [String: [[String: Any]]] ?? [:]
        var items: [RemoteItem] = []
        var seen = Set<String>()
        for t in todo {
            let type = text(t["contenttype"])
            var contentID = text(t["contentid"])
            if contentID.isEmpty { contentID = text(t["id"]) }
            let title = text(t["contenttitle"]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !contentID.isEmpty, !title.isEmpty else { continue }

            // The to-do entry rarely carries the deadline; the course's homework list does.
            var due = epoch(t["endtime"])
            if due == nil, type == "4", let list = homework[text(t["courseid"])],
               let match = list.first(where: { text($0["id"]) == contentID }) {
                due = epoch(match["endtime"])
            }
            guard let due else { continue } // nothing to remind about without a deadline

            let key = "ketangpai:\(type):\(contentID)"
            guard seen.insert(key).inserted else { continue }
            let course = text(t["coursename"])
            items.append(RemoteItem(key: key, title: title, course: course.isEmpty ? nil : course, due: due, url: todoPage, completed: false))
        }
        return items
    }
}

/// Reads the open homework of the logged-in 课堂派 account.
@MainActor
public final class KetangpaiSource {
    private let session: WebSessionFetching
    /// Receives the raw `{todo, homework}` JSON of every successful fetch (only set while calibrating).
    public var onRawResponse: ((String) -> Void)?

    public init(session: WebSessionFetching) {
        self.session = session
    }

    public func isLoggedIn() async -> Bool {
        do {
            let result = try await session.fetch(script: KetangpaiAPI.loginCheckScript, baseURL: KetangpaiAPI.pageBase)
            return result.status == 200
        } catch {
            return false
        }
    }

    public func fetchItems() async throws -> [RemoteItem] {
        let result = try await session.fetch(script: KetangpaiAPI.fetchScript, baseURL: KetangpaiAPI.pageBase)
        switch result.status {
        case 200:
            onRawResponse?(result.body)
            return try KetangpaiAPI.parse(body: result.body)
        case 401, 403:
            throw SourceError.notLoggedIn
        case 502:
            throw SourceError.badResponse(result.body.isEmpty ? "课堂派返回了失败状态" : result.body)
        default:
            throw SourceError.http(result.status)
        }
    }
}
