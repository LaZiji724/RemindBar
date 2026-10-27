import AppKit
import RemindCore

/// Keeps the app's reminders and Apple's Reminders app in step (see `AppleSyncEngine` for the rules). This class decides
/// when to sync: after a local change, when the Reminders database changes, every few minutes, and when the panel opens.
@MainActor
final class AppleRemindersService: ObservableObject {
    enum Status: Equatable {
        /// Not switched on.
        case off
        /// Waiting for the system's permission dialog.
        case asking
        /// Switched on, but the system has not (or no longer) given access.
        case needsPermission
        case denied
        /// The "提醒条" list was removed in the Reminders app.
        case listMissing
        case idle
        case syncing
        case failed(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var lists: [AppleList] = []
    @Published private(set) var lastReport: AppleSyncEngine.Report?

    private unowned let model: AppModel
    private let makeStore: @MainActor () -> AppleReminderStore
    private var storeBox: AppleReminderStore?
    private var running = false
    private var rerun = false
    /// The permission dialog is brought up at most once per store (that is, once per launch).
    private var askedForAccess = false
    private var debounce: Task<Void, Never>?

    init(model: AppModel, makeStore: @escaping @MainActor () -> AppleReminderStore) {
        self.model = model
        self.makeStore = makeStore
    }

    /// Created on first use: making the store asks for nothing, but there is no reason to touch Reminders while it is off.
    private var store: AppleReminderStore {
        if let storeBox { return storeBox }
        let made = makeStore()
        made.onChange = { [weak self] in self?.storeChanged() }
        storeBox = made
        return made
    }

    /// For the UI smoke test: link to an in-memory stand-in instead of the real Reminders.
    func useStore(_ replacement: AppleReminderStore) {
        replacement.onChange = { [weak self] in self?.storeChanged() }
        storeBox = replacement
        askedForAccess = false
    }

    var config: AppleSyncConfig { model.appleState.config }

    /// For the snapshot tool: shows a given state without talking to Reminders.
    func debugShow(status: Status, lists: [AppleList], report: AppleSyncEngine.Report?) {
        self.status = status
        self.lists = lists
        lastReport = report
    }

    // MARK: lifecycle

    func start() {
        model.onLocalChange = { [weak self] in self?.localChanged() }
        guard config.enabled else { status = .off; return }
        status = .idle
        syncSoon(after: 4)
    }

    func setEnabled(_ on: Bool) {
        if on { Task { await enable() } } else { disable() }
    }

    /// Asks for permission (the first time), makes sure the "提醒条" list exists, and syncs.
    func enable() async {
        status = .asking
        var access = store.access()
        if access == .notDetermined {
            _ = await store.requestAccess()
            access = store.access()
        }
        guard access == .full else {
            model.updateAppleConfig { $0.enabled = false }
            status = access == .notDetermined ? .needsPermission : .denied
            return
        }
        refreshLists()
        guard let list = ensureManagedList() else {
            model.updateAppleConfig { $0.enabled = false }
            status = .failed("没能在提醒事项里建出「\(config.managedListTitle)」列表")
            return
        }
        model.updateAppleConfig { $0.enabled = true; $0.managedListID = list.id }
        let includedDefault = await offerDefaultList(managed: list)
        await syncNow()
        if status == .idle {
            var message = "已开启同步"
            if let report = lastReport { message += "：" + report.text }
            if let includedDefault { message += "。默认列表「\(includedDefault)」也一起同步了（设置 › 提醒事项 里可取消）" }
            model.showToast(message, seconds: 7)
        }
    }

    /// Reminders made with Siri or in the Reminders app land in the default list. When that list is small it is brought
    /// along the first time, so "I added something on my phone" shows up here without a trip to the settings.
    private func offerDefaultList(managed: AppleList) async -> String? {
        guard !config.defaultListOffered else { return nil }
        model.updateAppleConfig { $0.defaultListOffered = true }
        guard config.importListIDs.isEmpty, let id = store.defaultListID(), id != managed.id,
              let list = lists.first(where: { $0.id == id }),
              let open = try? await store.fetchIncomplete(listIDs: [id]), open.count <= AppleSyncEngine.defaultImportLimit else { return nil }
        model.updateAppleConfig { $0.importListIDs = [id] }
        return list.title
    }

    func disable() {
        debounce?.cancel()
        model.updateAppleConfig { $0.enabled = false }
        status = .off
    }

    /// The managed list was removed in the Reminders app: start over with a new one. The reminders stay; only the pairing
    /// with the vanished copies is forgotten, so everything is written out again.
    func recreateList() async {
        guard store.access() == .full else { status = .denied; return }
        model.resetAppleLinks()
        model.updateAppleConfig { $0.managedListID = nil }
        guard let list = ensureManagedList() else {
            status = .failed("没能在提醒事项里建出「\(config.managedListTitle)」列表")
            return
        }
        model.updateAppleConfig { $0.enabled = true; $0.managedListID = list.id }
        await syncNow()
    }

    func refreshLists() {
        lists = store.access() == .full ? store.lists() : []
    }

    private func ensureManagedList() -> AppleList? {
        let all = store.lists()
        if let id = config.managedListID, let found = all.first(where: { $0.id == id }) { return found }
        // A list with that name already there (e.g. after reinstalling the app) is adopted instead of duplicated.
        if let named = all.first(where: { $0.title == config.managedListTitle && $0.writable }) { return named }
        return try? store.createList(title: config.managedListTitle)
    }

    // MARK: triggers

    private func localChanged() {
        guard config.enabled else { return }
        syncSoon(after: 1.5)
    }

    private func storeChanged() {
        guard config.enabled else { return }
        syncSoon(after: 2)
    }

    /// Called about once a minute by the app's clock: syncs when nothing happened for five minutes.
    func tick() {
        guard config.enabled, !running else { return }
        if Date().timeIntervalSince(config.lastSyncAt ?? .distantPast) > 300 { syncSoon(after: 0.2) }
    }

    /// Opening the panel or waking the Mac: look again unless it was looked at a moment ago.
    func refreshIfStale(olderThan seconds: TimeInterval = 60) {
        guard config.enabled, !running else { return }
        if Date().timeIntervalSince(config.lastSyncAt ?? .distantPast) > seconds { syncSoon(after: 0.3) }
    }

    func syncSoon(after delay: TimeInterval) {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            await self.syncNow()
        }
    }

    // MARK: sync

    func syncNow() async {
        guard config.enabled else { return }
        if running {
            rerun = true
            return
        }
        running = true
        defer { running = false }
        repeat {
            rerun = false
            await runOnce()
        } while rerun && config.enabled
    }

    private func runOnce() async {
        let store = self.store
        var access = store.access()
        if access == .notDetermined && !askedForAccess {
            // The system forgets the permission whenever the app is rebuilt (its signature changes). The link is switched
            // on, so ask again, once per launch, instead of letting the sync stop quietly.
            askedForAccess = true
            status = .asking
            _ = await store.requestAccess()
            access = store.access()
            if access != .full {
                model.showToast("提醒事项同步需要你允许提醒条访问“提醒事项”（设置 › 提醒事项）", seconds: 6)
            }
        }
        switch access {
        case .full: break
        case .notDetermined:
            status = .needsPermission
            return
        case .denied, .restricted, .writeOnly:
            status = .denied
            return
        }
        lists = store.lists()
        guard let managedID = config.managedListID, lists.contains(where: { $0.id == managedID }) else {
            status = .listMissing
            return
        }
        status = .syncing
        let importIDs = config.importListIDs.filter { id in id != managedID && lists.contains { $0.id == id } }
        let fetched: [AppleItem]
        do {
            fetched = try await store.fetchIncomplete(listIDs: [managedID] + importIDs)
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        guard config.enabled else { status = .off; return }
        // Nothing below suspends, so the reminder list cannot change between reading it and replacing it.
        let options = AppleSyncEngine.Options(managedListID: managedID, importListIDs: importIDs,
                                              includeWebsiteItems: config.includeWebsiteItems, alarms: config.alarms,
                                              now: Date(), calendar: model.calendar,
                                              defaultHour: Prefs.defaultHour, defaultMinute: Prefs.defaultMinute)
        let result = AppleSyncEngine.merge(reminders: model.reminders, links: model.appleState.links, fetched: fetched,
                                           store: store, options: options)
        model.applyAppleMerge(result)
        lastReport = result.report
        status = .idle
        if !result.report.warnings.isEmpty || !result.report.failures.isEmpty {
            model.showToast("提醒事项：" + (result.report.warnings + result.report.failures).joined(separator: "；"), seconds: 6)
        }
    }

    // MARK: text for the UI

    var statusText: String {
        switch status {
        case .off: return "未开启"
        case .asking: return "正在请求权限…"
        case .needsPermission: return "需要你允许提醒条访问“提醒事项”"
        case .denied: return "没有权限：请在“系统设置 › 隐私与安全性 › 提醒事项”里允许提醒条"
        case .listMissing: return "「\(config.managedListTitle)」列表在提醒事项里被删除了"
        case .idle:
            var text = "已连接"
            if let last = config.lastSyncAt { text += " · 上次同步 " + last.formatted(.dateTime.hour().minute().second()) }
            if let report = lastReport { text += " · " + report.text } else if let status = config.lastStatus { text += " · " + status }
            return text
        case .syncing: return "正在同步…"
        case .failed(let message): return "同步失败：\(message)"
        }
    }
}
