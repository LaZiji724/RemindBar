import Foundation
import RemindCore

/// Automatic re-login with a saved account: the retry rules, how the login-page script's answers are read, and that the
/// password never leaks into text.
enum AutoLoginTests {
    static func run(_ h: Harness) {
        h.suite = "auto-login"
        let now = Fixture.now
        let canvas = SavedLogin.siteKey(kind: .canvas, url: "https://canvas.tongji.edu.cn/courses/1")
        let ktp = SavedLogin.siteKey(kind: .ketangpai, url: "https://www.ketangpai.com/#/main")

        // Keys: one per site, independent of the page the site was added with.
        h.equal(canvas, "site-login.canvas.canvas.tongji.edu.cn", "canvas key is kind + host")
        h.equal(SavedLogin.siteKey(kind: .canvas, url: "https://Canvas.Tongji.edu.cn/"), canvas, "host is case-insensitive")
        h.equal(ktp, "site-login.ketangpai.www.ketangpai.com", "课堂派 key is kind + host")

        // The password never shows up in text.
        let login = SavedLogin(username: "2350001", password: "s3cr3t-密码")
        h.check(!"\(login)".contains("s3cr3t"), "description hides the password")
        h.check(!String(reflecting: login).contains("s3cr3t"), "debug description hides the password")
        h.check(login.isComplete, "account + password is complete")
        h.check(!SavedLogin(username: "  ", password: "x").isComplete, "a blank account is not complete")
        h.check(!SavedLogin(username: "a", password: "").isComplete, "an empty password is not complete")
        if let data = try? JSONEncoder().encode(login), let back = try? JSONDecoder().decode(SavedLogin.self, from: data) {
            h.equal(back, login, "keychain JSON round-trips")
        } else {
            h.check(false, "keychain JSON round-trips")
        }

        // The scripts take the account as arguments and never contain a value.
        for (name, script) in [("fill", AutoLoginScript.fill), ("inspect", AutoLoginScript.inspect)] {
            h.check(!script.contains("s3cr3t") && !script.contains("2350001"), "\(name) script holds no account data")
            h.check(!script.contains("checked = true") && !script.contains(".checked=true"), "\(name) script never ticks a box")
        }
        h.check(AutoLoginScript.fill.contains("String(username)") && AutoLoginScript.fill.contains("String(password)"),
                "fill script reads the callAsyncJavaScript arguments")
        h.check(!AutoLoginScript.inspect.contains("password)"), "inspect script never touches the password")

        // Reading the script's answers.
        h.equal(AutoLoginStep.decode(#"{"step":"submitted","reason":""}"#), .submitted, "submitted")
        h.equal(AutoLoginStep.decode(#"{"step":"needsHuman","reason":"登录页出现了滑块或图形验证"}"#),
                .needsHuman("登录页出现了滑块或图形验证"), "needs a person")
        h.equal(AutoLoginStep.decode(#"{"step":"rejected","reason":"用户名或密码错误"}"#), .rejected("用户名或密码错误"), "rejected")
        h.equal(AutoLoginStep.decode(#"{"step":"rejected","reason":""}"#), .rejected("账号或密码不对"), "rejected without text")
        h.equal(AutoLoginStep.decode(#"{"step":"idle"}"#), .idle, "idle")
        h.equal(AutoLoginStep.decode(#"{"step":"waiting","reason":"还没有找到密码输入框"}"#), .waiting("还没有找到密码输入框"), "waiting")
        h.equal(AutoLoginStep.decode("not json"), .waiting("登录页返回的内容看不懂"), "garbage means wait")
        if case .rejected(let text) = AutoLoginStep.decode(#"{"step":"rejected","reason":"\#(String(repeating: "错", count: 200))"}"#) {
            h.check(text.count <= 61, "long page text is clipped", "\(text.count)")
        } else {
            h.check(false, "long page text is clipped")
        }

        // Retry rules.
        var policy = AutoLoginPolicy()
        h.check(!policy.mayTry(siteKey: canvas, hasSavedLogin: false, now: now), "no saved account, no try")
        h.check(policy.mayTry(siteKey: canvas, hasSavedLogin: true, now: now), "saved account: may try")
        policy.record(.needsHuman("滑块"), siteKey: canvas, now: now)
        h.check(!policy.mayTry(siteKey: canvas, hasSavedLogin: true, now: now.addingTimeInterval(60)), "after a failed try: no loop")
        h.check(!policy.mayTry(siteKey: canvas, hasSavedLogin: true, now: now.addingTimeInterval(5 * 3_600)), "…not within the cooldown")
        h.check(policy.mayTry(siteKey: canvas, hasSavedLogin: true, now: now.addingTimeInterval(6 * 3_600 + 1)), "…but after it")
        h.check(policy.mayTry(siteKey: ktp, hasSavedLogin: true, now: now), "another site is not affected")
        policy.record(.success, siteKey: canvas, now: now)
        h.check(policy.mayTry(siteKey: canvas, hasSavedLogin: true, now: now), "a success clears the cooldown")

        policy.record(.rejected("密码错误"), siteKey: ktp, now: now)
        h.check(!policy.mayTry(siteKey: ktp, hasSavedLogin: true, now: now.addingTimeInterval(30 * 86_400)), "a rejected password is never retried")
        h.check(policy.rejected.contains(ktp), "rejection is remembered")
        let restored = AutoLoginPolicy(rejected: policy.rejected)
        h.check(!restored.mayTry(siteKey: ktp, hasSavedLogin: true, now: now), "…also after a restart")
        policy.reset(siteKey: ktp)
        h.check(policy.mayTry(siteKey: ktp, hasSavedLogin: true, now: now), "saving the account again re-enables it")

        // What the user is told.
        h.check(AutoLoginOutcome.rejected("密码错误").message.contains("停用"), "rejection says auto-login is off")
        h.check(AutoLoginOutcome.needsHuman("滑块").message.contains("手动登录"), "a challenge asks for a manual login")
    }
}
