import AppKit
import Combine
import RemindCore

/// What one read of a site changed.
struct SyncSummary: Equatable {
    var added = 0
    var completed = 0
    var reopened = 0
    var changedDue = 0
    var retired = 0
    var open = 0
    /// Open on the website, but the user chose not to be reminded about them.
    var ignored = 0

    var isEmpty: Bool { added + completed + reopened + changedDue + retired == 0 }

    var text: String {
        var parts: [String] = []
        if added > 0 { parts.append("新增 \(added) 项") }
        if completed > 0 { parts.append("网站上已完成 \(completed) 项") }
        if reopened > 0 { parts.append("重新变为待办 \(reopened) 项") }
        if changedDue > 0 { parts.append("截止时间变了 \(changedDue) 项") }
        if retired > 0 { parts.append("逾期太久、网站不再列出 \(retired) 项（已移出）") }
        let tail = ignored > 0 ? "，另有 \(ignored) 项已忽略" : ""
        return (parts.isEmpty ? "没有变化，共 \(open) 项待办" : parts.joined(separator: "，") + "，共 \(open) 项待办") + tail
    }
}

struct ReminderSection: Identifiable {
    let bucket: DayBucket
    let items: [Reminder]
    var id: Int { bucket.rawValue }
}

/// Microphone level lives in its own object so ~15 updates per second only redraw the mic button.
@MainActor
final class VoiceMeter: ObservableObject {
    @Published var level: Float = 0
}

@MainActor
final class AppModel: ObservableObject {
    // MARK: published state
    @Published private(set) var reminders: [Reminder] = []
    @Published private(set) var watchers: [WatcherConfig] = []
    /// Settings and pairings of the link with Apple's Reminders app.
    @Published private(set) var appleState = AppleSyncState()
    @Published var input: String = "" {
        didSet { if input != oldValue { refreshPreview() } }
    }
    @Published private(set) var preview: [ParsedEvent] = []
    @Published private(set) var intent: Intent = .empty
    @Published private(set) var now: Date = Date()
    @Published var highlightedID: UUID?
    @Published var toast: String?
    /// Ids that "撤销" in the toast removes again (auto-added by voice).
    @Published private(set) var undoIDs: [UUID] = []
    /// An item the toast's "撤销" brings back after it was ignored.
    @Published private(set) var undoIgnoreID: UUID?
    /// Whether the panel lists the ignored items.
    @Published var showIgnored = false
    @Published var showCompleted = false
    @Published private(set) var voiceState: VoiceState = .idle
    /// macOS has notifications switched off for this app: due alerts would be silent.
    @Published private(set) var notificationsDenied = false
    @Published private(set) var aiBusy = false
    @Published private(set) var aiTokensToday = 0
    @Published private(set) var aiNotice: String?
    /// Bumped whenever the panel should put the cursor into the input field.
    @Published var focusRequest = 0
    /// Fixes "now" for snapshots; nil in normal operation.
    var clockOverride: Date?

    let meter = VoiceMeter()

    // MARK: callbacks wired by the app delegate
    var onFires: (([Fire], [Reminder]) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenSettingsTab: ((SettingsTab) -> Void)?
    var onConnectRequest: ((ConnectRequest) -> Void)?
    var onRemindersChanged: (() -> Void)?
    /// A change made here (as opposed to one taken over from Apple's Reminders); the Reminders link syncs on it.
    var onLocalChange: (() -> Void)?

    // MARK: plumbing
    private let store: JSONStore<AppState>
    private var lastFireCheck = Date()
    private var timer: Timer?
    private var tickCount = 0
    private var lastScheduleDay = Date()
    private var toastTask: Task<Void, Never>?
    private lazy var voice: VoiceSession = makeVoiceSession()
    lazy var ai: AIService = makeAI()
    lazy var sources = SourceCoordinator(model: self)
    lazy var apple = AppleRemindersService(model: self, makeStore: { EventKitStore() })
    private var inputBeforeVoice = ""

    var calendar: Calendar { .reminder }

    init(storeURL: URL? = nil, loadFromDisk: Bool = true) {
        self.store = JSONStore<AppState>(url: storeURL ?? AppModel.defaultStoreURL())
        if loadFromDisk {
            do {
                if let state = try store.load() {
                    reminders = state.reminders
                    watchers = state.watchers
                    appleState = state.apple ?? AppleSyncState()
                }
            } catch {
                toast = "读取数据失败，已从空白开始：\(error.localizedDescription)"
            }
            // Earlier versions let Canvas / 课堂派 items be deleted by hand. Now the website decides, so forget those marks
            // and read the site again at once: whatever it still lists as open comes back, whatever is done stays gone.
            var migrated = false
            for i in watchers.indices where watchers[i].kind.completionFollowsSite && !watchers[i].deletedKeys.isEmpty {
                watchers[i].deletedKeys = []
                watchers[i].lastSyncAt = nil
                migrated = true
            }
            // Each reminder saves its own alert schedule: bring the ones made before the 3-minute warning up to date.
            if LeadTimes.upgrade(&reminders) { migrated = true }
            if migrated { save() }
        }
    }

    nonisolated static func defaultStoreURL() -> URL {
        // `--data-dir <dir>` isolates a run (used by the UI smoke test) from the user's real data.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count {
            return URL(fileURLWithPath: args[i + 1], isDirectory: true).appendingPathComponent("state.json")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("RemindBar", isDirectory: true).appendingPathComponent("state.json")
    }

    func refreshNotificationStatus() {
        Task { [weak self] in
            let status = await NotificationBridge.shared.authorizationStatus()
            self?.notificationsDenied = (status == .denied)
        }
    }

    func start() {
        lastFireCheck = Date()
        refreshNotificationStatus()
        // A first look at the connected sites shortly after launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            MainActor.assumeIsolated {
                self?.sources.syncDue()
                // The app may have been closed for hours: look at the sites again unless they were read a moment ago.
                self?.sources.refreshIfStale(olderThan: 120)
            }
        }
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        save()
    }

    // MARK: parsing

    func parseContext(at date: Date? = nil) -> ParseContext {
        ParseContext(now: date ?? clockOverride ?? Date(), calendar: calendar,
                     defaultHour: Prefs.defaultHour, defaultMinute: Prefs.defaultMinute)
    }

    private func refreshPreview() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            intent = .empty
            preview = []
            return
        }
        let ctx = parseContext()
        intent = IntentRouter.route(text, context: ctx)
        if case .reminder = intent {
            preview = NLParser.parse(text, context: ctx)
        } else {
            preview = []
        }
    }

    /// Return key in the input field.
    func commitInput() {
        switch intent {
        case .reminder:
            // Optionally let DeepSeek read a sentence the local parser could not understand, before adding it.
            if UserDefaults.standard.bool(forKey: Prefs.Key.aiTypedAuto), aiAvailable, needsAIHelp {
                parseWithAI()
            } else {
                addFromPreview()
            }
        case .connect(let request): onConnectRequest?(request)
        case .empty: break
        }
    }

    @discardableResult
    func addFromPreview(undoable: Bool = false) -> [UUID] {
        guard !preview.isEmpty else { return [] }
        let stamp = Date()
        let added = preview.map { Reminder(from: $0, now: stamp) }
        reminders.append(contentsOf: added)
        input = ""
        changed()
        let ids = added.map(\.id)
        showToast(added.count == 1 ? "已添加" : "已添加 \(added.count) 条提醒", undo: undoable ? ids : [])
        return ids
    }

    /// Swap the chosen moment with its alternative reading (AM/PM flip, or "tomorrow" for a time that already passed).
    func useAlternative(at index: Int) {
        guard preview.indices.contains(index), let alt = preview[index].alternative, let due = preview[index].due else { return }
        preview[index].due = alt
        preview[index].alternative = due
        if alt < (clockOverride ?? Date()) { preview[index].flags.insert(.past) } else { preview[index].flags.remove(.past) }
        preview[index].flags.remove(.rolledForward)
    }

    // MARK: AI

    nonisolated static func supportDirectory() -> URL {
        defaultStoreURL().deletingLastPathComponent()
    }

    private func makeAI() -> AIService {
        let dir = AppModel.supportDirectory()
        let ledger = UsageLedger(store: JSONStore(url: dir.appendingPathComponent("ai-usage.json")))
        let cache = AICache(store: JSONStore(url: dir.appendingPathComponent("ai-cache.json")))
        let client = DeepSeekClient(keyProvider: { KeyBox.shared.key })
        let gate = AIGate(client: client, ledger: ledger, cache: cache, config: { AppModel.aiConfig() })
        aiTokensToday = ledger.tokens(on: Date())
        return AIService(gate: gate)
    }

    static func aiConfig() -> AIConfig {
        let d = UserDefaults.standard
        return AIConfig(enabled: d.bool(forKey: Prefs.Key.aiEnabled),
                        dailyBudget: d.integer(forKey: Prefs.Key.aiDailyBudget),
                        monthlyBudget: d.integer(forKey: Prefs.Key.aiMonthlyBudget),
                        perSourceDailyCap: AIPolicy.defaultPerSourceDailyCap)
    }

    /// Cheap check for the UI; does not read the keychain.
    var aiAvailable: Bool { Prefs.aiEnabled && Prefs.aiKeyPresent }

    /// True while some previewed sentence is something the local parser could not make sense of.
    var needsAIHelp: Bool {
        preview.contains { $0.confidence == .low && !$0.flags.contains(.aiAssisted) }
    }

    func saveAIKey(_ key: String) -> Bool {
        let ok = KeyBox.shared.save(key)
        if ok { ai.gate.clearBlock() }
        objectWillChange.send()
        return ok
    }

    func removeAIKey() {
        KeyBox.shared.save(nil)
        objectWillChange.send()
    }

    func resetAIBreaker() {
        ai.gate.ledger.closeBreaker()
        ai.gate.clearBlock()
        aiNotice = nil
        objectWillChange.send()
    }

    /// Reads the current sentence with DeepSeek (one small call) and replaces the preview with the validated answer.
    func parseWithAI() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !aiBusy, case .reminder = intent else { return }
        aiBusy = true
        aiNotice = nil
        let ctx = parseContext()
        Task { [weak self] in
            guard let self else { return }
            let outcome = await ai.parseReminders(text, context: ctx)
            aiBusy = false
            aiTokensToday = ai.gate.ledger.tokens(on: Date())
            // The user may have kept typing; only apply the answer to the sentence it was asked about.
            guard input.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
            switch outcome {
            case .events(let events, _):
                preview = events
            case .skipped(let reason):
                aiNotice = reason.message
            case .failed(let error):
                aiNotice = error.message
            }
        }
    }

    // MARK: reminders

    /// Items from Canvas / 课堂派 are finished or not according to the website; there is no manual "done" for them.
    func canComplete(_ id: UUID) -> Bool {
        reminders.first { $0.id == id }.map { !$0.completionFollowsSite } ?? false
    }

    func toggleDone(_ id: UUID) {
        guard let i = reminders.firstIndex(where: { $0.id == id }), !reminders[i].completionFollowsSite else { return }
        if reminders[i].status == .pending {
            reminders[i].status = .done
            reminders[i].completedAt = Date()
            reminders[i].snoozedUntil = nil
        } else {
            reminders[i].status = .pending
            reminders[i].completedAt = nil
        }
        changed()
    }

    func complete(_ id: UUID) {
        guard let i = reminders.firstIndex(where: { $0.id == id }), reminders[i].status == .pending else { return }
        toggleDone(id)
    }

    /// Items from Canvas / 课堂派 stay until the website says they are done; deleting one would silently drop a deadline.
    func canDelete(_ id: UUID) -> Bool {
        reminders.first { $0.id == id }.map { !$0.completionFollowsSite } ?? false
    }

    func delete(_ id: UUID) {
        guard canDelete(id) else { return }
        // A deleted item from a generic page must not be re-created by the next read.
        if let r = reminders.first(where: { $0.id == id }), let watcherID = r.watcherID, let key = r.externalKey,
           let i = watchers.firstIndex(where: { $0.id == watcherID }), !watchers[i].deletedKeys.contains(key) {
            watchers[i].deletedKeys.append(key)
        }
        reminders.removeAll { $0.id == id }
        changed()
    }

    // MARK: ignoring

    /// Website items cannot be deleted, so "ignore" is how the user stops being reminded about one. It stays tracked (the
    /// website still decides when it is done) and can be restored at any time.
    func canIgnore(_ id: UUID) -> Bool {
        reminders.first { $0.id == id }.map { $0.completionFollowsSite && $0.status == .pending && !$0.ignored } ?? false
    }

    func ignore(_ id: UUID) {
        guard canIgnore(id), let i = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[i].ignored = true
        reminders[i].snoozedUntil = nil
        let title = reminders[i].title
        changed()
        showToast("已忽略「\(title)」，不再提醒；网站标记完成或不再列出后会自动清掉", undoIgnore: id, seconds: 6)
    }

    func unignore(_ id: UUID) {
        guard let i = reminders.firstIndex(where: { $0.id == id }), reminders[i].ignored else { return }
        reminders[i].ignored = false
        let title = reminders[i].title
        changed()
        showToast("已恢复提醒：\(title)")
    }

    /// Open website items the user chose to ignore, soonest deadline first.
    var ignoredItems: [Reminder] {
        reminders.filter { $0.ignored && $0.status == .pending }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    /// Stores what a generic-page check found and keeps its snapshot / AI bookkeeping.
    @discardableResult
    func applyWebResult(_ result: WebPageSource.Result, watcherID: String, silent: Bool, notify: Bool = true) -> SyncSummary {
        guard let wi = watchers.firstIndex(where: { $0.id == watcherID }) else { return SyncSummary() }
        if result.advanceSnapshot {
            watchers[wi].pageHash = result.fingerprint
            watchers[wi].pageLines = result.lines
        }
        watchers[wi].aiEmptyStreak = result.aiEmptyStreak
        watchers[wi].aiPausedUntil = result.aiPausedUntil
        aiTokensToday = ai.gate.ledger.tokens(on: Date())
        return applySync(items: result.items, watcherID: watcherID, silent: silent, note: result.note, notify: notify)
    }

    /// Merges the result of a site sync into the list and tells the user about news.
    @discardableResult
    func applySync(items: [RemoteItem], watcherID: String, silent: Bool, note: String? = nil, completeMissing: Bool = false,
                   retireBefore: Date? = nil, notify: Bool = true) -> SyncSummary {
        guard let wi = watchers.firstIndex(where: { $0.id == watcherID }) else { return SyncSummary() }
        let watcher = watchers[wi]
        let stamp = Date()
        let result = SyncEngine.reconcile(existing: reminders, remote: items, watcher: watcher, now: stamp,
                                          completeMissing: completeMissing, retireBefore: retireBefore)
        reminders = result.reminders
        let mine = result.reminders.filter { $0.watcherID == watcherID && $0.status == .pending }
        let open = mine.filter { !$0.ignored }.count
        let ignoredCount = mine.count - open
        watchers[wi].lastSyncAt = stamp
        watchers[wi].needsLogin = false
        watchers[wi].initialSyncDone = true
        watchers[wi].lastStatus = note.flatMap { $0.isEmpty ? nil : "\($0) · 共 \(open) 项待办" } ?? "已同步 · \(open) 项待办"
        changed()

        let summary = SyncSummary(added: result.added.count, completed: result.autoCompleted.count,
                                  reopened: result.reopened.count, changedDue: result.changedDue.count,
                                  retired: result.retired.count, open: open, ignored: ignoredCount)
        if silent {
            showToast("已从\(watcher.name)导入 \(result.added.count) 项待办")
            return summary
        }
        // Someone pressing refresh is looking at the panel already; system notifications are for background checks.
        guard notify else { return summary }
        if !result.added.isEmpty {
            let names = result.added.prefix(3).map(\.title).joined(separator: "、")
            NotificationBridge.shared.post(title: "\(watcher.name) 有 \(result.added.count) 个新作业",
                                           body: result.added.count > 3 ? "\(names) 等" : names)
        }
        let moved = result.changedDue.filter { !$0.reminder.ignored }
        if !moved.isEmpty {
            let names = moved.prefix(3).map { $0.reminder.title }.joined(separator: "、")
            NotificationBridge.shared.post(title: "\(watcher.name) 的截止时间有变化", body: names)
        }
        return summary
    }

    func undoLastAdd() {
        let ids = Set(undoIDs)
        guard !ids.isEmpty else { return }
        reminders.removeAll { ids.contains($0.id) }
        undoIDs = []
        changed()
        showToast("已撤销")
    }

    func snooze(_ id: UUID, minutes: Int) {
        guard let i = reminders.firstIndex(where: { $0.id == id }) else { return }
        reminders[i].snoozedUntil = Date().addingTimeInterval(Double(minutes) * 60)
        changed()
        showToast("\(minutes >= 60 ? "\(minutes / 60)小时" : "\(minutes)分钟")后再提醒")
    }

    func snoozeUntilTomorrow(_ id: UUID) {
        guard let i = reminders.firstIndex(where: { $0.id == id }) else { return }
        let cal = calendar
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date().addingTimeInterval(86_400)
        reminders[i].snoozedUntil = cal.date(bySettingHour: Prefs.defaultHour, minute: Prefs.defaultMinute, second: 0, of: tomorrow)
        changed()
        showToast("明天再提醒")
    }

    func replaceReminders(_ newValue: [Reminder]) {
        reminders = newValue
        changed()
    }

    func setWatchers(_ newValue: [WatcherConfig]) {
        watchers = newValue
        save()
    }

    private func changed() {
        save()
        onRemindersChanged?()
        onLocalChange?()
    }

    // MARK: Apple Reminders link

    func updateAppleConfig(_ change: (inout AppleSyncConfig) -> Void) {
        change(&appleState.config)
        save()
    }

    /// Forgets which Apple reminder belongs to which of ours (the reminders themselves are untouched).
    func resetAppleLinks() {
        appleState.links = []
        save()
    }

    /// Takes over the result of a sync with Apple's Reminders. It replaces the reminder list in one go (the sync ran without
    /// suspending, so nothing changed meanwhile) and does not count as a local change, so it does not trigger another sync.
    func applyAppleMerge(_ result: AppleSyncEngine.Result) {
        let remindersChanged = result.reminders != reminders
        if remindersChanged { reminders = result.reminders }
        appleState.links = result.links
        appleState.config.lastSyncAt = Date()
        appleState.config.lastStatus = result.report.text
        save()
        if remindersChanged { onRemindersChanged?() }
    }

    func save() {
        var state = AppState()
        state.reminders = reminders
        state.watchers = watchers
        state.lastFireCheck = lastFireCheck
        state.apple = appleState == AppleSyncState() ? nil : appleState
        do { try store.save(state) } catch { toast = "保存失败：\(error.localizedDescription)" }
    }

    func showToast(_ text: String, undo: [UUID] = [], undoIgnore: UUID? = nil, seconds: Double? = nil) {
        toast = text
        undoIDs = undo
        undoIgnoreID = undoIgnore
        toastTask?.cancel()
        let seconds = UInt64((seconds ?? (undo.isEmpty && undoIgnore == nil ? 2.5 : 6)) * 1_000_000_000)
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.toast = nil
                self?.undoIDs = []
                self?.undoIgnoreID = nil
            }
        }
    }

    var toastCanUndo: Bool { !undoIDs.isEmpty || undoIgnoreID != nil }

    /// The toast's "撤销".
    func undoFromToast() {
        if let id = undoIgnoreID {
            unignore(id)
        } else {
            undoLastAdd()
        }
    }

    // MARK: voice

    private func makeVoiceSession() -> VoiceSession {
        let session = VoiceSession(recognizer: AppleSpeechRecognizer())
        session.onChange = { [weak self] in self?.voiceStateChanged() }
        session.onLevel = { [weak self] level in self?.meter.level = level }
        session.onTranscript = { [weak self] text, final in self?.voiceTranscript(text, final: final) }
        return session
    }

    var voiceOptions: VoiceStartOptions {
        let defaults = UserDefaults.standard
        return VoiceStartOptions(locale: defaults.string(forKey: Prefs.Key.voiceLocale) ?? "zh-CN",
                                 contextualStrings: voiceHints(),
                                 allowServerRecognition: defaults.bool(forKey: Prefs.Key.voiceAllowServer))
    }

    /// Words that are hard to recognise without help: platform names plus the user's own course and task names.
    private func voiceHints() -> [String] {
        var hints = ["课堂派", "Canvas", "作业", "截止", "提醒", "DDL", "实验报告", "高等数学", "明天", "后天", "下周"]
        for r in reminders.sorted(by: { $0.createdAt > $1.createdAt }) {
            for text in [r.course, r.title] {
                if let text, !text.isEmpty, text.count <= 20, !hints.contains(text) { hints.append(text) }
            }
            if hints.count >= 60 { break }
        }
        return hints
    }

    func toggleVoice() {
        Task { await voice.toggle(voiceOptions) }
    }

    func dismissVoiceFailure() {
        voice.cancel()
    }

    private func voiceStateChanged() {
        let state = voice.state
        if state == .requestingPermission || (voiceState == .idle && state == .listening) {
            inputBeforeVoice = input
            if state == .requestingPermission { input = "" }
        }
        voiceState = state
        if state != .listening { meter.level = 0 }
        if case .failed = state, input.isEmpty { input = inputBeforeVoice }
    }

    private func voiceTranscript(_ text: String, final: Bool) {
        input = text
        guard final else { return }
        focusRequest += 1
        // A rambling dictation the local rules cannot read: let DeepSeek tidy it up (one small call).
        if UserDefaults.standard.bool(forKey: Prefs.Key.voiceAutoAI), aiAvailable, needsAIHelp {
            parseWithAI()
            return
        }
        guard UserDefaults.standard.bool(forKey: Prefs.Key.voiceAutoAdd),
              case .reminder = intent,
              !preview.isEmpty,
              preview.allSatisfy({ $0.confidence == .high && $0.due != nil }) else { return }
        addFromPreview(undoable: true)
    }

    // MARK: clock

    private func tick() {
        let current = Date()
        tickCount += 1
        if tickCount % 15 == 0 {
            now = current
            // After midnight the next 60 alerts are different ones: plan them again.
            if !calendar.isDate(lastScheduleDay, inSameDayAs: current) {
                lastScheduleDay = current
                onRemindersChanged?()
            }
        }
        if tickCount % 60 == 30 { sources.syncDue() }
        if tickCount % 60 == 45 { apple.tick() }
        let fires = FirePlanner.missed(reminders, from: lastFireCheck, to: current)
        lastFireCheck = current
        guard !fires.isEmpty else {
            if tickCount % 60 == 0 { save() }
            return
        }
        now = current
        // A snoozed reminder is spent once its snooze alert fires.
        for fire in fires where fire.lead < 0 {
            if let i = reminders.firstIndex(where: { $0.id == fire.reminderID }) { reminders[i].snoozedUntil = nil }
        }
        let hit = fires.compactMap { fire in reminders.first { $0.id == fire.reminderID } }
        save()
        onFires?(fires, hit)
    }

    // MARK: derived

    var pending: [Reminder] {
        reminders.filter { $0.status == .pending && !$0.ignored }
    }

    var pendingCount: Int { pending.count }

    var sections: [ReminderSection] {
        let cal = calendar
        let grouped = Dictionary(grouping: pending) { DisplayFormat.bucket(for: $0, now: now, calendar: cal) }
        return DayBucket.allCases.compactMap { bucket in
            guard var items = grouped[bucket], !items.isEmpty else { return nil }
            if bucket == .noDue {
                items.sort { $0.createdAt > $1.createdAt }
            } else {
                items.sort { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            }
            return ReminderSection(bucket: bucket, items: items)
        }
    }

    var recentlyCompleted: [Reminder] {
        reminders.filter { $0.status == .done }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
            .prefix(8).map { $0 }
    }

    /// Next pending item that has not passed yet.
    var nextUpcoming: Reminder? {
        pending.filter { ($0.due ?? .distantPast) >= now }.min { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    var overdueCount: Int {
        pending.filter { ($0.due ?? .distantFuture) < now }.count
    }

    /// The menu bar icon turns red for overdue items or anything due within three hours.
    var needsAttention: Bool {
        if overdueCount > 0 { return true }
        if let due = nextUpcoming?.due { return due.timeIntervalSince(now) < 3 * 3_600 }
        return false
    }

    var menuBarTitle: String? {
        guard Prefs.showNextInMenuBar, let next = nextUpcoming, let due = next.due,
              due.timeIntervalSince(now) < 24 * 3_600 else { return nil }
        let title = next.title.count > 10 ? String(next.title.prefix(10)) + "…" : next.title
        return "\(DisplayFormat.timeLabel(due, calendar: calendar)) \(title)"
    }

    // MARK: demo data for snapshots

    func debugSetPreview(_ events: [ParsedEvent]) { preview = events }

    static func demo(now: Date) -> AppModel {
        let model = AppModel(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent("remindbar-demo-\(UUID().uuidString).json"),
                             loadFromDisk: false)
        model.now = now
        let cal = Calendar.reminder
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let d = cal.date(byAdding: .day, value: dayOffset, to: cal.startOfDay(for: now)) ?? now
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: d) ?? d
        }
        var list: [Reminder] = []
        var a = Reminder(title: "提交实验报告", due: now.addingTimeInterval(-2 * 3_600), isDeadline: true, source: .ketangpai)
        a.course = "高等数学"
        list.append(a)
        list.append(Reminder(title: "去睡觉", due: at(0, 23)))
        var b = Reminder(title: "数据库 Lab 4 提交", due: at(0, 23, 59), isDeadline: true, source: .canvas)
        b.course = "数据库原理"
        list.append(b)
        list.append(Reminder(title: "开会", due: at(1, 15)))
        var c = Reminder(title: "操作系统作业 3", due: at(4, 23, 59), isDeadline: true, source: .canvas)
        c.course = "操作系统"
        list.append(c)
        list.append(Reminder(title: "期中考试复习", due: at(12, 9)))
        list.append(Reminder(title: "买牛奶", due: nil))
        list.append(Reminder(title: "给妈妈打电话", due: at(1, 19), source: .apple))
        var ignored = Reminder(title: "概率论 选做题", due: at(3, 23, 59), isDeadline: true, source: .canvas)
        ignored.course = "概率论"
        ignored.ignored = true
        list.append(ignored)
        model.reminders = list
        return model
    }
}
