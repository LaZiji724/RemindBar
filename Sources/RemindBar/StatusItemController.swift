import AppKit
import Combine
import SwiftUI
import RemindCore

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()
    private var autoClose: DispatchWorkItem?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
        }

        let host = NSHostingController(rootView: PopoverRoot(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self

        Publishers.CombineLatest(model.$reminders, model.$now)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.refreshAppearance() }
            .store(in: &cancellables)
        refreshAppearance()
    }

    var isShown: Bool { popover.isShown }

    /// Performs the same action a mouse click on the menu bar icon would.
    func simulateClick() {
        statusItem.button?.performClick(nil)
    }

    /// Renders the panel's real view hierarchy to a PNG (no screen-recording permission needed).
    func snapshot(to path: String) {
        guard let view = popover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    // MARK: appearance

    func refreshAppearance() {
        guard let button = statusItem.button else { return }
        let attention = model.needsAttention
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: attention ? "bell.badge.fill" : "bell.fill", accessibilityDescription: "提醒条")?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = attention ? .systemRed : nil
        if let title = model.menuBarTitle {
            button.attributedTitle = NSAttributedString(string: " " + title, attributes: [
                .font: NSFont.menuBarFont(ofSize: 0),
                .baselineOffset: 0.5
            ])
        } else {
            button.title = ""
        }
    }

    // MARK: popover

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else if popover.isShown {
            hide()
        } else {
            show(activate: true)
        }
    }

    func show(activate: Bool, autoCloseAfter seconds: TimeInterval? = nil) {
        guard let button = statusItem.button else { return }
        autoClose?.cancel()
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
            model.focusRequest += 1
        }
        if let seconds {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.popover.isShown, !self.mouseIsInsidePopover() else { return }
                self.hide()
            }
            autoClose = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    func hide() {
        autoClose?.cancel()
        popover.close()
    }

    private func mouseIsInsidePopover() -> Bool {
        guard let window = popover.contentViewController?.view.window else { return false }
        return NSMouseInRect(NSEvent.mouseLocation, window.frame, false)
    }

    /// Called when alerts fire while the app is running.
    func alert(fires: [Fire], reminders: [Reminder]) {
        model.highlightedID = reminders.first?.id
        refreshAppearance()
        guard Prefs.autoOpenOnFire else { return }
        // At the deadline itself the panel stays until dismissed; earlier warnings fold away on their own.
        let final = fires.contains { $0.lead <= 0 }
        show(activate: false, autoCloseAfter: final ? nil : 8)
    }

    // MARK: context menu

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开面板", action: #selector(openPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出提醒条", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openPanel() { show(activate: true) }
    @objc private func openSettings() { model.onOpenSettings?() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: NSPopoverDelegate

    func popoverDidShow(_ notification: Notification) {
        installMonitors()
        model.refreshNotificationStatus()
        model.sources.refreshIfStale()
        model.apple.refreshIfStale()
    }

    func popoverDidClose(_ notification: Notification) {
        removeMonitors()
        model.highlightedID = nil
    }

    private func installMonitors() {
        removeMonitors()
        // Clicks in other apps close the panel.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
        // Clicks elsewhere in this app (e.g. the settings window) and Esc close it as well.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.hide(); return nil }
                return event
            }
            let popoverWindow = self.popover.contentViewController?.view.window
            if event.window !== popoverWindow && event.window !== self.statusItem.button?.window {
                self.hide()
            }
            return event
        }
    }

    private func removeMonitors() {
        if let g = globalMonitor { NSEvent.removeMonitor(g) }
        if let l = localMonitor { NSEvent.removeMonitor(l) }
        globalMonitor = nil
        localMonitor = nil
    }
}
