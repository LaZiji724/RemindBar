import AppKit
import WebKit
import RemindCore

/// Runs scripts inside the user's logged-in browser session. The login window and this hidden runner share
/// WebKit's persistent data store, so cookies and SSO state behave exactly like in Safari — and the app never
/// sees or stores a password.
@MainActor
final class WebSession: WebSessionFetching {
    static let shared = WebSession()

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        return config
    }

    /// How many times a site was really read (scripts run + pages loaded). Lets the self-check prove that every press of
    /// the refresh button goes to the website.
    private(set) var requestCount = 0

    func fetch(script: String, baseURL: URL) async throws -> WebFetchResult {
        requestCount += 1
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: Self.makeConfiguration())
        web.customUserAgent = Self.userAgent
        let waiter = LoadWaiter()
        // An empty page whose origin is the target site: fetch() is then same-origin and carries the session cookies.
        try await waiter.load(web, html: "<!doctype html><html><body></body></html>", base: baseURL)
        let value = try await withTimeout(seconds: 40) {
            try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .page)
        }
        guard let text = value as? String else { throw SourceError.script("脚本没有返回内容") }
        return try CanvasAPI.decodeEnvelope(text)
    }

    /// Loads a page like a browser and returns its visible text once it stops changing (single-page apps render late).
    func pageText(url: URL) async throws -> String {
        requestCount += 1
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: Self.makeConfiguration())
        web.customUserAgent = Self.userAgent
        let waiter = LoadWaiter()
        // Every check really goes to the site: never answer from the local cache.
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 40)
        try await withTimeout(seconds: 45) { try await waiter.load(web, request: request) }

        var previous = ""
        var stableRounds = 0
        for _ in 0..<20 {
            try await Task.sleep(nanoseconds: 500_000_000)
            let value = try? await web.evaluateJavaScript("document.body ? document.body.innerText : ''")
            let text = (value as? String) ?? ""
            if !text.isEmpty && text == previous {
                stableRounds += 1
                if stableRounds >= 2 { break }
            } else {
                stableRounds = 0
                previous = text
            }
        }
        // A site that bounced the session to a sign-in page has expired.
        if let final = web.url, Self.looksLikeLogin(final), !Self.looksLikeLogin(url) { throw SourceError.notLoggedIn }
        return previous
    }

    private static func looksLikeLogin(_ url: URL) -> Bool {
        let s = url.absoluteString.lowercased()
        return ["login", "signin", "sign-in", "/sso", "/cas/", "oauth", "passport", "authserver"].contains { s.contains($0) }
    }

    /// Session cookies would vanish when the app quits; give them an expiry so the login survives restarts.
    func persistSessionCookies(domainSuffix: String, days: Int = 30) async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await store.allCookies()
        let expiry = Date().addingTimeInterval(Double(days) * 86_400)
        for cookie in cookies where cookie.domain.hasSuffix(domainSuffix) && cookie.expiresDate == nil {
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: cookie.name, .value: cookie.value, .domain: cookie.domain, .path: cookie.path, .expires: expiry
            ]
            if cookie.isSecure { props[.secure] = "TRUE" }
            if cookie.isHTTPOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let sameSite = cookie.sameSitePolicy { props[.sameSitePolicy] = sameSite }
            if let renewed = HTTPCookie(properties: props) { await store.setCookie(renewed) }
        }
    }

    // MARK: helpers

    private func withTimeout<T: Sendable>(seconds: Double, _ work: @escaping @MainActor () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SourceError.script("超时（\(Int(seconds)) 秒）")
            }
            guard let first = try await group.next() else { throw SourceError.script("没有结果") }
            group.cancelAll()
            return first
        }
    }
}

/// Waits for one navigation of a WKWebView to finish.
@MainActor
private final class LoadWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?

    func load(_ web: WKWebView, html: String, base: URL) async throws {
        web.navigationDelegate = self
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            continuation = cont
            web.loadHTMLString(html, baseURL: base)
        }
    }

    func load(_ web: WKWebView, request: URLRequest) async throws {
        web.navigationDelegate = self
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            continuation = cont
            web.load(request)
        }
    }

    private func finish(_ error: Error?) {
        guard let cont = continuation else { return }
        continuation = nil
        if let error { cont.resume(throwing: SourceError.script(error.localizedDescription)) } else { cont.resume() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }
}

/// A normal window with the site's login page. The user signs in themselves (password, SMS, QR code, SSO…);
/// the app only watches whether the session becomes valid.
@MainActor
final class LoginWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate {
    /// Calibration mode: record the site's own API traffic and stay open after login.
    struct CaptureOptions {
        let script: String
        let onMessage: (String) -> Void
        let instruction: String
    }

    private final class ScriptHandler: NSObject, WKScriptMessageHandler {
        let onMessage: (String) -> Void
        init(_ onMessage: @escaping (String) -> Void) { self.onMessage = onMessage }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let text = message.body as? String { onMessage(text) }
        }
    }

    private var window: NSWindow?
    /// The page shown in the window (exposed for the self-check).
    var webView: WKWebView? { web }
    private var capture: CaptureOptions?
    private var manualOnly = false
    private var loggedInShown = false
    private var web: WKWebView?
    private var statusLabel: NSTextField?
    private var pollTask: Task<Void, Never>?
    private var finished = false
    private var onFinished: ((Bool) -> Void)?
    private var check: (() async -> Bool)?

    /// `check` is polled every few seconds; the window closes by itself once it returns true.
    func show(title: String, loginURL: URL, check: @escaping () async -> Bool, capture: CaptureOptions? = nil,
              manualOnly: Bool = false, onFinished: @escaping (Bool) -> Void) {
        self.manualOnly = manualOnly
        close(notify: false)
        finished = false
        loggedInShown = false
        self.check = check
        self.onFinished = onFinished
        self.capture = capture

        let config = WebSession.makeConfiguration()
        if let capture {
            config.userContentController.add(ScriptHandler(capture.onMessage), name: "rbcapture")
            config.userContentController.addUserScript(
                WKUserScript(source: capture.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.translatesAutoresizingMaskIntoConstraints = false
        self.web = web

        let label = NSTextField(labelWithString: capture?.instruction
            ?? (manualOnly ? "请在下方登录“\(title)”（如果需要登录），然后停在你想让提醒条盯着的页面，再点右侧“我已登录”。"
                           : "请在下方登录“\(title)”。登录成功后窗口会自动关闭；提醒条不会看到或保存你的密码。"))
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        statusLabel = label

        let doneButton = NSButton(title: capture == nil ? "我已登录" : "完成校准", target: self, action: #selector(doneClicked))
        doneButton.bezelStyle = .rounded
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(label)
        content.addSubview(doneButton)
        content.addSubview(web)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: doneButton.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: doneButton.leadingAnchor, constant: -12),
            doneButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            doneButton.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            web.topAnchor.constraint(equalTo: doneButton.bottomAnchor, constant: 10),
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "登录 \(title)"
        w.contentView = content
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w

        web.load(URLRequest(url: loginURL))
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)

        guard !manualOnly else { return }
        pollTask = Task { [weak self] in
            // Give the page a moment, then look for a valid session every 3 seconds.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            while !Task.isCancelled {
                guard let self, !self.finished, let check = self.check else { return }
                if await check() {
                    if self.capture == nil {
                        self.finish(success: true)
                        return
                    }
                    if !self.loggedInShown {
                        self.loggedInShown = true
                        self.statusLabel?.stringValue = "已登录。请点开左侧的“待办”页面和课程里的作业列表，各停留几秒；完成后点右上角“完成校准”。"
                    }
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    @objc private func doneClicked() {
        if capture != nil || manualOnly {
            finish(success: true)
            return
        }
        statusLabel?.stringValue = "正在确认登录状态…"
        Task { [weak self] in
            guard let self, let check = self.check else { return }
            if await check() {
                self.finish(success: true)
            } else {
                self.statusLabel?.stringValue = "还没有检测到登录。请先在下方完成登录，再点“我已登录”。"
            }
        }
    }

    private func finish(success: Bool) {
        guard !finished else { return }
        finished = true
        pollTask?.cancel()
        let callback = onFinished
        close(notify: false)
        callback?(success)
    }

    func close(notify: Bool) {
        pollTask?.cancel()
        pollTask = nil
        let w = window
        window = nil
        w?.delegate = nil
        w?.close()
        web = nil
        if notify { finish(success: false) }
    }

    func windowWillClose(_ notification: Notification) {
        // The user closed the window without a valid session.
        if !finished {
            finished = true
            pollTask?.cancel()
            let callback = onFinished
            window = nil
            web = nil
            callback?(false)
        }
    }
}
