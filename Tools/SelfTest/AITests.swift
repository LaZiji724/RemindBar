import Foundation
import RemindCore

private let goodItems = #"{"items":[{"title":"去睡觉","date":"2026-10-26","time":"19:00","deadline":false}]}"#

enum AITests {
    @MainActor
    static func run(_ h: Harness) async {
        h.suite = "ai"
        requestShape(h)
        responseParsing(h)
        validator(h)
        await gate(h)
        await service(h)
        ledger(h)
        policyScan(h)
    }

    // MARK: request shape — the part that must never drift

    private static func requestShape(_ h: Harness) {
        guard let data = try? DeepSeekClient.requestBody(system: "系统 json", user: "用户", maxTokens: 384),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            h.check(false, "request body is valid JSON")
            return
        }
        h.equal(obj["model"] as? String, "deepseek-flash", "model is deepseek-flash")
        h.equal((obj["thinking"] as? [String: Any])?["type"] as? String, "disabled", "thinking is disabled")
        h.equal((obj["response_format"] as? [String: Any])?["type"] as? String, "json_object", "JSON output mode")
        h.equal(obj["stream"] as? Bool, false, "no streaming")
        h.equal(obj["temperature"] as? Int, 0, "temperature 0")
        h.equal(obj["max_tokens"] as? Int, 384, "max_tokens is set")
        let messages = obj["messages"] as? [[String: Any]]
        h.equal(messages?.map { $0["role"] as? String ?? "" } ?? [], ["system", "user"], "system prompt first, user text last")
        let forbidden = ["reasoning_effort", "reasoning", "output_config", "top_p", "tools"]
        h.equal(forbidden.filter { obj[$0] != nil }, [], "no other mode switches are sent")
        h.equal(Set(obj.keys), ["model", "messages", "stream", "temperature", "max_tokens", "response_format", "thinking"],
                "the body has exactly the allowed fields")
        h.equal(AIPolicy.model.rawValue, "deepseek-flash", "policy model")
    }

    private static func responseParsing(_ h: Harness) {
        let ok = try? DeepSeekClient.parseChat(Data(chatJSON(goodItems).utf8))
        h.equal(ok?.finishReason, "stop", "finish reason parsed")
        h.equal(ok?.usage.cacheHitTokens, 250, "cache hit tokens parsed")
        h.equal(ok?.usage.cacheMissTokens, 50, "cache miss tokens parsed")
        h.equal(ok?.usage.completionTokens, 40, "completion tokens parsed")
        h.equal(ok?.showedReasoning, false, "no reasoning by default")
        let thinking = try? DeepSeekClient.parseChat(Data(chatJSON(goodItems, reasoningTokens: 120).utf8))
        h.equal(thinking?.showedReasoning, true, "reasoning tokens are detected")
        let thinkingText = try? DeepSeekClient.parseChat(Data(chatJSON(goodItems, reasoningContent: "让我想想").utf8))
        h.equal(thinkingText?.showedReasoning, true, "reasoning_content is detected")
        h.check((try? DeepSeekClient.parseChat(Data("not json".utf8))) == nil, "garbage response is rejected")
        let noUsage = try? DeepSeekClient.parseChat(Data(#"{"choices":[{"message":{"content":"{}"},"finish_reason":"stop"}]}"#.utf8))
        h.equal(noUsage?.usage.total, 0, "missing usage is tolerated as zero")
        for (status, expected) in [(401, AIError.invalidKey), (402, .insufficientBalance), (429, .rateLimited), (503, .server(503))] {
            do { try DeepSeekClient.check(status: status, data: Data()); h.check(false, "status \(status) throws") }
            catch { h.equal(error as? AIError, expected, "status \(status) maps to \(expected)") }
        }
    }

    // MARK: validator

    private static func validator(_ h: Harness) {
        let ctx = Fixture.context
        func items(_ json: String) -> [AIReminderItem]? {
            if case .success(let v) = ResultValidator.parseReminderItems(json, now: ctx.now, calendar: ctx.calendar) { return v }
            return nil
        }
        h.equal(items(goodItems)?.first?.title, "去睡觉", "valid item accepted")
        h.check(items(#"{"items":[{"title":"x","date":"2026-13-45","time":null}]}"#) == nil, "impossible date rejected")
        h.check(items(#"{"items":[{"title":"x","date":"2030-01-01","time":null}]}"#) == nil, "date beyond two years rejected")
        h.check(items(#"{"items":[{"title":"x","date":"2025-01-01","time":null}]}"#) == nil, "date far in the past rejected")
        h.check(items(#"{"items":[{"title":"x","date":"2026-10-25","time":null}]}"#) != nil, "yesterday is still accepted")
        h.check(items(#"{"items":[{"title":"x","date":null,"time":"25:00"}]}"#) == nil, "impossible time rejected")
        h.check(items(#"{"items":[{"title":"x","date":null,"time":"7:30"}]}"#) == nil, "time must be HH:mm")
        h.check(items(#"{"items":[{"title":"","date":null,"time":null}]}"#) == nil, "empty title rejected")
        h.check(items(#"{"items":[{"title":"\#(String(repeating: "长", count: 81))","date":null,"time":null}]}"#) == nil, "title over 80 characters rejected")
        h.check(items("[1,2]") == nil, "wrong shape rejected")
        h.equal(items(#"{"title":"单条","date":null,"time":null}"#)?.count, 1, "a bare object is read as one item")
        let many = (1...8).map { #"{"title":"事\#($0)","date":null,"time":null}"# }.joined(separator: ",")
        h.equal(items(#"{"items":[\#(many)]}"#)?.count, 5, "at most 5 items are kept")
        let mixed = #"{"items":[{"title":"好","date":null,"time":null},{"title":"坏","date":"2026-02-31","time":null}]}"#
        h.equal(items(mixed)?.map(\.title), ["好"], "one bad item does not spoil the others")

        func event(_ json: String) -> ParsedEvent? {
            items(json).flatMap { ResultValidator.events(from: $0, context: ctx, original: "原文").first }
        }
        let full = event(#"{"items":[{"title":"去健身","date":"2026-10-27","time":"19:30","deadline":false}]}"#)
        h.equal(Fixture.format(full?.due), "2026-10-27 19:30", "date + time combined")
        h.check(full?.flags.contains(.aiAssisted) == true, "AI results are flagged")
        h.equal(full?.hasExplicitTime, true, "explicit time")
        let dl = event(#"{"items":[{"title":"交作业","date":"2026-10-30","time":null,"deadline":true}]}"#)
        h.equal(Fixture.format(dl?.due), "2026-10-30 23:59", "deadline without time uses 23:59")
        h.equal(dl?.isDeadline, true, "deadline flag carried")
        let plain = event(#"{"items":[{"title":"开会","date":"2026-10-30","time":null,"deadline":false}]}"#)
        h.equal(Fixture.format(plain?.due), "2026-10-30 09:00", "date without time uses the default time")
        let timeOnly = event(#"{"items":[{"title":"喝水","date":null,"time":"19:30"}]}"#)
        h.equal(Fixture.format(timeOnly?.due), "2026-10-27 19:30", "time only rolls to the next day when it has passed")
        let none = event(#"{"items":[{"title":"买牛奶","date":null,"time":null}]}"#)
        h.equal(none?.due, nil, "no date and no time -> no due date")
        h.equal(none?.confidence, .low, "no due date is low confidence")
    }

    // MARK: gate

    @MainActor
    private static func makeGate(_ transport: FakeTransport, key: String? = "sk-test", config: AIConfig = AIConfig(),
                                 now: Date = Fixture.now) -> AIGate {
        let client = DeepSeekClient(transport: transport, keyProvider: { key })
        return AIGate(client: client, ledger: UsageLedger(), cache: AICache(), config: { config }, clock: { now }, pause: { _ in })
    }

    private static func task(_ text: String = "去睡觉，今晚19点", source: String? = nil) -> AITask {
        AITask(purpose: "parse", system: Prompts.parseSystem, user: "输入：\(text)", maxTokens: 384, sourceID: source, cacheKey: text)
    }

    @MainActor
    private static func gate(_ h: Harness) async {
        // Happy path, ledger and cache.
        do {
            let t = FakeTransport(); t.steps = [.reply(200, chatJSON(goodItems))]
            let g = makeGate(t)
            let first = await g.run(task())
            h.check({ if case .fresh = first { return true }; return false }(), "first call is fresh")
            h.equal(t.requests.count, 1, "one request sent")
            h.equal(t.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test", "bearer header")
            h.equal(t.requests.first?.httpMethod, "POST", "POST")
            h.equal(t.requests.first?.url, AIPolicy.chatURL, "chat endpoint")
            h.equal(g.ledger.state.calls.count, 1, "the call is recorded")
            h.equal(g.ledger.tokens(on: Fixture.now), 340, "tokens recorded (prompt + completion)")
            let second = await g.run(task())
            h.check({ if case .cached = second { return true }; return false }(), "same input is served from the cache")
            h.equal(t.requests.count, 1, "a cache hit sends nothing")
            h.equal(g.ledger.state.calls.count, 1, "a cache hit costs nothing")
        }
        // Switches.
        do {
            let t = FakeTransport()
            let noKey = await makeGate(t, key: nil).run(task())
            h.equal(noKey, .skipped(.noKey), "no key -> skipped")
            let off = await makeGate(t, config: AIConfig(enabled: false)).run(task())
            h.equal(off, .skipped(.disabled), "disabled -> skipped")
            h.equal(t.requests.count, 0, "nothing sent while skipped")
        }
        // Key problems block until fixed.
        do {
            let t = FakeTransport(); t.steps = [.reply(401, #"{"error":{"message":"bad key"}}"#)]
            let g = makeGate(t)
            h.equal(await g.run(task()), .failed(.invalidKey), "401 -> invalid key")
            h.equal(await g.run(task("另一句")), .failed(.invalidKey), "stays blocked")
            h.equal(t.requests.count, 1, "no retries against a rejected key")
            g.clearBlock()
            t.steps = [.reply(200, chatJSON(goodItems))]
            let again = await g.run(task("另一句"))
            h.check({ if case .fresh = again { return true }; return false }(), "works again after the key was replaced")
        }
        do {
            let t = FakeTransport(); t.steps = [.reply(402, "{}")]
            h.equal(await makeGate(t).run(task()), .failed(.insufficientBalance), "402 -> insufficient balance")
            let t2 = FakeTransport(); t2.steps = [.reply(400, #"{"error":{"message":"invalid param"}}"#)]
            h.equal(await makeGate(t2).run(task()), .failed(.badRequest("invalid param")), "400 -> bad request, not retried")
            h.equal(t2.requests.count, 1, "400 is not retried")
        }
        // Exactly one retry for transient trouble.
        do {
            let t = FakeTransport(); t.steps = [.reply(429, "{}"), .reply(200, chatJSON(goodItems))]
            let result = await makeGate(t).run(task())
            h.check({ if case .fresh = result { return true }; return false }(), "429 then success")
            h.equal(t.requests.count, 2, "one retry")
            let t2 = FakeTransport(); t2.steps = [.reply(500, "{}"), .reply(503, "{}"), .reply(200, chatJSON(goodItems))]
            h.equal(await makeGate(t2).run(task()), .failed(.server(503)), "two server errors give up")
            h.equal(t2.requests.count, 2, "never more than two attempts")
            let t3 = FakeTransport(); t3.steps = [.fail("offline"), .reply(200, chatJSON(goodItems))]
            let net = await makeGate(t3).run(task())
            h.check({ if case .fresh = net { return true }; return false }(), "network error then success")
            let t4 = FakeTransport(); t4.steps = [.reply(200, chatJSON("")), .reply(200, chatJSON(goodItems))]
            let g4 = makeGate(t4)
            let empty = await g4.run(task())
            h.check({ if case .fresh = empty { return true }; return false }(), "empty content is retried once")
            h.equal(g4.ledger.state.calls.map(\.outcome), ["emptyContent", "ok"], "both attempts are accounted for")
        }
        // Answers that must be rejected, without retries.
        do {
            let t = FakeTransport(); t.steps = [.reply(200, chatJSON("这不是json"))]
            let g = makeGate(t)
            h.equal(await g.run(task()), .failed(.invalidJSON), "non-JSON answer rejected")
            h.equal(t.requests.count, 1, "not retried")
            h.equal(g.ledger.state.calls.first?.outcome, "invalidJSON", "tokens of a bad answer are still recorded")
            let t2 = FakeTransport(); t2.steps = [.reply(200, chatJSON(goodItems, finish: "length"))]
            h.equal(await makeGate(t2).run(task()), .failed(.truncated), "finish_reason length rejected")
            let t3 = FakeTransport(); t3.steps = [.reply(200, chatJSON(goodItems, finish: "content_filter"))]
            h.equal(await makeGate(t3).run(task()), .failed(.truncated), "any finish reason but stop rejected")
        }
        // The breaker: thinking turned out not to be off.
        do {
            let t = FakeTransport(); t.steps = [.reply(200, chatJSON(goodItems, reasoningTokens: 90))]
            let g = makeGate(t)
            h.equal(await g.run(task()), .failed(.reasoningNotDisabled), "reasoning tokens trip the breaker")
            h.check(g.ledger.breakerReason != nil, "breaker is open")
            h.equal(g.ledger.tokens(on: Fixture.now), 340, "the spent tokens are still accounted for")
            let blocked = await g.run(task("另一句"))
            h.check({ if case .skipped(.breakerOpen) = blocked { return true }; return false }(), "later calls are skipped")
            h.equal(t.requests.count, 1, "nothing is sent while the breaker is open")
            g.ledger.closeBreaker()
            t.steps = [.reply(200, chatJSON(goodItems))]
            let resumed = await g.run(task("第三句"))
            h.check({ if case .fresh = resumed { return true }; return false }(), "works again once the breaker is cleared")
            let t2 = FakeTransport(); t2.steps = [.reply(200, chatJSON(goodItems, reasoningContent: "思考过程"))]
            let g2 = makeGate(t2)
            h.equal(await g2.run(task()), .failed(.reasoningNotDisabled), "reasoning_content trips the breaker too")
        }
        // Budgets.
        do {
            let t = FakeTransport(); t.steps = [.reply(200, chatJSON(goodItems)), .reply(200, chatJSON(goodItems))]
            let g = makeGate(t, config: AIConfig(dailyBudget: 300))
            _ = await g.run(task("第一句"))
            h.equal(await g.run(task("第二句")), .skipped(.dailyBudget), "daily budget stops further calls")
            h.equal(t.requests.count, 1, "nothing sent over budget")
            let t2 = FakeTransport(); t2.steps = [.reply(200, chatJSON(goodItems))]
            let g2 = makeGate(t2, config: AIConfig(monthlyBudget: 300))
            _ = await g2.run(task("第一句"))
            h.equal(await g2.run(task("第二句")), .skipped(.monthlyBudget), "monthly budget stops further calls")
            let t3 = FakeTransport(); t3.steps = Array(repeating: .reply(200, chatJSON(goodItems)), count: 5)
            let g3 = makeGate(t3, config: AIConfig(perSourceDailyCap: 2))
            _ = await g3.run(task("a", source: "w1"))
            _ = await g3.run(task("b", source: "w1"))
            h.equal(await g3.run(task("c", source: "w1")), .skipped(.sourceCap), "per-source daily cap")
            let other = await g3.run(task("c", source: "w2"))
            h.check({ if case .fresh = other { return true }; return false }(), "other sources are not affected")
        }
        // Input is clipped before it leaves the machine.
        do {
            let t = FakeTransport(); t.steps = [.reply(200, chatJSON(goodItems))]
            let g = makeGate(t)
            _ = await g.run(AITask(purpose: "parse", system: Prompts.parseSystem, user: String(repeating: "长", count: 5_000),
                                   maxTokens: 384, cacheKey: "long"))
            if let body = t.requests.first?.httpBody,
               let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let user = (obj["messages"] as? [[String: Any]])?.last?["content"] as? String {
                h.check(user.count <= AIPolicy.maxInputCharacters, "user text is clipped to \(AIPolicy.maxInputCharacters) characters", "was \(user.count)")
            } else {
                h.check(false, "request body readable")
            }
        }
    }

    @MainActor
    private static func service(_ h: Harness) async {
        let t = FakeTransport()
        t.steps = [.reply(200, chatJSON(#"{"items":[{"title":"去睡觉","date":"2026-10-26","time":"19:00","deadline":false}]}"#))]
        let svc = AIService(gate: makeGate(t))
        let outcome = await svc.parseReminders("去睡觉，今晚19点", context: Fixture.context)
        if case .events(let events, let cached) = outcome {
            h.equal(events.first?.title, "去睡觉", "service returns validated events")
            h.equal(cached, false, "fresh result")
        } else {
            h.check(false, "service returns events", "\(outcome)")
        }
        if let body = t.requests.first?.httpBody, let text = String(data: body, encoding: .utf8) {
            h.check(text.contains("现在：2026-10-26 周一 21:05"), "the current time goes into the user message")
            h.check(text.contains("去睡觉，今晚19点"), "the sentence goes into the user message")
        }
        h.check(Prompts.parseSystem.contains("json"), "the system prompt mentions json (required by JSON mode)")
        let again = await svc.parseReminders("去睡觉，今晚19点", context: Fixture.context)
        if case .events(_, let cached) = again { h.equal(cached, true, "second identical request is cached") }
        let bad = FakeTransport(); bad.steps = [.reply(200, chatJSON(#"{"items":[{"title":"x","date":"2099-01-01","time":null}]}"#))]
        let outcome2 = await AIService(gate: makeGate(bad)).parseReminders("乱七八糟", context: Fixture.context)
        h.check({ if case .failed(.invalidAnswer) = outcome2 { return true }; return false }(), "an answer that fails validation never becomes a reminder")
    }

    // MARK: ledger

    @MainActor
    private static func ledger(_ h: Harness) {
        let l = UsageLedger(calendar: Fixture.calendar)
        let usage = TokenUsage(promptTokens: 1_000, cacheHitTokens: 800, cacheMissTokens: 200, completionTokens: 100)
        l.record(AICall(at: Fixture.date("2026-10-26 10:00"), purpose: "parse", sourceID: "a", usage: usage, finishReason: "stop", outcome: "ok"))
        l.record(AICall(at: Fixture.date("2026-10-26 12:00"), purpose: "parse", sourceID: "a", usage: usage, finishReason: "stop", outcome: "ok"))
        l.record(AICall(at: Fixture.date("2026-10-20 12:00"), purpose: "parse", sourceID: nil, usage: usage, finishReason: "stop", outcome: "ok"))
        l.record(AICall(at: Fixture.date("2026-09-30 12:00"), purpose: "parse", sourceID: nil, usage: usage, finishReason: "stop", outcome: "ok"))
        let day = Fixture.date("2026-10-26 21:00")
        h.equal(l.tokens(on: day), 2_200, "tokens per day")
        h.equal(l.tokens(inMonthOf: day), 3_300, "tokens per month")
        h.equal(l.calls(on: day, sourceID: "a"), 2, "calls per source per day")
        h.equal(l.calls(on: day, sourceID: "b"), 0, "unknown source")
        // 800 hit * 0.04 + 200 miss * 2 + 100 out * 8 = 32 + 400 + 800 per million
        let expected = (800 * 0.04 + 200 * 2.0 + 100 * 8.0) / 1_000_000
        h.check(abs(usage.estimatedCost - expected) < 1e-12, "cost estimate uses the flash price table", "\(usage.estimatedCost)")
        l.openBreaker(reason: "测试")
        h.equal(l.breakerReason, "测试", "breaker reason")
        l.closeBreaker()
        h.equal(l.breakerReason, nil, "breaker cleared")
    }

    // MARK: static policy: nothing but deepseek-flash may appear in the sources

    private static func policyScan(_ h: Harness) {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources")
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            print("note: Sources/ not found from \(FileManager.default.currentDirectoryPath); policy scan skipped")
            return
        }
        var scanned = 0
        var bad: [String] = []
        let modelName = try? NSRegularExpression(pattern: #"deepseek-[a-z0-9][a-z0-9.\-]*"#, options: [.caseInsensitive])
        let forbiddenKeys = ["reasoning_effort", "output_config", "\"top_p\""]
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            let ns = text as NSString
            for m in modelName?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
                let name = ns.substring(with: m.range).lowercased()
                // The two "-key" names are keychain/CLI identifiers, not models.
                if !["deepseek-flash", "deepseek-api-key", "deepseek-key"].contains(name) { bad.append("\(url.lastPathComponent): \(name)") }
            }
            for key in forbiddenKeys where text.contains(key) { bad.append("\(url.lastPathComponent): \(key)") }
        }
        h.check(scanned > 5, "policy scan found the source files", "scanned \(scanned)")
        h.equal(bad, [], "no other model name or mode switch appears anywhere in Sources/")
    }
}
