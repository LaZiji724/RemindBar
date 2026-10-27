import SwiftUI
import UserNotifications
import RemindCore

enum SettingsTab: Hashable {
    case general, sources, apple, voice, ai, notifications
}

@MainActor
final class SettingsNav: ObservableObject {
    @Published var tab: SettingsTab
    init(_ tab: SettingsTab) { self.tab = tab }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var nav: SettingsNav

    init(model: AppModel, initialTab: SettingsTab = .general) {
        self.model = model
        _nav = StateObject(wrappedValue: SettingsNav(initialTab))
    }

    var body: some View {
        TabView(selection: $nav.tab) {
            GeneralSettings()
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            SourcesSettings(model: model, sources: model.sources)
                .tabItem { Label("监控源", systemImage: "graduationcap") }
                .tag(SettingsTab.sources)
            AppleSettings(model: model, service: model.apple)
                .tabItem { Label("提醒事项", systemImage: "checklist") }
                .tag(SettingsTab.apple)
            VoiceSettings()
                .tabItem { Label("语音", systemImage: "mic") }
                .tag(SettingsTab.voice)
            AISettings(model: model)
                .tabItem { Label("AI", systemImage: "sparkles") }
                .tag(SettingsTab.ai)
            NotificationSettings()
                .tabItem { Label("通知", systemImage: "bell") }
                .tag(SettingsTab.notifications)
        }
        .frame(width: 520, height: 520)
    }
}

@MainActor
private final class LoginItemState: ObservableObject {
    @Published var enabled = LaunchAtLogin.isEnabled
    @Published var message: String?
}

@MainActor
private final class NotificationInfo: ObservableObject {
    @Published var status: UNAuthorizationStatus = .notDetermined
}

private struct GeneralSettings: View {
    @AppStorage(Prefs.Key.defaultHour) private var hour = 9
    @AppStorage(Prefs.Key.defaultMinute) private var minute = 0
    @AppStorage(Prefs.Key.showNextInMenuBar) private var showNext = true
    @AppStorage(Prefs.Key.autoOpenOnFire) private var autoOpen = true
    @StateObject private var login = LoginItemState()

    var body: some View {
        Form {
            Section {
                Toggle("开机自动启动", isOn: Binding(get: { login.enabled }, set: setLaunchAtLogin))
                if let message = login.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("在菜单栏显示下一项提醒", isOn: $showNext)
                Toggle("提醒到点时自动展开面板", isOn: $autoOpen)
            }
            Section {
                DatePicker("只写了日期时，几点提醒", selection: defaultTime, displayedComponents: .hourAndMinute)
            } footer: {
                Text("例如输入“明天交作业”，没有说具体时间时按这里的时间提醒；写了“前”“截止”的会按 23:59 算。")
            }
            Section {
                LabeledContent("版本", value: Self.versionText)
            }
        }
        .formStyle(.grouped)
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "开发版"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version)（\($0)）" } ?? version
    }

    private var defaultTime: Binding<Date> {
        Binding(
            get: {
                Calendar.reminder.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
            },
            set: { newValue in
                let c = Calendar.reminder.dateComponents([.hour, .minute], from: newValue)
                hour = c.hour ?? 9
                minute = c.minute ?? 0
            }
        )
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            login.enabled = LaunchAtLogin.isEnabled
            login.message = LaunchAtLogin.needsApproval ? "需要在“系统设置 › 通用 › 登录项”里允许提醒条。" : nil
        } catch {
            login.enabled = LaunchAtLogin.isEnabled
            login.message = "设置失败：\(error.localizedDescription)。请把提醒条放进“应用程序”或“~/Applications”后再试。"
        }
    }
}

private struct VoiceSettings: View {
    @AppStorage(Prefs.Key.voiceLocale) private var locale = "zh-CN"
    @AppStorage(Prefs.Key.voiceAutoAdd) private var autoAdd = false
    @AppStorage(Prefs.Key.voiceAllowServer) private var allowServer = false

    var body: some View {
        Form {
            Section {
                Picker("识别语言", selection: $locale) {
                    Text("普通话").tag("zh-CN")
                    Text("粤语").tag("yue-CN")
                    Text("繁体中文（台湾）").tag("zh-TW")
                    Text("English").tag("en-US")
                }
                Toggle("识别完直接添加（只对“一听就懂”的句子，6 秒内可撤销）", isOn: $autoAdd)
            } footer: {
                Text("默认关闭：识别结果会先显示在输入框里，你看一眼再按回车，避免听错时间。")
            }
            Section {
                Toggle("语言没有离线识别包时，允许使用 Apple 服务器识别", isOn: $allowServer)
            } footer: {
                Text("默认只在本机识别，音频不会离开这台 Mac，也不会保存。")
            }
            Section {
                Button("打开“麦克风”权限设置") { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") }
                Button("打开“语音识别”权限设置") { open("x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") }
            }
        }
        .formStyle(.grouped)
    }

    private func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}

private struct NotificationSettings: View {
    @StateObject private var info = NotificationInfo()
    private var status: UNAuthorizationStatus { info.status }

    var body: some View {
        Form {
            Section {
                LabeledContent("通知权限") { Text(statusText).foregroundStyle(statusColor) }
                Button("发送一条测试通知") { NotificationBridge.shared.sendTestNotification() }
                    .disabled(!NotificationBridge.shared.isAvailable)
                Button("打开系统通知设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            } footer: {
                Text("提醒会以系统通知的形式发出，即使退出提醒条也会准点弹出。如果开启了专注模式，请在专注设置里允许“提醒条”。")
            }
        }
        .formStyle(.grouped)
        .task { info.status = await NotificationBridge.shared.authorizationStatus() }
    }

    private var statusText: String {
        guard NotificationBridge.shared.isAvailable else { return "仅在打包后的 App 中可用" }
        switch status {
        case .authorized, .provisional, .ephemeral: return "已允许"
        case .denied: return "已拒绝（请到系统设置里开启）"
        case .notDetermined: return "尚未询问"
        @unknown default: return "未知"
        }
    }

    private var statusColor: Color {
        switch status {
        case .authorized, .provisional, .ephemeral: return .green
        case .denied: return .red
        default: return .secondary
        }
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let model: AppModel

    init(model: AppModel) { self.model = model }

    func show(tab: SettingsTab? = nil) {
        if window == nil {
            let host = NSHostingController(rootView: SettingsView(model: model, initialTab: tab ?? .general))
            let w = NSWindow(contentViewController: host)
            w.title = "提醒条设置"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        } else if let tab {
            // Rebuilding the content is the simplest way to land on the requested tab.
            window?.contentViewController = NSHostingController(rootView: SettingsView(model: model, initialTab: tab))
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
