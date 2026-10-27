import SwiftUI
import RemindCore

/// Settings › 提醒事项: the two-way link with Apple's Reminders app.
struct AppleSettings: View {
    @ObservedObject var model: AppModel
    @ObservedObject var service: AppleRemindersService

    private var config: AppleSyncConfig { model.appleState.config }

    var body: some View {
        Form {
            Section {
                Toggle("与 Apple 提醒事项同步", isOn: Binding(get: { config.enabled }, set: { service.setEnabled($0) }))
                    .disabled(service.status == .asking)
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(dotColor).frame(width: 7, height: 7).padding(.top, 5)
                    Text(service.statusText)
                        .font(.footnote)
                        .foregroundStyle(statusIsProblem ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                problemButton
            } footer: {
                Text(config.enabled
                     ? "提醒条里的提醒会出现在“提醒事项”App 的「\(config.managedListTitle)」列表里，iPhone、iPad 上也看得到；在那边新增、改时间、勾选、删除，也会同步回来。"
                     : "打开后，提醒条里的提醒会写进“提醒事项”App 的「\(config.managedListTitle)」列表（iPhone、iPad 上也看得到），你在那边新增、修改、勾选的也会同步回来。第一次会弹出系统授权窗口。")
            }

            if config.enabled {
                Section {
                    if service.lists.filter({ $0.id != config.managedListID }).isEmpty {
                        Text("提醒事项里没有其它列表。").font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(service.lists.filter { $0.id != config.managedListID }) { list in
                        Toggle(listLabel(list), isOn: importBinding(for: list))
                    }
                } header: {
                    Text("也从这些列表导入并保持同步")
                } footer: {
                    Text("默认只同步「\(config.managedListTitle)」。比如想让 Siri 说“提醒我…”建出来的提醒也出现在这里，就勾选你的默认列表。新建的提醒仍然写进「\(config.managedListTitle)」。")
                }

                Section {
                    Toggle("包含网站来的作业（Canvas、课堂派、监控的网页）", isOn: Binding(
                        get: { config.includeWebsiteItems },
                        set: { value in model.updateAppleConfig { $0.includeWebsiteItems = value }; service.syncSoon(after: 0.3) }))
                    Toggle("给提醒事项里的副本在到点时设置闹铃（iPhone 上也会响）", isOn: Binding(
                        get: { config.alarms },
                        set: { value in model.updateAppleConfig { $0.alarms = value }; service.syncSoon(after: 0.3) }))
                } footer: {
                    Text("网站作业的副本是单向的：是否完成以网站为准，在提醒事项里勾选或修改它不会影响提醒条。开了闹铃后，Mac 上到点时提醒条和“提醒事项”会各响一次。前 1 天、3 小时、30 分钟、3 分钟的提前提醒只由提醒条在这台 Mac 上发出；想让 iPhone 也提前提醒，可以在提醒事项里给那一条设置“提前提醒”。只有提醒条写进去的副本带闹铃，你自己在提醒事项里建的提醒保持原样。有重复规则的提醒事项暂不导入。")
                }

                Section {
                    Button("立即同步") { Task { await service.syncNow() } }
                        .disabled(service.status == .syncing)
                    Button("打开“提醒事项”App") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
                            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                } footer: {
                    Text("删掉提醒事项里的「\(config.managedListTitle)」列表不会删除提醒条里的内容；想彻底断开，关掉上面的开关即可。")
                }
            }
        }
        .formStyle(.grouped)
        .task { service.refreshLists() }
    }

    // MARK: pieces

    @ViewBuilder
    private var problemButton: some View {
        switch service.status {
        case .needsPermission:
            Button("允许访问提醒事项…") { service.setEnabled(true) }
        case .denied:
            Button("打开“系统设置 › 隐私与安全性 › 提醒事项”") { open("x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") }
        case .listMissing:
            Button("重新创建「\(config.managedListTitle)」列表") { Task { await service.recreateList() } }
        case .failed:
            Button("重试") { Task { await service.syncNow() } }
        default:
            EmptyView()
        }
    }

    private var statusIsProblem: Bool {
        switch service.status {
        case .needsPermission, .denied, .listMissing, .failed: return true
        default: return false
        }
    }

    private var dotColor: Color {
        switch service.status {
        case .idle: return .green
        case .syncing, .asking: return .blue
        case .off: return .gray
        default: return .orange
        }
    }

    private func listLabel(_ list: AppleList) -> String {
        list.account.isEmpty ? list.title : "\(list.title) · \(list.account)"
    }

    private func importBinding(for list: AppleList) -> Binding<Bool> {
        Binding(
            get: { config.importListIDs.contains(list.id) },
            set: { on in
                model.updateAppleConfig {
                    $0.importListIDs.removeAll { $0 == list.id }
                    if on { $0.importListIDs.append(list.id) }
                }
                service.syncSoon(after: 0.3)
            })
    }

    private func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}
