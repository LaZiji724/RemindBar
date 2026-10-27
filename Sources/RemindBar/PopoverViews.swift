import SwiftUI
import RemindCore

// MARK: - Root

struct PopoverRoot: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(model: model)
            NotificationBanner(model: model)
            AppleInviteBanner(model: model)
            InputBar(model: model)
            PreviewSection(model: model)
            Divider().padding(.top, 8)
            ReminderListView(model: model)
            Divider()
            FooterBar(model: model)
        }
        .frame(width: 380)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                HStack(spacing: 10) {
                    Text(toast)
                        .font(.system(size: 12, weight: .medium))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.toastCanUndo {
                        Button("撤销") { model.undoFromToast() }
                            .buttonStyle(.link)
                            .font(.system(size: 12, weight: .semibold))
                    }
                }
                .frame(maxWidth: 330)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .padding(.bottom, 44)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.toast)
    }
}

// MARK: - Header

private struct HeaderBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sources: SourceCoordinator

    init(model: AppModel) {
        self.model = model
        self.sources = model.sources
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.fill")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 14, weight: .semibold))
            Text("提醒条")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if !model.watchers.isEmpty {
                if sources.isRefreshing || !sources.syncing.isEmpty {
                    ProgressView().controlSize(.small).help("正在去网站读取…")
                } else {
                    Button { sources.refreshAll() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 13))
                    }
                    .buttonStyle(.borderless)
                    .help("立即去网站重新读取，核对作业是否已完成")
                }
            }
            Button { model.onOpenSettings?() } label: {
                Image(systemName: "gearshape").font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .help("设置")
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }
}

// MARK: - Notifications switched off

private struct NotificationBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.notificationsDenied {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bell.slash.fill").foregroundStyle(.orange).font(.system(size: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("系统通知被关闭了，到点的提醒不会弹出")
                        .font(.system(size: 12, weight: .semibold))
                    Button("打开“系统设置 › 通知”，允许提醒条") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.orange.opacity(0.14)))
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Invitation to link with Apple's Reminders

/// Shown until the link with Apple's Reminders is switched on (or the person says "later"): one click instead of a trip
/// through the settings.
private struct AppleInviteBanner: View {
    @ObservedObject var model: AppModel
    @ObservedObject var service: AppleRemindersService
    @AppStorage(Prefs.Key.appleInviteDismissed) private var dismissed = false

    init(model: AppModel) {
        self.model = model
        self.service = model.apple
    }

    private var problem: Bool {
        switch service.status {
        case .needsPermission, .denied, .failed, .listMissing: return true
        default: return false
        }
    }

    private var message: String {
        switch service.status {
        case .off, .idle, .syncing:
            return "提醒条里的提醒会出现在“提醒事项”App 里（iPhone、iPad 上也看得到），那边新增、勾选的也会同步回来。"
        case .asking:
            return "请在系统弹出的窗口里点“允许完全访问”。"
        default:
            return service.statusText
        }
    }

    var body: some View {
        if !model.appleState.config.enabled && !dismissed {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checklist").foregroundStyle(Color.accentColor).font(.system(size: 14, weight: .semibold))
                VStack(alignment: .leading, spacing: 5) {
                    Text("同步到 Apple 提醒事项").font(.system(size: 12, weight: .semibold))
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(problem ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        if service.status == .asking {
                            ProgressView().controlSize(.small)
                        } else if service.status == .denied {
                            Button("打开系统设置") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        } else {
                            Button("开启同步") { service.setEnabled(true) }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                        }
                        Button("以后再说") { dismissed = true }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.10)))
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
    }
}

// MARK: - Input

private struct InputBar: View {
    @ObservedObject var model: AppModel
    @FocusState private var focused: Bool

    private var listening: Bool { model.voiceState == .listening }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 15))
                    TextField(listening ? "正在听你说…" : "输入或口述提醒，例如：去睡觉，今晚19点", text: $model.input)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)
                        .onSubmit { model.commitInput() }
                    if !model.input.isEmpty && !listening {
                        Button { model.input = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("清空")
                    }
                    MicButton(model: model, meter: model.meter)
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))

                Button { model.commitInput() } label: {
                    Image(systemName: "return")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(model.intent == .empty)
                .help("添加（回车）")
            }
            VoiceStatusLine(model: model)
        }
        .padding(.horizontal, 14)
        .onChange(of: model.focusRequest) { _, _ in focused = true }
        .onAppear { focused = true }
    }
}

private struct MicButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var meter: VoiceMeter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: VoiceState { model.voiceState }

    var body: some View {
        Button { model.toggleVoice() } label: {
            ZStack {
                if state == .listening {
                    Circle()
                        .fill(Color.red.opacity(0.18))
                        .scaleEffect(reduceMotion ? 1 : 1 + CGFloat(meter.level) * 0.45)
                        .animation(.easeOut(duration: 0.08), value: meter.level)
                }
                switch state {
                case .requestingPermission, .finishing:
                    ProgressView().controlSize(.small)
                default:
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("d", modifiers: .command)
        .help(state == .listening ? "点击结束听写（⌘D）" : "语音输入（⌘D）：直接口述提醒")
        .accessibilityLabel("语音输入")
    }

    private var icon: String {
        if case .failed = state { return "mic.slash.fill" }
        return "mic.fill"
    }

    private var tint: Color {
        switch state {
        case .listening: return .red
        case .failed: return .orange
        default: return .secondary
        }
    }
}

private struct VoiceStatusLine: View {
    @ObservedObject var model: AppModel

    var body: some View {
        switch model.voiceState {
        case .failed(let failure):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "mic.slash.fill").foregroundStyle(.orange).font(.system(size: 12))
                Text(failure.message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let link = failure.settingsURL, let url = URL(string: link) {
                    Button("打开设置") { NSWorkspace.shared.open(url) }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                }
                Button { model.dismissVoiceFailure() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.12)))
        case .listening:
            Label("正在听…说完停顿一下会自动结束，也可以再点一次麦克风", systemImage: "waveform")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            EmptyView()
        }
    }
}

// MARK: - Live preview of how the text was understood

private struct PreviewSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 6) {
            switch model.intent {
            case .connect(let request):
                ConnectCard(model: model, request: request)
            case .reminder:
                ForEach(Array(model.preview.enumerated()), id: \.offset) { index, event in
                    PreviewCard(model: model, event: event, index: index)
                }
                AIRow(model: model)
            case .empty:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, model.intent == .empty ? 0 : 8)
    }
}

private struct AIRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.needsAIHelp {
                if model.aiAvailable {
                    Button { model.parseWithAI() } label: {
                        HStack(spacing: 6) {
                            if model.aiBusy { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                            Text(model.aiBusy ? "AI 正在理解…" : "这句话没看懂，用 AI 解析")
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.aiBusy)
                } else {
                    Text("本地规则没看懂这句话。在设置里添加 DeepSeek Key 后，可以让 AI 帮忙理解。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            if let notice = model.aiNotice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Chip: View {
    let text: String
    let symbol: String?
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(text).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.14)))
        .foregroundStyle(tint)
    }
}

private struct PreviewCard: View {
    @ObservedObject var model: AppModel
    let event: ParsedEvent
    let index: Int

    private var cal: Calendar { model.calendar }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Chip(text: event.title, symbol: event.isDeadline ? "flag.fill" : "text.alignleft",
                     tint: event.flags.contains(.emptyTitle) ? .orange : .primary)
                    .truncationMode(.tail)
                if let due = event.due {
                    Chip(text: DisplayFormat.fullDayLabel(due, now: model.now, calendar: cal), symbol: "calendar", tint: dateTint)
                        .fixedSize()
                        .layoutPriority(1)
                    Chip(text: DisplayFormat.timeLabel(due, calendar: cal), symbol: "clock", tint: timeTint)
                        .fixedSize()
                        .layoutPriority(1)
                } else {
                    Chip(text: "无时间", symbol: "calendar.badge.exclamationmark", tint: .orange)
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            ForEach(hints, id: \.self) { hint in
                hintView(hint)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private var dateTint: Color { event.flags.contains(.past) ? .red : .accentColor }
    private var timeTint: Color {
        if event.flags.contains(.past) { return .red }
        if event.flags.contains(.ampmInferred) || event.flags.contains(.defaultTime) || event.flags.contains(.periodDefaultTime) { return .orange }
        return .accentColor
    }

    private enum Hint: Hashable {
        case past, ampm, defaultTime, noDate, recurrence, check, weekGeneric, inherited, rolled, ai
    }

    private var hints: [Hint] {
        var out: [Hint] = []
        let f = event.flags
        if f.contains(.past) { out.append(.past) }
        if f.contains(.ampmInferred) { out.append(.ampm) }
        if f.contains(.rolledForward) && !f.contains(.ampmInferred) { out.append(.rolled) }
        if f.contains(.defaultTime) || f.contains(.periodDefaultTime) { out.append(.defaultTime) }
        if f.contains(.weekGeneric) { out.append(.weekGeneric) }
        if f.contains(.dateInherited) { out.append(.inherited) }
        if f.contains(.noDateTime) { out.append(.noDate) }
        if f.contains(.recurrenceMentioned) { out.append(.recurrence) }
        if f.contains(.conflict) || f.contains(.leftoverDateWords) { out.append(.check) }
        if f.contains(.aiAssisted) { out.append(.ai) }
        return out
    }

    @ViewBuilder
    private func hintView(_ hint: Hint) -> some View {
        switch hint {
        case .past:
            HStack(spacing: 6) {
                hintText("这个时间已经过去", symbol: "exclamationmark.triangle.fill", tint: .red)
                if let alt = event.alternative {
                    Button("改为\(DisplayFormat.dayLabel(alt, now: model.now, calendar: cal))") { model.useAlternative(at: index) }
                        .buttonStyle(.link).font(.system(size: 11))
                }
            }
        case .ampm:
            HStack(spacing: 6) {
                hintText("没说上午还是下午，已按最近的一次理解", symbol: "sun.max", tint: .orange)
                if let alt = event.alternative {
                    Button("改为 \(DisplayFormat.timeLabel(alt, calendar: cal))") { model.useAlternative(at: index) }
                        .buttonStyle(.link).font(.system(size: 11))
                }
            }
        case .rolled:
            hintText("今天这个时间已过，已顺延到明天", symbol: "arrow.turn.down.right", tint: .orange)
        case .defaultTime:
            hintText("没指定具体时间，按 \(event.due.map { DisplayFormat.timeLabel($0, calendar: cal) } ?? "") 提醒", symbol: "clock.badge.questionmark", tint: .orange)
        case .weekGeneric:
            hintText("只说了“周”，已取当周的第一天或周六，可修改文字", symbol: "calendar.badge.clock", tint: .orange)
        case .inherited:
            hintText("日期沿用了上一条", symbol: "arrow.triangle.merge", tint: .secondary)
        case .noDate:
            hintText("没识别到时间，将添加为“无截止”待办", symbol: "calendar.badge.exclamationmark", tint: .orange)
        case .recurrence:
            hintText("暂不支持循环提醒，已按最近一次创建", symbol: "repeat", tint: .orange)
        case .check:
            hintText("句子里的日期或时间有冲突或无法识别，请核对", symbol: "questionmark.circle.fill", tint: .red)
        case .ai:
            hintText("由 AI 整理，添加前请核对日期和时间", symbol: "sparkles", tint: .purple)
        }
    }

    private func hintText(_ text: String, symbol: String, tint: Color) -> some View {
        Label {
            Text(text).font(.system(size: 11))
        } icon: {
            Image(systemName: symbol).font(.system(size: 10))
        }
        .foregroundStyle(tint)
    }
}

private struct ConnectCard: View {
    @ObservedObject var model: AppModel
    let request: ConnectRequest

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: request.kind.symbolName)
                .font(.system(size: 16))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(request.kind == .web ? "监控网页：\(request.url?.host ?? "")" : "连接监控源：\(request.kind.displayName)")
                    .font(.system(size: 13, weight: .semibold))
                Text(request.kind == .web
                     ? "在弹出的窗口里登录并停在要盯的页面；页面有变化时才会让 AI 读新增内容。"
                     : "需要你在弹出的窗口里自己登录；\(request.url?.host ?? "")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button("开始") { model.commitInput() }.buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.10)))
    }
}

// MARK: - List

private struct ReminderListView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            // Not lazy: the panel is sized from this content, and a lazy stack under-reports its height when a section grows.
            VStack(alignment: .leading, spacing: 0) {
                if model.sections.isEmpty {
                    EmptyState()
                }
                ForEach(model.sections) { section in
                    SectionHeader(bucket: section.bucket, count: section.items.count)
                    ForEach(section.items) { reminder in
                        ReminderRow(model: model, reminder: reminder)
                    }
                }
                if model.showCompleted && !model.recentlyCompleted.isEmpty {
                    Text("最近完成")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                        .padding(.bottom, 2)
                    ForEach(model.recentlyCompleted) { reminder in
                        ReminderRow(model: model, reminder: reminder)
                    }
                }
                if !model.ignoredItems.isEmpty {
                    IgnoredSection(model: model)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(minHeight: 110, maxHeight: 340)
    }
}

private struct SectionHeader: View {
    let bucket: DayBucket
    let count: Int

    var body: some View {
        HStack(spacing: 5) {
            Text(bucket.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(bucket == .overdue ? Color.red : Color.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

private struct EmptyState: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)
            Text("没有待办").font(.system(size: 13, weight: .medium))
            Text("在上方输入，例如：去睡觉，今晚19点")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

private func color(for urgency: Urgency) -> Color {
    switch urgency {
    case .overdue, .soon: return .red
    case .today: return .orange
    case .normal: return .secondary
    }
}

/// Per-row hover flag. `@State` is a macro in this SDK and needs Xcode's plugin, so an ObservableObject is used instead.
private final class HoverFlag: ObservableObject {
    @Published var on = false
}

private struct ReminderRow: View {
    @ObservedObject var model: AppModel
    let reminder: Reminder
    @StateObject private var hover = HoverFlag()
    private var hovering: Bool { hover.on }

    private var done: Bool { reminder.status == .done }
    private var urgency: Urgency { DisplayFormat.urgency(of: reminder.due, now: model.now) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            leading

            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(.system(size: 13, weight: .medium))
                    .strikethrough(done)
                    .foregroundStyle(done ? Color.secondary : Color.primary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .contextMenu { menuItems }
    }

    /// Own reminders have a tick circle. Items from Canvas / 课堂派 show where they come from instead: whether they are
    /// finished is decided by the website and found out when the sites are read again.
    @ViewBuilder
    private var leading: some View {
        if reminder.completionFollowsSite {
            Image(systemName: done ? "checkmark.circle.fill" : reminder.source.symbolName)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(done ? Color.secondary : (urgency == .normal ? Color.accentColor : color(for: urgency)))
                .frame(width: 20, height: 20)
                .help(done ? "已在\(reminder.source.displayName)上完成"
                           : "是否完成以\(reminder.source.displayName)网站为准；点上方的刷新会去网站重新读取")
        } else {
            Button { model.toggleDone(reminder.id) } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(done ? Color.secondary : (urgency == .normal ? Color.accentColor : color(for: urgency)))
            }
            .buttonStyle(.plain)
            .help(done ? "标为未完成" : "标为完成")
        }
    }

    private var rowBackground: Color {
        if model.highlightedID == reminder.id { return Color.accentColor.opacity(0.14) }
        return hovering ? Color.primary.opacity(0.05) : .clear
    }

    private var subtitle: String {
        var parts: [String] = []
        if let due = reminder.due { parts.append(DisplayFormat.dueLabel(due, now: model.now, calendar: model.calendar)) }
        else { parts.append("无截止") }
        if reminder.source != .manual { parts.append(reminder.source.displayName) }
        if let course = reminder.course, !course.isEmpty { parts.append(course) }
        if reminder.snoozedUntil != nil { parts.append("已推迟") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var trailing: some View {
        if hovering {
            HStack(spacing: 8) {
                if !done {
                    Menu {
                        Button("10 分钟后") { model.snooze(reminder.id, minutes: 10) }
                        Button("1 小时后") { model.snooze(reminder.id, minutes: 60) }
                        Button("明天再提醒") { model.snoozeUntilTomorrow(reminder.id) }
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("稍后提醒")
                }
                if let link = reminder.url, let url = URL(string: link) {
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.right.square") }
                        .buttonStyle(.plain)
                        .help("打开网页")
                }
                if model.canIgnore(reminder.id) {
                    Button { model.ignore(reminder.id) } label: { Image(systemName: "eye.slash") }
                        .buttonStyle(.plain)
                        .help("忽略这一项：不再提醒，可以随时恢复")
                } else if !reminder.completionFollowsSite {
                    Button { model.delete(reminder.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                        .help("删除")
                }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        } else if let due = reminder.due, !done {
            Text(DisplayFormat.countdown(to: due, now: model.now))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color(for: urgency))
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        if !done {
            Button("10 分钟后再提醒") { model.snooze(reminder.id, minutes: 10) }
            Button("1 小时后再提醒") { model.snooze(reminder.id, minutes: 60) }
            Button("明天再提醒") { model.snoozeUntilTomorrow(reminder.id) }
            Divider()
        }
        if !reminder.completionFollowsSite {
            Button(done ? "标为未完成" : "标为完成") { model.toggleDone(reminder.id) }
        }
        if let link = reminder.url, let url = URL(string: link) {
            Button("打开网页") { NSWorkspace.shared.open(url) }
        }
        if model.canIgnore(reminder.id) {
            Divider()
            Button("忽略这一项（不再提醒）") { model.ignore(reminder.id) }
        } else if !reminder.completionFollowsSite {
            Divider()
            Button("删除", role: .destructive) { model.delete(reminder.id) }
        }
    }
}

// MARK: - Ignored items

/// Website items the user chose not to be reminded about. They are still tracked: the website decides when they are done.
private struct IgnoredSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.showIgnored.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.showIgnored ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("已忽略 \(model.ignoredItems.count)")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 2)
            .help("不再提醒的网站作业；网站上标记完成或不再列出后会自动清掉")
            if model.showIgnored {
                ForEach(model.ignoredItems) { reminder in
                    IgnoredRow(model: model, reminder: reminder)
                }
            }
        }
    }
}

struct IgnoredRow: View {
    @ObservedObject var model: AppModel
    let reminder: Reminder

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "eye.slash")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(reminder.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button("恢复") { model.unignore(reminder.id) }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let due = reminder.due { parts.append(DisplayFormat.dueLabel(due, now: model.now, calendar: model.calendar)) }
        if let course = reminder.course, !course.isEmpty { parts.append(course) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Footer

/// State of the link with Apple's Reminders; a click opens its settings.
private struct AppleChip: View {
    @ObservedObject var model: AppModel
    @ObservedObject var service: AppleRemindersService

    init(model: AppModel) {
        self.model = model
        self.service = model.apple
    }

    private var color: Color {
        switch service.status {
        case .idle: return .green
        case .syncing, .asking: return .blue
        case .off: return .gray
        default: return .orange
        }
    }

    var body: some View {
        Button { model.onOpenSettingsTab?(.apple) } label: {
            HStack(spacing: 3) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text("提醒事项").font(.system(size: 11))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(service.statusText)
    }
}

private struct FooterBar: View {
    @ObservedObject var model: AppModel

    private func chipHelp(_ w: WatcherConfig) -> String {
        var text = w.lastStatus ?? "尚未同步"
        if let last = w.lastSyncAt { text += " · 上次读取 " + last.formatted(.dateTime.hour().minute().second()) }
        return text
    }

    private func statusColor(_ w: WatcherConfig) -> Color {
        if w.needsLogin { return .red }
        if !w.enabled { return .gray }
        if let status = w.lastStatus, status.hasPrefix("同步失败") { return .orange }
        return w.lastSyncAt == nil ? .gray : .green
    }

    private static func compact(_ n: Int) -> String {
        guard n >= 1_000 else { return "\(n)" }
        return n % 1_000 == 0 ? "\(n / 1_000)k" : String(format: "%.1fk", Double(n) / 1_000)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text("\(model.pendingCount) 项待办")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ForEach(model.watchers) { watcher in
                Button { model.onOpenSettings?() } label: {
                    HStack(spacing: 3) {
                        Circle().fill(statusColor(watcher)).frame(width: 6, height: 6)
                        Text(watcher.name).font(.system(size: 11))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(chipHelp(watcher))
            }
            if model.appleState.config.enabled {
                AppleChip(model: model)
            }
            if model.overdueCount > 0 {
                Text("· \(model.overdueCount) 项已逾期")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            Spacer()
            if model.aiAvailable {
                Text("AI \(Self.compact(model.aiTokensToday))/\(Self.compact(UserDefaults.standard.integer(forKey: Prefs.Key.aiDailyBudget)))")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .help("今天已用的 AI token / 每日上限")
            }
            Toggle("已完成", isOn: $model.showCompleted)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            Button("退出") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
