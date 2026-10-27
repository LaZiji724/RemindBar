import AppKit
import WebKit
import RemindCore

/// Owns the monitored sites: connecting (login), the periodic sync, and what to do when a session expires.
enum SyncOutcome: Equatable {
    case synced(SyncSummary)
    case needsLogin
    case failed(String)
    case alreadyRunning
}

@MainActor
final class SourceCoordinator: ObservableObject {
    private unowned let model: AppModel
    @Published private(set) var syncing: Set<String> = []
    /// True while the refresh button's read of all sites is running.
    @Published private(set) var isRefreshing = false
    private var login: LoginWindowController?
    private var failures: [String: Int] = [:]
    private var nextAttempt: [String: Date] = [:]

    init(model: AppModel) {
        self.model = model
    }

    var pollInterval: TimeInterval {
        let minutes = UserDefaults.standard.integer(forKey: Prefs.Key.pollMinutes)
        return Double(max(minutes, 10)) * 60
    }

    // MARK: connect

    /// For the self-check: the web view of the login window that is currently open.
    var activeLoginWebView: WKWebView? { login?.webView }

    func closeLoginWindow() {
        login?.close(notify: true)
        login = nil
    }

    func connect(_ request: ConnectRequest) {
        let url: URL
        switch request.kind {
        case .canvas: url = request.url ?? IntentRouter.canvasURL
        case .ketangpai: url = request.url ?? IntentRouter.ketangpaiURL
        case .web:
            guard let given = request.url else {
                model.showToast("请把要盯的网址一起说出来或粘贴进来")
                return
            }
            url = given
        case .manual, .apple:
            return
        }
        let host = url.host ?? ""
        var watchers = model.watchers
        let watcher: WatcherConfig
        if let existing = watchers.first(where: { $0.kind == request.kind && URL(string: $0.url)?.host == host }) {
            watcher = existing
        } else {
            watcher = WatcherConfig(kind: request.kind, name: Self.displayName(kind: request.kind, host: host),
                                    url: url.absoluteString, hint: request.hint, lastStatus: "尚未登录")
            watchers.append(watcher)
            model.setWatchers(watchers)
        }
        model.input = ""
        relogin(watcherID: watcher.id)
    }

    static func displayName(kind: SourceKind, host: String) -> String {
        switch kind {
        case .ketangpai: return "课堂派"
        case .canvas: return host == "canvas.tongji.edu.cn" ? "同济 Canvas" : "Canvas · \(host)"
        default: return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
    }

    /// Opens the login window; on success the first sync runs right away.
    func relogin(watcherID: String) {
        guard let watcher = model.watchers.first(where: { $0.id == watcherID }) else { return }
        guard let loginURL = loginURL(for: watcher) else {
            model.showToast("暂不支持这个站点")
            return
        }
        let checker = loginCheck(for: watcher) ?? { false }
        let controller = LoginWindowController()
        login = controller
        controller.show(title: watcher.name, loginURL: loginURL, check: checker, manualOnly: watcher.kind == .web) { [weak self] success in
            guard let self else { return }
            self.login = nil
            guard success else { return }
            self.updateWatcher(watcherID) { $0.needsLogin = false; $0.lastStatus = "已登录，正在同步…" }
            Task {
                await WebSession.shared.persistSessionCookies(domainSuffix: self.cookieDomain(for: watcher))
                await self.sync(watcherID: watcherID, userInitiated: true)
            }
        }
    }

    /// Developer tool: opens 课堂派 and records the read-only API traffic of its own pages for calibration.
    func calibrateKetangpai() {
        let controller = LoginWindowController()
        login = controller
        let capture = LoginWindowController.CaptureOptions(
            script: KetangpaiCapture.script,
            onMessage: { CaptureStore.append(line: $0, to: "ketangpai.jsonl") },
            instruction: "校准模式：请登录课堂派，登录后点开“待办”页面和课程里的作业列表，各停留几秒；完成后点右上角“完成校准”。")
        controller.show(title: "课堂派", loginURL: IntentRouter.ketangpaiURL,
                        check: { await KetangpaiSource(session: WebSession.shared).isLoggedIn() },
                        capture: capture) { [weak self] _ in
            self?.login = nil
            self?.model.showToast("校准样本已保存")
            // Keep the login: session cookies would otherwise be gone after a restart.
            Task { await WebSession.shared.persistSessionCookies(domainSuffix: "ketangpai.com") }
        }
    }

    private func loginURL(for w: WatcherConfig) -> URL? {
        switch w.kind {
        case .canvas:
            return CanvasAPI.base(from: w.url).flatMap { URL(string: "login", relativeTo: $0)?.absoluteURL }
        case .ketangpai:
            return URL(string: "https://www.ketangpai.com/#/login") ?? URL(string: w.url)
        default:
            return URL(string: w.url)
        }
    }

    private func loginCheck(for w: WatcherConfig) -> (() async -> Bool)? {
        switch w.kind {
        case .canvas:
            guard let base = CanvasAPI.base(from: w.url) else { return nil }
            return { await CanvasSource(session: WebSession.shared, base: base).isLoggedIn() }
        case .ketangpai:
            return { await KetangpaiSource(session: WebSession.shared).isLoggedIn() }
        default:
            return nil
        }
    }

    private func cookieDomain(for w: WatcherConfig) -> String {
        switch w.kind {
        case .ketangpai: return "ketangpai.com"
        default:
            // Cookies live on the registrable domain, e.g. "example.edu.cn" for "portal.example.edu.cn".
            let host = URL(string: w.url)?.host ?? ""
            let parts = host.split(separator: ".")
            return parts.count > 2 ? parts.suffix(2).joined(separator: ".") : host
        }
    }

    // MARK: sync

    /// The refresh button: reads EVERY enabled site again right now (no waiting for the timer, no cache), then says what
    /// the sites reported — including "nothing changed", so a press is never silent.
    func refreshAll() {
        guard !isRefreshing else { return }
        let targets = model.watchers.filter { $0.enabled }
        guard !targets.isEmpty else {
            model.showToast("还没有连接网站（设置 › 监控源）")
            return
        }
        isRefreshing = true
        Task { [weak self] in
            guard let self else { return }
            var outcomes: [String: SyncOutcome] = [:]
            await withTaskGroup(of: (String, SyncOutcome).self) { group in
                for w in targets {
                    group.addTask { @MainActor in (w.id, await self.sync(watcherID: w.id, userInitiated: true)) }
                }
                for await (id, outcome) in group { outcomes[id] = outcome }
            }
            self.isRefreshing = false
            self.model.showToast(Self.refreshText(targets: targets, outcomes: outcomes), seconds: 5)
        }
    }

    static func refreshText(targets: [WatcherConfig], outcomes: [String: SyncOutcome]) -> String {
        targets.map { w -> String in
            switch outcomes[w.id] {
            case .synced(let summary): return "\(w.name)：\(summary.text)"
            case .needsLogin: return "\(w.name)：登录已过期，请到设置里重新登录"
            case .failed(let message): return "\(w.name)：读取失败（\(message)）"
            case .alreadyRunning: return "\(w.name)：上一次读取还没结束"
            case nil: return "\(w.name)：没有结果"
            }
        }.joined(separator: "\n")
    }

    /// Opening the panel: if the last read is more than `seconds` old, read again quietly.
    func refreshIfStale(olderThan seconds: TimeInterval = 300) {
        let now = Date()
        for w in model.watchers where w.enabled && !w.needsLogin && w.initialSyncDone && !syncing.contains(w.id) {
            let stale = now.timeIntervalSince(w.lastSyncAt ?? .distantPast) > seconds
            if stale && (nextAttempt[w.id] ?? .distantPast) <= now {
                Task { await sync(watcherID: w.id, userInitiated: false) }
            }
        }
    }

    /// Called about once a minute: syncs whatever is due and not backing off.
    func syncDue() {
        let now = Date()
        // Only sites that were logged in at least once are checked on their own. A first sync that failed
        // (e.g. before the adapter understood the site) is retried too.
        for w in model.watchers where w.enabled && !w.needsLogin
            && (w.initialSyncDone || (w.lastStatus ?? "").hasPrefix("同步失败")) {
            let due = (w.lastSyncAt ?? .distantPast).addingTimeInterval(pollInterval) <= now
            let ready = (nextAttempt[w.id] ?? .distantPast) <= now
            if due && ready && !syncing.contains(w.id) {
                Task { await sync(watcherID: w.id, userInitiated: false) }
            }
        }
    }

    /// Reads one site right now and merges what it says. A pressed refresh button always lands here: the request
    /// goes to the site every time.
    @discardableResult
    func sync(watcherID: String, userInitiated: Bool) async -> SyncOutcome {
        guard let watcher = model.watchers.first(where: { $0.id == watcherID }) else { return .failed("找不到这个网站") }
        guard !syncing.contains(watcherID) else { return .alreadyRunning }
        if watcher.needsLogin && !userInitiated { return .needsLogin }
        syncing.insert(watcherID)
        defer { syncing.remove(watcherID) }

        do {
            let summary: SyncSummary
            if watcher.kind == .web {
                summary = try await syncWeb(watcher, userInitiated: userInitiated)
            } else {
                let items = try await fetchItems(for: watcher)
                let firstSync = !watcher.initialSyncDone
                // 课堂派's to-do list only holds open items, so what disappears from it has been dealt with. Canvas lists a
                // window starting two weeks back; one more day of margin covers time-zone differences at its edge.
                let canvasWindowEdge = Calendar.reminder.date(byAdding: .day, value: -15, to: Date())
                summary = model.applySync(items: items, watcherID: watcherID, silent: firstSync,
                                          completeMissing: watcher.kind == .ketangpai,
                                          retireBefore: watcher.kind == .canvas ? canvasWindowEdge : nil,
                                          notify: !userInitiated)
            }
            failures[watcherID] = 0
            nextAttempt[watcherID] = nil
            await WebSession.shared.persistSessionCookies(domainSuffix: cookieDomain(for: watcher))
            return .synced(summary)
        } catch let error as SourceError {
            return handle(error, watcher: watcher)
        } catch {
            return handle(.script(error.localizedDescription), watcher: watcher)
        }
    }

    private func syncWeb(_ watcher: WatcherConfig, userInitiated: Bool) async throws -> SyncSummary {
        let source = WebPageSource(session: WebSession.shared, ai: model.aiAvailable ? model.ai : nil,
                                   context: { [model] in model.parseContext() })
        let result = try await source.check(watcher)
        return model.applyWebResult(result, watcherID: watcher.id, silent: !watcher.initialSyncDone, notify: !userInitiated)
    }

    private func fetchItems(for w: WatcherConfig) async throws -> [RemoteItem] {
        switch w.kind {
        case .canvas:
            guard let base = CanvasAPI.base(from: w.url) else { throw SourceError.badResponse("网址不对") }
            let source = CanvasSource(session: WebSession.shared, base: base)
            if Prefs.debugCapture {
                // Structure only: field names and types, never course names or titles.
                source.onRawResponse = { CaptureStore.write(JSONShape.describe($0), to: "canvas-shape.txt") }
            }
            return try await source.fetchItems()
        case .ketangpai:
            let source = KetangpaiSource(session: WebSession.shared)
            if Prefs.debugCapture {
                // Structure only: field names and types, never course names or titles.
                source.onRawResponse = { CaptureStore.write(JSONShape.describe($0), to: "ketangpai-shape.txt") }
            }
            return try await source.fetchItems()
        default:
            throw SourceError.badResponse("不支持的类型")
        }
    }

    @discardableResult
    private func handle(_ error: SourceError, watcher: WatcherConfig) -> SyncOutcome {
        if error == .notLoggedIn {
            let wasWorking = watcher.initialSyncDone && !watcher.needsLogin
            updateWatcher(watcher.id) {
                $0.needsLogin = true
                $0.lastStatus = watcher.initialSyncDone ? "登录已过期，需要重新登录" : "尚未登录"
            }
            // One notification per expiry, never a loop, and none for a site that was never logged in.
            if wasWorking {
                NotificationBridge.shared.post(title: "\(watcher.name) 需要重新登录", body: "点开提醒条的设置，在“监控源”里重新登录。")
            }
            return .needsLogin
        }
        let count = (failures[watcher.id] ?? 0) + 1
        failures[watcher.id] = count
        // Back off: 5 min, 10, 20 … at most 4 hours.
        let delay = min(Double(300) * pow(2, Double(count - 1)), 4 * 3_600)
        nextAttempt[watcher.id] = Date().addingTimeInterval(delay)
        updateWatcher(watcher.id) { $0.lastStatus = "同步失败：\(error.message)" }
        return .failed(error.message)
    }

    private func updateWatcher(_ id: String, _ change: (inout WatcherConfig) -> Void) {
        var list = model.watchers
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[i])
        model.setWatchers(list)
    }

    func remove(watcherID: String) {
        model.setWatchers(model.watchers.filter { $0.id != watcherID })
    }

    func setEnabled(_ enabled: Bool, watcherID: String) {
        updateWatcher(watcherID) { $0.enabled = enabled }
    }
}
