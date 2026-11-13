import SwiftUI
import RemindCore

@MainActor
final class AddSourceForm: ObservableObject {
    @Published var url = ""
    @Published var hint = ""
    @Published var message: String?
}

struct SourcesSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sources: SourceCoordinator
    @StateObject private var form = AddSourceForm()
    @AppStorage(Prefs.Key.pollMinutes) private var pollMinutes = 30

    var body: some View {
        Form {
            Section("已连接的网站") {
                if model.watchers.isEmpty {
                    Text("还没有连接任何网站。").foregroundStyle(.secondary)
                }
                ForEach(model.watchers) { watcher in
                    WatcherRow(model: model, sources: sources, watcher: watcher)
                }
            }

            if !model.ignoredItems.isEmpty {
                Section {
                    ForEach(model.ignoredItems) { reminder in
                        IgnoredRow(model: model, reminder: reminder)
                    }
                } header: {
                    Text("已忽略的作业")
                } footer: {
                    Text("这些作业不再提醒，但仍在被跟踪；网站上标记完成或不再列出后会自动清掉。点“恢复”重新提醒。")
                }
            }

            Section {
                Button("连接 课堂派") {
                    sources.connect(ConnectRequest(kind: .ketangpai, url: IntentRouter.ketangpaiURL, hint: ""))
                }
                Button("连接 同济 Canvas") {
                    sources.connect(ConnectRequest(kind: .canvas, url: IntentRouter.canvasURL, hint: ""))
                }
                TextField("其它网站的网址（Canvas 或任意网课、作业页面）", text: $form.url)
                TextField("想让 AI 盯什么（可选），例如：只关注作业和截止时间", text: $form.hint)
                HStack {
                    Spacer()
                    Button("连接这个网站") { connectCustom() }.disabled(form.url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let message = form.message {
                    Text(message).font(.footnote).foregroundStyle(.orange)
                }
            } header: {
                Text("添加")
            } footer: {
                Text("点“连接”会打开一个登录窗口，请你自己登录（账号密码、验证码、扫码都行）；提醒条不会看到也不会保存你的密码。想让它掉线时自动登录，可以在上面的网站下点“保存账号…”（可选，只存钥匙串）。只读取作业和截止时间，不会替你提交或勾选任何东西。")
            }

            Section {
                Button("校准课堂派接口（只需做一次）") { sources.calibrateKetangpai() }
                Button("打开校准样本文件夹") { NSWorkspace.shared.open(CaptureStore.directory) }
                Button("删除校准样本", role: .destructive) {
                    form.message = CaptureStore.clear() ? "校准样本已删除。" : "删除失败，可以在“打开校准样本文件夹”里手动删。"
                }
            } header: {
                Text("高级")
            } footer: {
                Text("课堂派已经校准好了，平时用不到这一栏。校准会记录课堂派网页自己调用的“待办/作业”接口的请求和返回（自动抹掉 token、密码、手机号），只保存在本机；里面有课程和作业名，不需要时请删除。")
            }

            Section {
                Picker("检查新作业的间隔", selection: $pollMinutes) {
                    Text("15 分钟").tag(15)
                    Text("30 分钟").tag(30)
                    Text("1 小时").tag(60)
                    Text("2 小时").tag(120)
                }
            } footer: {
                Text("读取这些网站不消耗任何 AI token。来自 Canvas、课堂派的待办没有手动“完成”：是否完成以网站为准，面板上方的刷新按钮每次都会去网站重新读取并核对。登录过期时：保存了账号的网站会先自动登录一次，不成功或没保存账号就只提醒一次，不会反复重试。")
            }
        }
        .formStyle(.grouped)
    }

    private func connectCustom() {
        let text = form.url.trimmingCharacters(in: .whitespaces)
        let withScheme = text.hasPrefix("http") ? text : "https://\(text)"
        guard let url = URL(string: withScheme), url.host != nil else {
            form.message = "网址看起来不对。"
            return
        }
        form.message = nil
        let kind = IntentRouter.kind(forHost: url.host)
        sources.connect(ConnectRequest(kind: kind, url: url, hint: form.hint))
        form.url = ""
        form.hint = ""
    }
}

private struct WatcherRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sources: SourceCoordinator
    let watcher: WatcherConfig

    @State private var editingLogin = false

    private var busy: Bool { sources.syncing.contains(watcher.id) }
    private var supportsAutoLogin: Bool { watcher.kind == .canvas || watcher.kind == .ketangpai }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: watcher.kind.symbolName).foregroundStyle(Color.accentColor)
                Text(watcher.name).font(.system(size: 13, weight: .semibold))
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Toggle("", isOn: Binding(get: { watcher.enabled }, set: { sources.setEnabled($0, watcherID: watcher.id) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help(watcher.enabled ? "暂停监控" : "恢复监控")
            }
            Text(statusLine)
                .font(.footnote)
                .foregroundStyle(watcher.needsLogin ? Color.red : Color.secondary)
            if supportsAutoLogin {
                autoLoginLine
            }
            HStack {
                Button("立即同步") { Task { await sources.sync(watcherID: watcher.id, userInitiated: true) } }
                    .disabled(busy || watcher.needsLogin)
                Button(watcher.needsLogin ? "重新登录" : "重新登录…") { sources.relogin(watcherID: watcher.id) }
                Spacer()
                Button("移除", role: .destructive) { sources.remove(watcherID: watcher.id) }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
        .sheet(isPresented: $editingLogin) {
            SavedLoginSheet(siteName: watcher.name, username: sources.savedUsername(for: watcher) ?? "") { login in
                sources.saveLogin(login, watcherID: watcher.id)
            }
        }
    }

    @ViewBuilder
    private var autoLoginLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "key.fill").font(.system(size: 10)).foregroundStyle(.secondary)
            if let name = sources.savedUsername(for: watcher) {
                if sources.autoLoginRejected(for: watcher) {
                    Text("自动登录已停用：网站说账号或密码不对，请重新保存").foregroundStyle(.orange)
                } else if sources.autoLoggingIn.contains(watcher.id) {
                    Text("正在用 \(name) 自动登录…").foregroundStyle(.secondary)
                } else {
                    Text("掉线时自动用 \(name) 登录").foregroundStyle(.secondary)
                }
                Spacer()
                Button("修改…") { editingLogin = true }
                Button("删除账号") { sources.deleteLogin(watcherID: watcher.id) }
            } else {
                Text("自动登录：未开启").foregroundStyle(.secondary)
                Spacer()
                Button("保存账号…") { editingLogin = true }
            }
        }
        .font(.footnote)
        .controlSize(.small)
    }

    private var statusLine: String {
        var parts: [String] = []
        if let status = watcher.lastStatus { parts.append(status) }
        if let last = watcher.lastSyncAt {
            parts.append("上次 " + last.formatted(.dateTime.month().day().hour().minute()))
        }
        if !watcher.enabled { parts.append("已暂停") }
        return parts.isEmpty ? "尚未同步" : parts.joined(separator: " · ")
    }
}

/// Asks for the account and password used to log in again by itself. The password field always starts empty: a saved
/// password is never read back into the window.
private struct SavedLoginSheet: View {
    let siteName: String
    @State var username: String
    let onSave: (SavedLogin) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var failed = false

    init(siteName: String, username: String, onSave: @escaping (SavedLogin) -> Bool) {
        self.siteName = siteName
        _username = State(initialValue: username)
        self.onSave = onSave
    }

    private var login: SavedLogin {
        SavedLogin(username: username.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("“\(siteName)”掉线时自动登录").font(.headline)
            Form {
                TextField("账号（学号 / 手机号）", text: $username)
                SecureField("密码", text: $password)
            }
            .formStyle(.grouped)
            Text("账号和密码只存在这台 Mac 的钥匙串里，不写进任何文件，也不会发给除这个网站以外的地方。登录过期时，提醒条在后台打开网站的登录页，替你填好账号密码并点“登录”。登录页上的“同意用户协议”会替你勾上；遇到验证码、滑块、扫码或短信验证时，它会停下来通知你手动登录；网站说密码不对时会立刻停用自动登录，避免账号被锁。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if failed {
                Text("没能写进钥匙串，请再试一次。").font(.footnote).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if onSave(login) { dismiss() } else { failed = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!login.isComplete)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
