import AppKit
import SwiftUI
import RemindCore

/// `RemindBar --snapshot <dir>` renders the panel with demo data to PNG files.
/// It draws the view hierarchy itself, so it needs no screen-recording permission.
@MainActor
enum SnapshotTool {
    static func run(arguments: [String]) {
        guard let i = arguments.firstIndex(of: "--snapshot") else { return }
        let dir = (i + 1 < arguments.count && !arguments[i + 1].hasPrefix("--")) ? arguments[i + 1] : NSTemporaryDirectory()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Prefs.register()

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        cal.firstWeekday = 2
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 21, minute: 5)) ?? Date()

        // Pretend a DeepSeek key exists (in memory only) so the AI controls are rendered.
        UserDefaults.standard.register(defaults: [Prefs.Key.aiKeyPresent: true])

        let scenes: [(name: String, input: String)] = [
            ("list", ""),
            ("preview-past", "去睡觉，今晚19点"),
            ("preview-ampm", "明天10点开会"),
            ("preview-multi", "明天上午九点开会，后天下午三点交作业"),
            ("preview-lowconf", "晚点提醒我"),
            ("connect", "监控课堂派的新作业")
        ]
        for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            for scene in scenes {
                let model = AppModel.demo(now: now)
                model.clockOverride = now
                model.input = scene.input
                render(PopoverRoot(model: model), appearance: appearance, to: "\(dir)/panel-\(scene.name)-\(appearanceName).png")
            }
        }
        // After DeepSeek answered: the preview carries the AI flag.
        do {
            let model = AppModel.demo(now: now)
            model.clockOverride = now
            model.input = "晚点提醒我"
            let ctx = model.parseContext()
            let items = [AIReminderItem(title: "提醒", date: "2026-10-26", time: "22:00", deadline: false)]
            model.debugSetPreview(ResultValidator.events(from: items, context: ctx, original: "晚点提醒我"))
            render(PopoverRoot(model: model), appearance: .aqua, to: "\(dir)/panel-ai-result-light.png")
        }

        // The ignored section, and the panel with the Reminders link switched on
        let demoLists = [AppleList(id: "L1", title: "提醒条", account: "iCloud"), AppleList(id: "L2", title: "提醒", account: "iCloud"),
                         AppleList(id: "L3", title: "购物", account: "iCloud"), AppleList(id: "L4", title: "工作", account: "iCloud")]
        func linkedModel(enabled: Bool, status: AppleRemindersService.Status) -> AppModel {
            let model = AppModel.demo(now: now)
            model.clockOverride = now
            model.updateAppleConfig {
                $0.enabled = enabled
                $0.managedListID = "L1"
                $0.importListIDs = ["L2"]
                $0.lastSyncAt = now
            }
            var report = AppleSyncEngine.Report()
            report.created = 4
            report.imported = 1
            model.apple.debugShow(status: status, lists: demoLists, report: report)
            return model
        }
        do {
            let model = linkedModel(enabled: true, status: .idle)
            model.showIgnored = true
            render(PopoverRoot(model: model), appearance: .aqua, to: "\(dir)/panel-ignored-light.png")
            render(PopoverRoot(model: model), appearance: .darkAqua, to: "\(dir)/panel-ignored-dark.png")
        }
        do {
            // A short list, so the ignored section at its end is in view.
            let model = linkedModel(enabled: true, status: .idle)
            model.replaceReminders(model.reminders.filter { ["去睡觉", "数据库 Lab 4 提交", "概率论 选做题"].contains($0.title) })
            model.showIgnored = true
            render(PopoverRoot(model: model), appearance: .aqua, to: "\(dir)/panel-ignored-short-light.png")
            render(PopoverRoot(model: model), appearance: .darkAqua, to: "\(dir)/panel-ignored-short-dark.png")
            model.showIgnored = false
            render(PopoverRoot(model: model), appearance: .aqua, to: "\(dir)/panel-ignored-folded-light.png")
        }
        for (name, enabled, status) in [("apple-on", true, AppleRemindersService.Status.idle), ("apple-off", false, .off),
                                        ("apple-denied", false, .denied), ("apple-missing", true, .listMissing)] {
            let model = linkedModel(enabled: enabled, status: status)
            render(SettingsView(model: model, initialTab: .apple), appearance: .aqua, to: "\(dir)/settings-\(name)-light.png")
        }
        do {
            let model = linkedModel(enabled: true, status: .idle)
            render(SettingsView(model: model, initialTab: .apple), appearance: .darkAqua, to: "\(dir)/settings-apple-on-dark.png")
            render(SettingsView(model: model, initialTab: .sources), appearance: .aqua, to: "\(dir)/settings-sources-light.png")
        }

        // Settings tabs
        for (name, tab) in [("general", SettingsTab.general), ("voice", .voice), ("ai", .ai), ("notifications", .notifications)] {
            let model = AppModel.demo(now: now)
            render(SettingsView(model: model, initialTab: tab), appearance: .aqua, to: "\(dir)/settings-\(name)-light.png")
        }
        print("Snapshots written to \(dir)")
    }

    static func render<V: View>(_ view: V, appearance: NSAppearance.Name, to path: String) {
        let background = appearance == .darkAqua ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        let hosting = NSHostingView(rootView: view.background(Color(nsColor: background)))
        hosting.appearance = NSAppearance(named: appearance)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
