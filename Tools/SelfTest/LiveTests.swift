import Foundation
import RemindCore

/// `DEEPSEEK_API_KEY=… remind-selftest --live`: a few real, tiny requests (roughly 1k tokens in total).
enum LiveTests {
    @MainActor
    static func run(_ h: Harness) async {
        h.suite = "live"
        guard let key = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !key.isEmpty else {
            print("live tests skipped: set DEEPSEEK_API_KEY")
            return
        }
        print("— live DeepSeek smoke test —")
        let client = DeepSeekClient(keyProvider: { key })

        do {
            let balances = try await client.balance()
            h.check(!balances.isEmpty, "balance is readable")
            for b in balances { print("  balance: \(b.total) \(b.currency) (granted \(b.granted), topped up \(b.toppedUp))") }
        } catch {
            h.check(false, "GET /user/balance", "\(error)")
        }
        do {
            let models = try await client.listModels()
            print("  models: \(models.joined(separator: ", "))")
            h.check(models.contains("deepseek-flash"), "the model list contains deepseek-flash", "\(models)")
        } catch {
            h.check(false, "GET /models", "\(error)")
        }

        let ledger = UsageLedger(calendar: .reminder)
        let service = AIService(gate: AIGate(client: client, ledger: ledger, cache: AICache(), config: { AIConfig() }))
        let ctx = ParseContext(now: Date(), calendar: .reminder)

        let sentence = "去睡觉，今晚19点"
        switch await service.parseReminders(sentence, context: ctx) {
        case .events(let events, let cached):
            h.equal(cached, false, "first call goes to the network")
            h.equal(events.count, 1, "one reminder is returned")
            h.check(events.first?.title.contains("睡觉") == true, "title keeps the activity", "\(events.map(\.title))")
            if let due = events.first?.due {
                let c = ctx.calendar.dateComponents([.hour, .minute], from: due)
                h.check(c.hour == 19 && c.minute == 0, "the time is read as 19:00", "\(due)")
                h.check(ctx.calendar.isDate(due, inSameDayAs: ctx.now) || due > ctx.now, "the date is today (or the next 19:00)", "\(due)")
            } else {
                h.check(false, "a due date is returned")
            }
        case .skipped(let reason):
            h.check(false, "the call is not skipped", reason.message)
        case .failed(let error):
            h.check(false, "the call succeeds", error.message)
        }
        if let call = ledger.state.calls.last {
            let u = call.usage
            print("  usage: prompt \(u.promptTokens) (cache hit \(u.cacheHitTokens)), completion \(u.completionTokens), reasoning \(u.reasoningTokens), finish \(call.finishReason ?? "nil"), ≈ ¥\(String(format: "%.5f", u.estimatedCost))")
            h.equal(u.reasoningTokens, 0, "thinking is really off (0 reasoning tokens)")
            h.equal(call.finishReason, "stop", "finish_reason is stop")
            h.equal(call.outcome, "ok", "answer passed every check")
            h.check(u.total < 1_200, "one call stays small", "\(u.total) tokens")
        } else {
            h.check(false, "the call was recorded in the ledger")
        }

        let before = ledger.state.calls.count
        if case .events(_, let cached) = await service.parseReminders(sentence, context: ctx) {
            h.equal(cached, true, "the identical sentence is answered from the cache")
        }
        h.equal(ledger.state.calls.count, before, "a cache hit adds nothing to the ledger")

        // A sentence with two tasks, to see how the model reads it (informational + sanity checks).
        if case .events(let events, _) = await service.parseReminders("明晚七点半去健身，周五之前交高数作业", context: ctx) {
            for e in events { print("  → \(e.title) @ \(e.due.map { DisplayFormat.dueLabel($0, now: ctx.now, calendar: ctx.calendar) } ?? "—")\(e.isDeadline ? " (截止)" : "")") }
            h.equal(events.count, 2, "two tasks in one sentence give two reminders")
        } else {
            h.check(false, "the two-task sentence is understood")
        }
        print("  total spent in this test: \(ledger.tokens(on: Date())) tokens ≈ ¥\(String(format: "%.5f", ledger.state.calls.reduce(0) { $0 + $1.usage.estimatedCost }))")
    }
}
