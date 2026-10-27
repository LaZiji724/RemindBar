import Foundation

/// The only model this app may call. There is deliberately no other case and no setting for it.
public enum DeepSeekModel: String, Sendable {
    case flash = "deepseek-flash"
}

/// Hard rules for every DeepSeek call. Changing any of these is a code change, not a setting.
public enum AIPolicy {
    public static let model = DeepSeekModel.flash
    public static let chatURL = URL(string: "https://api.deepseek.com/chat/completions")!
    public static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    public static let modelsURL = URL(string: "https://api.deepseek.com/models")!

    public static let timeout: TimeInterval = 30
    /// Longest text ever sent in one request (characters), so a runaway page can never cost a lot.
    public static let maxInputCharacters = 3_000
    public static let maxTokensParse = 384
    public static let maxTokensBatch = 900
    public static let maxItemsPerAnswer = 5
    /// Courtesy gap between two calls.
    public static let minimumCallInterval: TimeInterval = 1.0
    public static let cacheLifetime: TimeInterval = 30 * 86_400

    public static let defaultDailyBudget = 20_000
    public static let defaultMonthlyBudget = 300_000
    /// How many calls one monitored source may trigger per day.
    public static let defaultPerSourceDailyCap = 6
}

/// DeepSeek list prices for `deepseek-flash` in CNY per million tokens (peak hours, the conservative figure).
public enum AIPricing {
    public static let cacheHitPerMillion = 0.04
    public static let cacheMissPerMillion = 2.0
    public static let outputPerMillion = 8.0

    public static func cost(cacheHit: Int, cacheMiss: Int, output: Int) -> Double {
        (Double(cacheHit) * cacheHitPerMillion + Double(cacheMiss) * cacheMissPerMillion + Double(output) * outputPerMillion) / 1_000_000
    }
}

public struct TokenUsage: Codable, Equatable, Sendable {
    public var promptTokens: Int
    public var cacheHitTokens: Int
    public var cacheMissTokens: Int
    public var completionTokens: Int
    public var reasoningTokens: Int

    public init(promptTokens: Int = 0, cacheHitTokens: Int = 0, cacheMissTokens: Int = 0, completionTokens: Int = 0, reasoningTokens: Int = 0) {
        self.promptTokens = promptTokens
        self.cacheHitTokens = cacheHitTokens
        self.cacheMissTokens = cacheMissTokens
        self.completionTokens = completionTokens
        self.reasoningTokens = reasoningTokens
    }

    public var total: Int { promptTokens + completionTokens }
    public var estimatedCost: Double {
        AIPricing.cost(cacheHit: cacheHitTokens, cacheMiss: cacheMissTokens, output: completionTokens)
    }
}

public enum AIError: Error, Equatable, Sendable {
    case noKey
    case invalidKey
    case insufficientBalance
    case badRequest(String)
    case rateLimited
    case server(Int)
    case network(String)
    case emptyContent
    case truncated
    case invalidJSON
    case invalidAnswer(String)
    /// Thinking was supposed to be off but the answer carries reasoning tokens.
    case reasoningNotDisabled

    /// Transient problems worth exactly one more attempt.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .server, .network, .emptyContent: return true
        default: return false
        }
    }

    public var message: String {
        switch self {
        case .noKey: return "还没有设置 DeepSeek Key。"
        case .invalidKey: return "DeepSeek Key 无效或已被撤销，请在设置里重新粘贴。"
        case .insufficientBalance: return "DeepSeek 余额不足，请充值后再试。"
        case .badRequest(let detail): return "DeepSeek 拒绝了请求：\(detail)"
        case .rateLimited: return "DeepSeek 暂时限流，稍后再试。"
        case .server(let code): return "DeepSeek 服务暂时出错（\(code)），稍后再试。"
        case .network(let detail): return "连不上 DeepSeek：\(detail)"
        case .emptyContent: return "DeepSeek 返回了空内容。"
        case .truncated: return "DeepSeek 的回答被截断了，已放弃这次结果。"
        case .invalidJSON: return "DeepSeek 没有返回合法的 JSON，已放弃这次结果。"
        case .invalidAnswer(let detail): return "DeepSeek 的回答没通过校验：\(detail)"
        case .reasoningNotDisabled: return "检测到 DeepSeek 在“思考”（会额外消耗 token），已暂停所有 AI 调用，请在设置里检查后再恢复。"
        }
    }
}
