import SwiftUI
import RemindCore

@MainActor
final class AIFormState: ObservableObject {
    @Published var keyInput = ""
    @Published var message: String?
    @Published var isError = false
    @Published var busy = false

    func show(_ text: String, error: Bool) {
        message = text
        isError = error
    }
}

struct AISettings: View {
    @ObservedObject var model: AppModel
    @StateObject private var form = AIFormState()
    @AppStorage(Prefs.Key.aiEnabled) private var enabled = true
    @AppStorage(Prefs.Key.aiTypedAuto) private var typedAuto = false
    @AppStorage(Prefs.Key.aiDailyBudget) private var daily = 20_000
    @AppStorage(Prefs.Key.aiMonthlyBudget) private var monthly = 300_000
    @AppStorage(Prefs.Key.aiKeyPresent) private var keyPresent = false

    private var ledger: UsageLedger { model.ai.gate.ledger }

    var body: some View {
        Form {
            Section {
                LabeledContent("模型") {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill").font(.caption)
                        Text("deepseek-flash · 不开思考").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Key") {
                    Text(keyPresent ? "已保存在钥匙串" : "未设置").foregroundStyle(keyPresent ? Color.green : Color.secondary)
                }
                SecureField("粘贴 DeepSeek API Key", text: $form.keyInput)
                HStack {
                    Button("保存") { save() }.disabled(form.keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("测试连接") { testConnection() }.disabled(!keyPresent || form.busy)
                    Button("删除 Key", role: .destructive) { model.removeAIKey(); form.show("已删除。", error: false) }.disabled(!keyPresent)
                    if form.busy { ProgressView().controlSize(.small) }
                }
                if let message = form.message {
                    Text(message).font(.footnote).foregroundStyle(form.isError ? Color.red : Color.green)
                }
            } header: {
                Text("DeepSeek")
            } footer: {
                Text("Key 只保存在这台 Mac 的钥匙串里，不写进任何文件。“测试连接”只查询余额和模型列表，不消耗 token。")
            }

            Section("用量与预算") {
                LabeledContent("今天") { Text("\(model.aiTokensToday) / \(daily) tokens").foregroundStyle(.secondary) }
                LabeledContent("本月") {
                    Text("\(ledger.tokens(inMonthOf: Date())) / \(monthly) tokens · 约 ¥\(String(format: "%.4f", ledger.cost(inMonthOf: Date())))")
                        .foregroundStyle(.secondary)
                }
                Stepper(value: $daily, in: 2_000...200_000, step: 2_000) { Text("每日上限 \(daily) tokens") }
                Stepper(value: $monthly, in: 20_000...3_000_000, step: 20_000) { Text("每月上限 \(monthly) tokens") }
            }

            Section {
                Toggle("启用 AI", isOn: $enabled)
                Toggle("打字时遇到看不懂的句子，先让 AI 整理再添加", isOn: $typedAuto)
                if let reason = ledger.breakerReason {
                    Text(reason).font(.footnote).foregroundStyle(.red)
                    Button("我已检查，恢复 AI") { model.resetAIBreaker() }
                }
            } footer: {
                Text("只有本地规则看不懂的句子才会调用 AI，每次约几百 token；相同的句子会直接用缓存，不会重复计费。")
            }

            Section("最近的调用") {
                if ledger.recent.isEmpty {
                    Text("还没有调用").foregroundStyle(.secondary)
                }
                ForEach(Array(ledger.recent.prefix(6).enumerated()), id: \.offset) { _, call in
                    HStack {
                        Text(call.at, format: .dateTime.month().day().hour().minute()).foregroundStyle(.secondary)
                        Text(call.purpose)
                        Spacer()
                        Text("\(call.usage.total) tokens · \(call.outcome)").foregroundStyle(call.outcome == "ok" ? Color.secondary : Color.orange)
                    }
                    .font(.footnote)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        if model.saveAIKey(form.keyInput) {
            form.keyInput = ""
            form.show("已保存到钥匙串。可以点“测试连接”确认。", error: false)
        } else {
            form.show("写入钥匙串失败。", error: true)
        }
    }

    private func testConnection() {
        form.busy = true
        form.message = nil
        let client = DeepSeekClient(keyProvider: { KeyBox.shared.key })
        Task {
            do {
                let balances = try await client.balance()
                let models = try await client.listModels()
                var text = "连接正常"
                if let b = balances.first { text += " · 余额 \(b.total) \(b.currency)" }
                let hasFlash = models.contains(AIPolicy.model.rawValue)
                text += hasFlash ? " · deepseek-flash 可用" : " · 注意：模型列表里没有 deepseek-flash"
                form.show(text, error: !hasFlash)
            } catch let error as AIError {
                form.show(error.message, error: true)
            } catch {
                form.show(error.localizedDescription, error: true)
            }
            form.busy = false
        }
    }
}
