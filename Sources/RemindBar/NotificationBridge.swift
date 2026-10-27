import AppKit
import RemindCore
@preconcurrency import UserNotifications

/// Local notifications for every upcoming alert. They keep firing after the app quits.
@MainActor
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationBridge()

    enum ActionID {
        static let done = "REMINDER_DONE"
        static let snooze = "REMINDER_SNOOZE10"
        static let category = "REMINDER"
        /// Items from Canvas / 课堂派: only "later", completion comes from the website.
        static let categorySite = "REMINDER_SITE"
    }

    /// `swift run` binaries are not app bundles; UNUserNotificationCenter would crash there.
    var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    var onAction: ((String, UUID) -> Void)?
    /// Every alert of ours starts with this. A run with its own data directory (the UI smoke test) uses another one, so it
    /// can never replace or leave behind alerts that belong to the real app.
    let prefix = CommandLine.arguments.contains("--data-dir") ? "rbtest|" : "rb|"

    func setup() {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let done = UNNotificationAction(identifier: ActionID.done, title: "完成", options: [])
        let snooze = UNNotificationAction(identifier: ActionID.snooze, title: "10 分钟后再提醒", options: [])
        let category = UNNotificationCategory(identifier: ActionID.category, actions: [done, snooze],
                                              intentIdentifiers: [], options: [])
        let siteCategory = UNNotificationCategory(identifier: ActionID.categorySite, actions: [snooze],
                                                  intentIdentifiers: [], options: [])
        center.setNotificationCategories([category, siteCategory])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        guard isAvailable else { return .notDetermined }
        return await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func sendTestNotification() {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "提醒条"
        content.body = "通知工作正常。"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "\(prefix)test", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }

    /// An immediate notification (new homework found, login expired…).
    func post(title: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: "\(prefix)sync|\(UUID().uuidString)", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }

    /// Replaces every pending alert of ours with the next 60 (the system allows 64 at most).
    func reschedule(_ reminders: [Reminder], now: Date = Date()) {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        let plan = FirePlanner.plan(reminders, after: now, limit: 60)
        let byID = Dictionary(uniqueKeysWithValues: reminders.map { ($0.id, $0) })
        let calendar = Calendar.reminder
        let prefix = self.prefix
        Task {
            let pending = await center.pendingNotificationRequests()
            let ours = pending.map(\.identifier).filter {
                $0.hasPrefix(prefix) && !$0.hasPrefix("\(prefix)sync") && $0 != "\(prefix)test"
            }
            center.removePendingNotificationRequests(withIdentifiers: ours)
            for fire in plan {
                guard let r = byID[fire.reminderID] else { continue }
                let content = UNMutableNotificationContent()
                content.title = r.title
                content.body = DisplayFormat.alertBody(for: r, lead: fire.lead, now: fire.at, calendar: calendar)
                content.sound = .default
                content.categoryIdentifier = r.completionFollowsSite ? ActionID.categorySite : ActionID.category
                content.threadIdentifier = r.id.uuidString
                content.userInfo = ["id": r.id.uuidString]
                let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fire.at)
                let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                let request = UNNotificationRequest(identifier: prefix + fire.id, content: content, trigger: trigger)
                try? await center.add(request)
            }
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let action = response.actionIdentifier
        guard let idString = response.notification.request.content.userInfo["id"] as? String,
              let id = UUID(uuidString: idString) else { return }
        await MainActor.run { self.onAction?(action, id) }
    }
}
