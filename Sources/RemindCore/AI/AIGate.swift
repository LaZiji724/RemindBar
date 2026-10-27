import Foundation

public struct AIConfig: Equatable, Sendable {
    public var enabled: Bool
    public var dailyBudget: Int
    public var monthlyBudget: Int
    public var perSourceDailyCap: Int

    public init(enabled: Bool = true, dailyBudget: Int = AIPolicy.defaultDailyBudget,
                monthlyBudget: Int = AIPolicy.defaultMonthlyBudget, perSourceDailyCap: Int = AIPolicy.defaultPerSourceDailyCap) {
        self.enabled = enabled
        self.dailyBudget = dailyBudget
        self.monthlyBudget = monthlyBudget
        self.perSourceDailyCap = perSourceDailyCap
    }
}

public enum AISkip: Equatable, Sendable {
    case disabled, noKey, dailyBudget, monthlyBudget, sourceCap
    case breakerOpen(String)

    public var message: String {
        switch self {
        case .disabled: return "AI 功能已关闭。"
        case .noKey: return "还没有设置 DeepSeek Key。"
        case .dailyBudget: return "今天的 AI 额度已用完，明天再试（可在设置里调整）。"
        case .monthlyBudget: return "本月的 AI 额度已用完（可在设置里调整）。"
        case .sourceCap: return "这个监控源今天的 AI 次数已用完。"
        case .breakerOpen(let reason): return reason
        }
    }
}

public enum AIOutcome: Equatable, Sendable {
    case cached(String)
    case fresh(String, TokenUsage)
    case skipped(AISkip)
    case failed(AIError)
}

public struct AITask: Sendable {
    public var purpose: String
    public var system: String
    public var user: String
    public var maxTokens: Int
    public var sourceID: String?
    /// Identical keys share one answer for 30 days.
    public var cacheKey: String

    public init(purpose: String, system: String, user: String, maxTokens: Int, sourceID: String? = nil, cacheKey: String) {
        self.purpose = purpose
        self.system = system
        self.user = user
        self.maxTokens = maxTokens
        self.sourceID = sourceID
        self.cacheKey = cacheKey
    }
}

/// The single door to DeepSeek: cache → switches → budgets → one call (+ one retry for transient errors) → verification.
@MainActor
public final class AIGate {
    private let client: DeepSeekClient
    public let ledger: UsageLedger
    private let cache: AICache
    private let config: () -> AIConfig
    private let clock: () -> Date
    private let pause: (TimeInterval) async -> Void
    private var lastCallAt: Date?

    /// A key problem (rejected key, empty balance) blocks further calls until the user fixes it.
    public private(set) var blockedBy: AIError?

    public init(client: DeepSeekClient, ledger: UsageLedger, cache: AICache, config: @escaping () -> AIConfig,
                clock: @escaping () -> Date = Date.init,
                pause: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.client = client
        self.ledger = ledger
        self.cache = cache
        self.config = config
        self.clock = clock
        self.pause = pause
    }

    public var hasKey: Bool { client.hasKey }

    /// Call after the key was replaced or the balance topped up.
    public func clearBlock() { blockedBy = nil }

    public func run(_ task: AITask) async -> AIOutcome {
        let cfg = config()
        guard cfg.enabled else { return .skipped(.disabled) }
        guard client.hasKey else { return .skipped(.noKey) }
        if let reason = ledger.breakerReason { return .skipped(.breakerOpen(reason)) }
        if let blockedBy { return .failed(blockedBy) }

        let now = clock()
        let key = AICache.key(task.purpose, task.cacheKey, task.system)
        if let hit = cache.get(key, now: now) { return .cached(hit) }
        if ledger.tokens(on: now) >= cfg.dailyBudget { return .skipped(.dailyBudget) }
        if ledger.tokens(inMonthOf: now) >= cfg.monthlyBudget { return .skipped(.monthlyBudget) }
        if let source = task.sourceID, ledger.calls(on: now, sourceID: source) >= cfg.perSourceDailyCap { return .skipped(.sourceCap) }

        var attempt = 0
        while true {
            attempt += 1
            await respectInterval()
            do {
                let answer = try await client.chatJSON(system: task.system, user: task.user, maxTokens: task.maxTokens)
                lastCallAt = clock()

                func record(_ outcome: String) {
                    ledger.record(AICall(at: clock(), purpose: task.purpose, sourceID: task.sourceID, usage: answer.usage,
                                         finishReason: answer.finishReason, outcome: outcome))
                }

                if answer.showedReasoning {
                    record("reasoning")
                    ledger.openBreaker(reason: AIError.reasoningNotDisabled.message, at: clock())
                    return .failed(.reasoningNotDisabled)
                }
                guard answer.finishReason == "stop" else {
                    record("truncated")
                    return .failed(.truncated)
                }
                let content = answer.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if content.isEmpty {
                    record("emptyContent")
                    if attempt < 2 { await pause(2); continue }
                    return .failed(.emptyContent)
                }
                guard let data = content.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                    record("invalidJSON")
                    return .failed(.invalidJSON)
                }
                record("ok")
                cache.set(key, content: content, now: clock())
                return .fresh(content, answer.usage)
            } catch let error as AIError {
                lastCallAt = clock()
                switch error {
                case .invalidKey, .insufficientBalance:
                    blockedBy = error
                    return .failed(error)
                default:
                    if error.isTransient && attempt < 2 {
                        await pause(2)
                        continue
                    }
                    return .failed(error)
                }
            } catch {
                return .failed(.network(error.localizedDescription))
            }
        }
    }

    private func respectInterval() async {
        guard let last = lastCallAt else { return }
        let wait = AIPolicy.minimumCallInterval - clock().timeIntervalSince(last)
        if wait > 0 { await pause(wait) }
    }
}
