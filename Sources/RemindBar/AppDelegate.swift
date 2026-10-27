import AppKit
import RemindCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var status: StatusItemController!
    private var settings: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Prefs.register()

        // Developer check: real recognizer + synthesised speech, then quit. Needs the packaged app (Info.plist).
        if let i = CommandLine.arguments.firstIndex(of: "--voice-file-test"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            Task { @MainActor in
                await VoiceFileTest.run(outputPath: out)
                NSApp.terminate(nil)
            }
            return
        }

        if let i = CommandLine.arguments.firstIndex(of: "--ketangpai-check"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            Task { @MainActor in
                await KetangpaiCheck.run(outputPath: out)
                NSApp.terminate(nil)
            }
            return
        }

        if let i = CommandLine.arguments.firstIndex(of: "--canvas-crosscheck"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            Task { @MainActor in
                await CanvasCrossCheck.run(outputPath: out)
                NSApp.terminate(nil)
            }
            return
        }

        if let i = CommandLine.arguments.firstIndex(of: "--apple-status"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            Task { @MainActor in
                await AppleStatusProbe.run(outputPath: out)
                NSApp.terminate(nil)
            }
            return
        }

        if let i = CommandLine.arguments.firstIndex(of: "--apple-selftest"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            Task { @MainActor in
                await AppleSelfTest.run(outputPath: out)
                NSApp.terminate(nil)
            }
            return
        }

        if let i = CommandLine.arguments.firstIndex(of: "--test-web-fetch"), i + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            Task { @MainActor in
                await WebFetchTest.run(outputPath: out)
                NSApp.terminate(nil)
            }
            return
        }

        model = AppModel()
        settings = SettingsWindowController(model: model)
        status = StatusItemController(model: model)

        model.onOpenSettings = { [weak self] in
            self?.status.hide()
            self?.settings.show()
        }
        model.onOpenSettingsTab = { [weak self] tab in
            self?.status.hide()
            self?.settings.show(tab: tab)
        }
        model.onFires = { [weak self] fires, reminders in
            self?.status.alert(fires: fires, reminders: reminders)
        }
        model.onConnectRequest = { [weak self] request in
            self?.model.sources.connect(request)
        }
        model.onRemindersChanged = { [weak self] in
            guard let self else { return }
            NotificationBridge.shared.reschedule(self.model.reminders)
        }

        let bridge = NotificationBridge.shared
        bridge.onAction = { [weak self] action, id in self?.handleNotificationAction(action, id: id) }
        bridge.setup()
        bridge.reschedule(model.reminders)

        model.start()
        model.apple.start()
        // `--enable-apple-link`: switch the link on (as the toggle in the settings does) right after launch.
        if CommandLine.arguments.contains("--enable-apple-link") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await self.model.apple.enable()
            }
        }

        // The Mac may have slept through some alerts; re-plan from the current time when it wakes.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                NotificationBridge.shared.reschedule(self.model.reminders)
                self.model.refreshNotificationStatus()
                self.model.apple.syncSoon(after: 3)
                // Give the network a few seconds to come back, then catch up on the connected sites.
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    MainActor.assumeIsolated { self?.model.sources.syncDue() }
                }
            }
        }

        if CommandLine.arguments.contains("--show-panel") {
            status.show(activate: true)
        }

        if let i = CommandLine.arguments.firstIndex(of: "--ui-smoke"), i + 1 < CommandLine.arguments.count,
           let d = CommandLine.arguments.firstIndex(of: "--data-dir"), d + 1 < CommandLine.arguments.count {
            let out = CommandLine.arguments[i + 1]
            let dir = URL(fileURLWithPath: CommandLine.arguments[d + 1], isDirectory: true)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await UISmokeTest.run(model: model, status: status, outputPath: out, dataDir: dir)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // The developer check modes quit without ever creating the model.
        model?.stop()
    }

    private func handleNotificationAction(_ action: String, id: UUID) {
        switch action {
        case NotificationBridge.ActionID.done:
            model.complete(id)
        case NotificationBridge.ActionID.snooze:
            model.snooze(id, minutes: 10)
        default:
            model.highlightedID = id
            status.show(activate: true)
        }
    }
}
