import AppKit
import WebKit
import RemindCore
@preconcurrency import UserNotifications

/// `RemindBar --ui-smoke <outfile> --data-dir <dir>`: drives the REAL status item, popover and model inside the
/// running app (click, type, submit, alert) and reports what happened. Uses an isolated data directory.
@MainActor
enum UISmokeTest {
    static func run(model: AppModel, status: StatusItemController, outputPath: String, dataDir: URL) async {
        var lines: [String] = []
        var failures = 0
        func check(_ ok: Bool, _ name: String, _ detail: String = "") {
            lines.append((ok ? "PASS " : "FAIL ") + name + (detail.isEmpty ? "" : "  — " + detail))
            if !ok { failures += 1 }
        }
        func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        /// Waits (polling) until the condition holds; the popover's open/close animations take a variable time.
        func until(_ timeout: Double = 3, _ condition: () -> Bool) async -> Bool {
            var waited = 0.0
            while waited < timeout {
                if condition() { return true }
                await pause(0.1)
                waited += 0.1
            }
            return condition()
        }
        let shots = dataDir.appendingPathComponent("shots")
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)

        // 1. A click on the menu bar icon opens and closes the panel.
        check(!status.isShown, "panel starts closed")
        status.simulateClick()
        check(await until { status.isShown }, "clicking the status item opens the panel")
        await pause(0.4)
        status.snapshot(to: shots.appendingPathComponent("1-open.png").path)
        status.simulateClick()
        check(await until { !status.isShown }, "clicking again closes it")
        status.show(activate: true)
        check(await until { status.isShown }, "show(activate:) opens it")
        await pause(0.4)

        // 2. Typing a sentence gives a live preview.
        model.input = "去睡觉，明晚23点"
        await pause(0.4)
        check(model.preview.count == 1, "one event is previewed", "\(model.preview.count)")
        let tomorrow = Calendar.reminder.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        if let due = model.preview.first?.due {
            let c = Calendar.reminder.dateComponents([.hour, .minute], from: due)
            check(c.hour == 23 && c.minute == 0 && Calendar.reminder.isDate(due, inSameDayAs: tomorrow), "preview reads tomorrow 23:00", "\(due)")
        } else {
            check(false, "preview has a due date")
        }
        status.snapshot(to: shots.appendingPathComponent("2-preview.png").path)

        // 3. Return adds it, clears the field and persists.
        let before = model.reminders.count
        model.commitInput()
        await pause(0.4)
        check(model.reminders.count == before + 1, "return adds the reminder")
        check(model.input.isEmpty, "the input field is cleared")
        check(model.reminders.last?.title == "去睡觉", "title is 去睡觉", model.reminders.last?.title ?? "nil")
        let saved = try? JSONStore<AppState>(url: dataDir.appendingPathComponent("state.json")).load()
        check(saved?.reminders.contains { $0.title == "去睡觉" } == true, "the reminder is saved to disk")
        status.snapshot(to: shots.appendingPathComponent("3-added.png").path)

        // 4. Voice button state machine reacts (no microphone is opened in this test).
        check(model.voiceState == .idle, "voice is idle")

        // 5. Notifications: authorisation and scheduling.
        let auth = await NotificationBridge.shared.authorizationStatus()
        check(true, "notification authorisation status", "\(auth.rawValue) (2 = authorised)")
        if auth == .authorized || auth == .provisional {
            let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
            check(pending.contains { $0.identifier.hasPrefix(NotificationBridge.shared.prefix) }, "an alert was scheduled with the system", "\(pending.count) pending")
        }

        // 6. A reminder that comes due while the app runs pops the panel open and stays until dismissed.
        status.hide()
        _ = await until { !status.isShown }
        let soon = Reminder(title: "冒烟测试：到点提醒", due: Date().addingTimeInterval(3), leadTimes: [0])
        model.replaceReminders(model.reminders + [soon])
        check(await until(8) { status.isShown }, "the due alert opens the panel by itself")
        check(model.highlightedID == soon.id, "the due reminder is highlighted")
        status.snapshot(to: shots.appendingPathComponent("4-due-alert.png").path)
        await pause(9)
        check(status.isShown, "an alert at the deadline stays open")
        status.hide()
        var closedAfter = -1.0
        for step in 1...30 {
            await pause(0.1)
            if !status.isShown { closedAfter = Double(step) * 0.1; break }
        }
        check(closedAfter >= 0, "hide() closes it", closedAfter >= 0 ? String(format: "closed after %.1f s", closedAfter) : "still open after 3 s")

        // 7. An early warning opens the panel and folds it away again after a few seconds.
        let early = Reminder(title: "冒烟测试：提前提醒", due: Date().addingTimeInterval(130), isDeadline: true, leadTimes: [127])
        model.replaceReminders(model.reminders + [early])
        check(await until(8) { status.isShown }, "an early warning opens the panel")
        check(await until(14) { !status.isShown }, "…and it closes by itself after ~8 s")

        // 8. Completing and deleting.
        model.complete(soon.id)
        check(model.reminders.first { $0.id == soon.id }?.status == .done, "complete marks it done")
        model.delete(early.id)
        check(!model.reminders.contains { $0.id == early.id }, "delete removes it")

        // 9. "连接同济 Canvas" opens a real login window that loads the real Tongji sign-in page.
        model.sources.connect(ConnectRequest(kind: .canvas, url: IntentRouter.canvasURL, hint: ""))
        check(model.watchers.contains { $0.kind == .canvas && $0.name == "同济 Canvas" }, "connecting Canvas creates a watcher")
        check(await until(5) { model.sources.activeLoginWebView != nil }, "the Canvas login window opens")
        if let web = model.sources.activeLoginWebView {
            let loaded = await until(30) { !web.isLoading && web.url != nil }
            check(loaded, "the login page finishes loading", web.url?.absoluteString ?? "nil")
            check(web.url?.host?.contains("tongji.edu.cn") == true, "it is a Tongji page (Canvas or the unified sign-in)", web.url?.host ?? "nil")
        }
        model.sources.closeLoginWindow()
        check(model.sources.activeLoginWebView == nil, "closing the window releases it")
        check(model.watchers.first { $0.kind == .canvas }?.needsLogin == false, "closing without logging in does not mark anything broken")

        // 10. The 课堂派 calibration window loads the site with the capture hook installed from the first byte.
        model.sources.calibrateKetangpai()
        check(await until(5) { model.sources.activeLoginWebView != nil }, "the calibration window opens")
        if let web = model.sources.activeLoginWebView {
            let loaded = await until(30) { !web.isLoading && web.url != nil }
            check(loaded, "the 课堂派 page finishes loading", web.url?.absoluteString ?? "nil")
            check(web.url?.host?.contains("ketangpai.com") == true, "it is the 课堂派 site", web.url?.host ?? "nil")
            await pause(1.5)
            let hook = try? await web.evaluateJavaScript("window.__rbCapture === true")
            check((hook as? Bool) == true, "the capture hook is installed in the page")
        }
        model.sources.closeLoginWindow()

        // 11. Items from Canvas / 课堂派 cannot be completed by hand; the website decides.
        let siteItem = Reminder(title: "冒烟：网站作业", due: Date().addingTimeInterval(7_200), isDeadline: true,
                                source: .canvas, watcherID: "w-smoke", externalKey: "canvas:assignment:smoke")
        let ownItem = Reminder(title: "冒烟：自己的提醒", due: Date().addingTimeInterval(7_200))
        model.replaceReminders(model.reminders + [siteItem, ownItem])
        check(!model.canComplete(siteItem.id), "a Canvas item has no manual completion")
        check(!model.canDelete(siteItem.id), "a Canvas item cannot be deleted by hand")
        model.delete(siteItem.id)
        check(model.reminders.contains { $0.id == siteItem.id }, "delete() leaves a Canvas item alone")
        check(model.watchers.allSatisfy { $0.deletedKeys.isEmpty }, "…and no hidden-for-good mark is recorded")
        model.complete(siteItem.id)
        model.toggleDone(siteItem.id)
        check(model.reminders.first { $0.id == siteItem.id }?.status == .pending, "complete() / toggleDone() leave a Canvas item alone")
        // "Ignore" is how a website item stops reminding: it leaves every list and count, and can be undone or restored.
        check(model.canIgnore(siteItem.id), "a Canvas item can be ignored")
        check(!model.canIgnore(ownItem.id), "an own reminder cannot (it can be deleted instead)")
        let pendingBefore = model.pendingCount
        model.ignore(siteItem.id)
        check(model.reminders.first { $0.id == siteItem.id }?.ignored == true, "ignore marks the item")
        check(model.pendingCount == pendingBefore - 1, "an ignored item leaves the pending list and counts")
        check(model.ignoredItems.contains { $0.id == siteItem.id }, "…and shows up in the ignored list")
        check(!model.sections.flatMap(\.items).contains { $0.id == siteItem.id }, "…and in no day section")
        check(model.toastCanUndo && model.toast?.contains("已忽略") == true, "the toast offers 撤销", model.toast ?? "nil")
        model.undoFromToast()
        check(model.reminders.first { $0.id == siteItem.id }?.ignored == false, "撤销 restores the item")
        model.ignore(siteItem.id)
        model.unignore(siteItem.id)
        check(model.pendingCount == pendingBefore, "restoring from the ignored list brings it back")
        check(model.canComplete(ownItem.id), "an own reminder can be completed by hand")
        model.toggleDone(ownItem.id)
        check(model.reminders.first { $0.id == ownItem.id }?.status == .done, "…and it completes")
        model.replaceReminders(model.reminders.filter { $0.id != siteItem.id && $0.id != ownItem.id })

        // 12. Every press of the refresh button reads the websites again (the Canvas watcher from step 9 is still there).
        func press() async -> (read: Bool, toast: String?) {
            let before = WebSession.shared.requestCount
            model.sources.refreshAll()
            let done = await until(90) { !model.sources.isRefreshing && WebSession.shared.requestCount > before }
            return (done, model.toast)
        }
        let first = await press()
        check(first.read, "pressing refresh reads the website")
        check(first.toast?.contains("同济 Canvas") == true, "…and the message says what the website reported", first.toast ?? "nil")
        await pause(0.5)
        let second = await press()
        check(second.read, "pressing it again reads the website again (no waiting for the timer, no cache)")
        check(second.toast?.contains("同济 Canvas") == true, "…and reports again", second.toast ?? "nil")

        // 13. The link with Apple's Reminders, against an in-memory stand-in (the real database is never touched here).
        let fake = InMemoryAppleStore(calendar: Calendar.reminder, access: .notDetermined)
        let defaultList = fake.userAddList("提醒")
        fake.defaultListIdentifier = defaultList.id
        fake.userAdd(title: "冒烟：默认列表里的", due: Date().addingTimeInterval(10_800), in: defaultList.id)
        model.apple.useStore(fake)
        check(!model.appleState.config.enabled, "the link starts switched off (the panel shows its invitation)")
        model.apple.setEnabled(true)
        check(await until(8) { model.apple.status == .idle }, "switching the link on asks for access, makes the list and syncs", "\(model.apple.status)")
        check(fake.access() == .full, "…access was granted")
        let managedID = model.appleState.config.managedListID ?? ""
        check(model.appleState.config.importListIDs == [defaultList.id], "the small default list is brought along the first time", "\(model.appleState.config.importListIDs)")
        check(model.reminders.contains { $0.title == "冒烟：默认列表里的" && $0.source == .apple }, "…and its reminders are imported")
        check(model.appleState.config.defaultListOffered, "…and it is not offered again")
        await pause(0.3)
        check(model.toast?.contains("已开启同步") == true, "the panel says the link is on", model.toast ?? "nil")
        check(fake.lists().contains { $0.id == managedID && $0.title == "提醒条" }, "…and the 「提醒条」 list exists")
        model.input = "后天下午4点开周会"
        await pause(0.4)
        model.commitInput()
        check(await until(8) { fake.items.values.contains { $0.fields.title.contains("周会") } }, "a reminder added here appears in Reminders")
        let theirs = fake.userAdd(title: "冒烟：提醒事项里建的", due: Date().addingTimeInterval(7_200), in: managedID)
        check(await until(8) { model.reminders.contains { $0.title == "冒烟：提醒事项里建的" && $0.source == .apple } }, "…and one made in Reminders appears here")
        fake.userSetCompleted(theirs, true)
        check(await until(8) { model.reminders.first { $0.title == "冒烟：提醒事项里建的" }?.status == .done }, "ticking it in Reminders completes it here")
        let mirrored = Reminder(title: "冒烟：网站作业副本", due: Date().addingTimeInterval(86_400), isDeadline: true, source: .canvas,
                                watcherID: "w-smoke2", externalKey: "canvas:assignment:smoke2")
        model.replaceReminders(model.reminders + [mirrored])
        check(await until(8) { fake.items.values.contains { $0.fields.title == "冒烟：网站作业副本" } }, "a website item is copied to Reminders")
        model.ignore(mirrored.id)
        check(await until(8) { !fake.items.values.contains { $0.fields.title == "冒烟：网站作业副本" } }, "ignoring it takes the copy away")
        model.unignore(mirrored.id)
        check(await until(8) { fake.items.values.contains { $0.fields.title == "冒烟：网站作业副本" } }, "restoring it brings the copy back")
        if let meeting = model.reminders.first(where: { $0.title.contains("周会") }) {
            model.delete(meeting.id)
            check(await until(8) { !fake.items.values.contains { $0.fields.title.contains("周会") } }, "deleting here deletes in Reminders")
        } else {
            check(false, "the reminder typed in the panel exists")
        }
        check(model.appleState.links.count >= 3, "the pairs are remembered", "\(model.appleState.links.count)")
        let onDisk = try? JSONStore<AppState>(url: dataDir.appendingPathComponent("state.json")).load()
        check(onDisk?.apple?.config.enabled == true && onDisk?.apple?.links.isEmpty == false, "…and saved to disk")
        status.snapshot(to: shots.appendingPathComponent("13-apple.png").path)
        model.apple.disable()
        let writesWhenOff = fake.writes
        model.replaceReminders(model.reminders + [Reminder(title: "冒烟：关闭之后", due: Date().addingTimeInterval(9_000))])
        await pause(3)
        check(model.appleState.config.enabled == false && model.apple.status == .off, "switching the link off turns it off")
        check(fake.writes == writesWhenOff, "…and nothing is written to Reminders any more")

        // 14. After an update the system forgets the permission while the link is on: the app asks for it again by itself,
        //     once, instead of letting the sync stop quietly.
        let lost = InMemoryAppleStore(calendar: Calendar.reminder, access: .notDetermined)
        let lostList = lost.userAddList("提醒条")
        model.apple.useStore(lost)
        model.updateAppleConfig { $0.enabled = true; $0.managedListID = lostList.id; $0.defaultListOffered = true }
        model.apple.start()
        check(await until(15) { lost.accessRequests == 1 && lost.access() == .full }, "link on but permission lost: the app asks for it again by itself", "\(lost.accessRequests) request(s), \(lost.access())")
        check(await until(15) { model.apple.status == .idle }, "…and the sync carries on once it is given", "\(model.apple.status)")
        let silent = InMemoryAppleStore(calendar: Calendar.reminder, access: .notDetermined)
        silent.answersRequests = false
        let silentList = silent.userAddList("提醒条")
        model.apple.useStore(silent)
        model.updateAppleConfig { $0.managedListID = silentList.id }
        await model.apple.syncNow()
        check(silent.accessRequests == 1, "if nobody answers it asked once", "\(silent.accessRequests)")
        check(model.apple.status == .needsPermission, "…and says that permission is needed", "\(model.apple.status)")
        check(model.toast?.contains("需要你允许") == true, "…with a message in the panel", model.toast ?? "nil")
        await model.apple.syncNow()
        await model.apple.syncNow()
        check(silent.accessRequests == 1, "…and does not ask again during the same launch", "\(silent.accessRequests)")
        model.apple.disable()

        // Leave nothing of this run in the system's notification centre (its alerts use their own prefix).
        if NotificationBridge.shared.isAvailable {
            let center = UNUserNotificationCenter.current()
            let prefix = NotificationBridge.shared.prefix
            let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: pending)
            let delivered = await center.deliveredNotifications().map(\.request.identifier).filter { $0.hasPrefix(prefix) }
            center.removeDeliveredNotifications(withIdentifiers: delivered)
        }

        lines.append("")
        lines.append("RESULT: \(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")")
        try? lines.joined(separator: "\n").write(toFile: outputPath, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
