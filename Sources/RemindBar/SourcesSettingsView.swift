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
                Text("点“连接”会打开一个登录窗口，请你自己登录（账号密码、验证码、扫码都行）；提醒条不会看到也不会保存你的密码。只读取作业和截止时间，不会替你提交或勾选任何东西。")
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
                Text("读取这些网站不消耗任何 AI token。来自 Canvas、课堂派的待办没有手动“完成”：是否完成以网站为准，面板上方的刷新按钮每次都会去网站重新读取并核对。登录过期时只提醒一次，不会反复重试。")
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

    private var busy: Bool { sources.syncing.contains(watcher.id) }

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
