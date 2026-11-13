import AppKit
import WebKit
import RemindCore

/// Saved accounts for automatic re-login. The account and password live together in one keychain item per site;
/// only the account name (no secret) is mirrored in UserDefaults so the settings page can show it without asking
/// the keychain (which may prompt after every rebuild).
enum SavedLoginStore {
    private static let namesKey = "savedLoginNames"
    private static let rejectedKey = "autoLoginRejected"

    static func load(siteKey: String) -> SavedLogin? {
        guard let text = KeychainStore.read(account: siteKey), let data = text.data(using: .utf8),
              let login = try? JSONDecoder().decode(SavedLogin.self, from: data), login.isComplete else { return nil }
        return login
    }

    @discardableResult
    static func save(_ login: SavedLogin, siteKey: String) -> Bool {
        guard login.isComplete, let data = try? JSONEncoder().encode(login), let text = String(data: data, encoding: .utf8),
              KeychainStore.write(text, account: siteKey) else { return false }
        var names = savedNames
        names[siteKey] = login.username
        UserDefaults.standard.set(names, forKey: namesKey)
        return true
    }

    static func delete(siteKey: String) {
        KeychainStore.delete(account: siteKey)
        var names = savedNames
        names[siteKey] = nil
        UserDefaults.standard.set(names, forKey: namesKey)
    }

    /// The account name shown in settings, or nil when nothing is saved.
    static func username(siteKey: String) -> String? { savedNames[siteKey] }

    private static var savedNames: [String: String] {
        (UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String]) ?? [:]
    }

    /// Sites whose password the site rejected; kept across restarts so a wrong password is never retried.
    static var rejectedSites: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: rejectedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: rejectedKey) }
    }
}

/// Logs in by itself in a hidden web view that shares the app's WebKit store, so a successful login renews exactly the
/// session the sources read from. It types the saved account into the site's own login page and presses its login
/// button (ticking the form's user-agreement box if there is one): captchas, sliders, QR codes and SMS codes stop it
/// and are left to the user.
@MainActor
final class AutoLoginRunner {
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    /// `check` is the same "is the session valid" probe the login window uses.
    func run(loginURL: URL, login: SavedLogin, check: @escaping () async -> Bool) async -> AutoLoginOutcome {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: WebSession.makeConfiguration())
        web.customUserAgent = Self.userAgent
        defer { web.stopLoading() }
        web.load(URLRequest(url: loginURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 40))

        // Phase 1: wait for the form (single-page apps render late), then fill it in and press the button once.
        var submitted = false
        var lastWait = "登录页没有打开"
        var checkedAfterLoad = false
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !web.isLoading else { continue }
            // Once the page has loaded: a session that is valid again needs no typing at all (the school's SSO may
            // have remembered the user and sent the browser straight back).
            if !checkedAfterLoad {
                checkedAfterLoad = true
                if await check() { return .success }
            }
            switch await step(web, script: AutoLoginScript.fill, login: login) {
            case .submitted: submitted = true
            case .needsHuman(let why): return .needsHuman(why)
            case .rejected(let why): return .rejected(why)
            case .waiting(let why): lastWait = why.isEmpty ? lastWait : why
            case .idle: break
            }
            if submitted { break }
        }
        guard submitted else { return .needsHuman(lastWait == "还没有找到密码输入框" ? "没有找到账号密码登录框" : lastWait) }

        // Phase 2: the site redirects (SSO) and sets cookies; watch for success, an error message or a challenge.
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if await check() { return .success }
            guard !web.isLoading else { continue }
            switch await step(web, script: AutoLoginScript.inspect, login: nil) {
            case .rejected(let why): return .rejected(why)
            case .needsHuman(let why): return .needsHuman(why)
            default: continue
            }
        }
        return .failed("按下登录后 30 秒仍未登录成功")
    }

    private func step(_ web: WKWebView, script: String, login: SavedLogin?) async -> AutoLoginStep {
        var arguments: [String: Any] = [:]
        if let login {
            arguments["username"] = login.username
            arguments["password"] = login.password
        }
        do {
            let value = try await web.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
            return AutoLoginStep.decode((value as? String) ?? "")
        } catch {
            // Mid-navigation the page can vanish under the script; that's a "try again", not a failure.
            return .waiting("")
        }
    }
}
