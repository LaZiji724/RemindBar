import Foundation

/// Account details the user chose to save for one site, so an expired session can be renewed without them.
/// Lives only in the login keychain (see `SavedLoginStore` in the app); never in state.json, UserDefaults or logs.
public struct SavedLogin: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var username: String
    public var password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    public var isComplete: Bool {
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    /// Printing a login (print, string interpolation, a crash log) never shows the password.
    public var description: String { "SavedLogin(\(username), 密码已隐藏)" }
    public var debugDescription: String { description }

    /// One keychain item per site: the kind plus the host, so removing and re-adding a site keeps nothing stale.
    public static func siteKey(kind: SourceKind, url: String) -> String {
        let host = URL(string: url)?.host?.lowercased() ?? url.lowercased()
        return "site-login.\(kind.rawValue).\(host)"
    }
}

/// What one run of the login-page script found. Decoded from the JSON the script returns.
public enum AutoLoginStep: Equatable, Sendable {
    /// The account and password were typed in and the login button was pressed.
    case submitted
    /// The page is not ready yet (still loading, or a tab had to be switched to the password form first).
    case waiting(String)
    /// The page wants something only a person can do: a captcha, a slider, a QR code, an SMS code, a second factor.
    case needsHuman(String)
    /// The site said the account or password is wrong.
    case rejected(String)
    /// Nothing that looks like an error or a challenge is on the page.
    case idle

    public static func decode(_ text: String) -> AutoLoginStep {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let step = json["step"] as? String else {
            return .waiting("登录页返回的内容看不懂")
        }
        let reason = Self.clip((json["reason"] as? String) ?? "")
        switch step {
        case "submitted": return .submitted
        case "needsHuman": return .needsHuman(reason.isEmpty ? "登录页需要人工验证" : reason)
        case "rejected": return .rejected(reason.isEmpty ? "账号或密码不对" : reason)
        case "idle": return .idle
        default: return .waiting(reason)
        }
    }

    /// Page text shown to the user is kept short and on one line.
    static func clip(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
    }
}

/// How one automatic login ended.
public enum AutoLoginOutcome: Equatable, Sendable {
    case success
    case needsHuman(String)
    case rejected(String)
    case failed(String)

    /// The sentence shown in the source's status line and in the notification.
    public var message: String {
        switch self {
        case .success: return "已自动重新登录"
        case .needsHuman(let why): return "自动登录停下了：\(why)，请手动登录一次"
        case .rejected(let why): return "自动登录被网站拒绝（\(why)），已停用自动登录，请在设置里重新保存账号"
        case .failed(let why): return "自动登录没有成功（\(why)）"
        }
    }
}

/// When the app may try to log in by itself. Pure bookkeeping so the rules are testable:
/// - only with a saved account and password;
/// - at most one try per expiry, and after a failed try none for `cooldown` (never a loop that could lock the account);
/// - after the site rejected the password, never again until the user saves the account anew.
public struct AutoLoginPolicy: Equatable, Sendable {
    public static let cooldown: TimeInterval = 6 * 3_600

    public private(set) var lastFailure: [String: Date] = [:]
    public private(set) var rejected: Set<String> = []

    public init(rejected: Set<String> = []) {
        self.rejected = rejected
    }

    public func mayTry(siteKey: String, hasSavedLogin: Bool, now: Date) -> Bool {
        guard hasSavedLogin, !rejected.contains(siteKey) else { return false }
        if let last = lastFailure[siteKey], now.timeIntervalSince(last) < Self.cooldown { return false }
        return true
    }

    public mutating func record(_ outcome: AutoLoginOutcome, siteKey: String, now: Date) {
        switch outcome {
        case .success:
            lastFailure[siteKey] = nil
        case .rejected:
            rejected.insert(siteKey)
            lastFailure[siteKey] = now
        case .needsHuman, .failed:
            lastFailure[siteKey] = now
        }
    }

    /// A manual login or a newly saved account starts with a clean slate.
    public mutating func reset(siteKey: String) {
        lastFailure[siteKey] = nil
        rejected.remove(siteKey)
    }
}

/// The scripts run inside the site's own login page. The account and password are passed as `callAsyncJavaScript`
/// arguments (`username`, `password`), never pasted into the script text, so no quoting can break or leak them.
/// The scripts only type into the login form and press its login button: they never tick an agreement box, never
/// touch a captcha or slider, and never follow any other link.
public enum AutoLoginScript {
    /// Shared helpers: visibility, challenge detection and error detection.
    static let prelude = """
    const visible = (el) => {
      if (!el || !el.isConnected) { return false; }
      const style = window.getComputedStyle(el);
      if (style.display === 'none' || style.visibility === 'hidden' || (style.opacity !== '' && Number(style.opacity) === 0)) { return false; }
      const r = el.getBoundingClientRect();
      return (r.width > 0 && r.height > 0) || el.getClientRects().length > 0;
    };
    const textOf = (el) => String((el && (el.innerText || el.textContent)) || '').replace(/\\s+/g, ' ').trim();
    const describe = (el) => [el.name, el.id, el.placeholder, el.getAttribute('aria-label'), el.className]
      .map(v => String(v || '')).join(' ').toLowerCase();
    const codeWords = /验证码|校验码|动态码|短信|captcha|verifycode|verify_code|validcode|valicode|checkcode|authcode|smscode|sms|otp/;
    const challenge = () => {
      for (const input of document.querySelectorAll('input')) {
        if (input.type === 'hidden' || input.type === 'password' || !visible(input)) { continue; }
        if (codeWords.test(describe(input))) { return '登录页要求输入验证码'; }
      }
      for (const el of document.querySelectorAll('[class*="slider" i], [class*="captcha" i], [id*="captcha" i], [class*="geetest" i], [id*="nc_" i], [class*="nc-container" i], [class*="verify" i]')) {
        if (visible(el) && (el.offsetWidth > 30 || el.offsetHeight > 20)) { return '登录页出现了滑块或图形验证'; }
      }
      const body = textOf(document.body);
      if (/二次验证|二次认证|安全验证|身份验证|双因素|短信验证|请拖动|向右滑动|拖动滑块/.test(body)) { return '登录页要求额外的安全验证'; }
      return '';
    };
    const errorText = () => {
      const pattern = /(密码|账号|帐号|用户名|学号|工号)[^。！!]{0,12}(错误|不正确|有误|不存在|不匹配)|错误次数|已被锁定|账号锁定|invalid (user|password|credentials)|incorrect/i;
      for (const el of document.querySelectorAll('[class*="error" i], [class*="message" i], [class*="msg" i], [class*="tip" i], [class*="toast" i], [class*="alert" i], [role="alert"], .el-message, .ant-message')) {
        if (!visible(el)) { continue; }
        const t = textOf(el);
        if (t.length > 0 && t.length < 120 && pattern.test(t)) { return t; }
      }
      return '';
    };
    const answer = (step, reason) => JSON.stringify({step: step, reason: reason || ''});
    """

    /// Fills the form and presses the login button, or explains why it can't (yet).
    public static let fill = prelude + """
    const blocked = challenge();
    if (blocked) { return answer('needsHuman', blocked); }
    const err = errorText();
    if (err) { return answer('rejected', err); }

    const passwords = Array.from(document.querySelectorAll('input[type="password"]')).filter(visible);
    if (passwords.length === 0) {
      // Many school pages open on a QR-code tab: switch to the account/password tab once, then look again.
      const tabWords = /^(账号登录|帐号登录|密码登录|账号密码登录|帐号密码登录|用户名密码登录|统一身份认证登录|学号登录)$/;
      for (const el of document.querySelectorAll('a, button, span, div, li, label')) {
        if (!visible(el) || el.children.length > 2) { continue; }
        if (tabWords.test(textOf(el))) { el.click(); return answer('waiting', '切换到账号密码登录'); }
      }
      return answer('waiting', '还没有找到密码输入框');
    }
    if (passwords.length > 1) { return answer('needsHuman', '登录页有多个密码框，可能是在要求修改密码'); }
    const pwd = passwords[0];
    const scope = pwd.closest('form') || document;

    const textTypes = ['text', 'email', 'tel', 'number', ''];
    const candidates = Array.from(scope.querySelectorAll('input'))
      .filter(i => textTypes.includes((i.getAttribute('type') || '').toLowerCase()) && visible(i) && !i.disabled && !i.readOnly)
      .filter(i => !codeWords.test(describe(i)));
    // The account box is the last text box before the password box.
    const before = candidates.filter(i => i.compareDocumentPosition(pwd) & Node.DOCUMENT_POSITION_FOLLOWING);
    const user = before.length > 0 ? before[before.length - 1] : candidates[0];
    if (!user) { return answer('needsHuman', '没有找到账号输入框'); }

    // Vue / React keep their own copy of the value: use the native setter, then fire the events they listen to.
    const setValue = (el, value) => {
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      el.focus();
      setter.call(el, value);
      el.dispatchEvent(new Event('input', {bubbles: true}));
      el.dispatchEvent(new Event('change', {bubbles: true}));
      el.dispatchEvent(new Event('blur', {bubbles: true}));
    };
    setValue(user, String(username));
    setValue(pwd, String(password));

    // An unticked agreement box is the user's to tick; the app never agrees to anything on their behalf.
    for (const box of scope.querySelectorAll('input[type="checkbox"]')) {
      const label = textOf(box.closest('label') || box.parentElement);
      if (/协议|同意|阅读|条款|隐私/.test(label) && !box.checked) {
        return answer('needsHuman', '登录页要求勾选用户协议');
      }
    }

    const loginWords = /^(登\\s*录|立即登录|登录\\s*\\/\\s*注册|log\\s*in|sign\\s*in)$/i;
    let button = scope.querySelector('button[type="submit"], input[type="submit"]');
    if (!button || !visible(button)) {
      // A wrapper around the button has the same text; take the innermost match, real buttons first.
      const matches = Array.from(scope.querySelectorAll('button, input[type="button"], a, div, span'))
        .filter(el => visible(el) && loginWords.test(textOf(el) || String(el.value || '')));
      const innermost = matches.filter(el => !matches.some(other => other !== el && el.contains(other)));
      button = innermost.find(el => el.tagName === 'BUTTON' || el.tagName === 'INPUT') || innermost[0];
    }
    if (button) {
      button.click();
    } else if (scope.tagName === 'FORM' && typeof scope.requestSubmit === 'function') {
      scope.requestSubmit();
    } else {
      return answer('needsHuman', '没有找到登录按钮');
    }
    return answer('submitted', '');
    """

    /// Looks at the page after the login button was pressed: an error message, or a challenge that appeared.
    public static let inspect = prelude + """
    const err = errorText();
    if (err) { return answer('rejected', err); }
    const blocked = challenge();
    if (blocked) { return answer('needsHuman', blocked); }
    return answer('idle', '');
    """
}
