import Foundation

/// One assignment / task as reported by a remote site, before it becomes a `Reminder`.
public struct RemoteItem: Equatable, Sendable {
    /// Stable id from the site, e.g. "canvas:assignment:123"; used to de-duplicate on every sync.
    public var key: String
    public var title: String
    public var course: String?
    public var due: Date?
    public var url: String?
    /// Submitted / excused / marked complete at the source.
    public var completed: Bool

    public init(key: String, title: String, course: String? = nil, due: Date?, url: String? = nil, completed: Bool = false) {
        self.key = key
        self.title = title
        self.course = course
        self.due = due
        self.url = url
        self.completed = completed
    }
}

public enum SourceError: Error, Equatable, Sendable {
    /// The session expired or the user never logged in.
    case notLoggedIn
    case http(Int)
    case badResponse(String)
    case script(String)

    public var message: String {
        switch self {
        case .notLoggedIn: return "需要重新登录"
        case .http(let code): return "网站返回错误 \(code)"
        case .badResponse(let detail): return "返回内容无法识别：\(detail)"
        case .script(let detail): return "读取失败：\(detail)"
        }
    }
}

/// What the web session returns for a scripted request.
public struct WebFetchResult: Equatable, Sendable {
    public var status: Int
    /// Concatenated JSON array (Canvas) or the raw JSON text of the answer.
    public var body: String

    public init(status: Int, body: String) {
        self.status = status
        self.body = body
    }
}

/// Runs a request inside the logged-in web session. The real implementation drives a hidden WKWebView.
public protocol WebSessionFetching: AnyObject {
    @MainActor func fetch(script: String, baseURL: URL) async throws -> WebFetchResult
    /// Loads the page like a browser (JavaScript, SSO redirects) and returns its visible text.
    /// Throws `SourceError.notLoggedIn` when the site bounced the session to a login page.
    @MainActor func pageText(url: URL) async throws -> String
}
