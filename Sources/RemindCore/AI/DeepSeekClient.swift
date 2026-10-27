import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = AIPolicy.timeout
        config.timeoutIntervalForResource = AIPolicy.timeout * 2
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public struct ChatAnswer: Equatable, Sendable {
    public var content: String
    public var finishReason: String?
    public var usage: TokenUsage
    /// The response carried reasoning tokens or `reasoning_content` although thinking is disabled.
    public var showedReasoning: Bool
}

public struct BalanceInfo: Equatable, Sendable {
    public var currency: String
    public var total: String
    public var granted: String
    public var toppedUp: String
}

/// Thin DeepSeek client. It can only build the one request shape the policy allows.
public final class DeepSeekClient: @unchecked Sendable {
    private let transport: HTTPTransport
    private let keyProvider: @Sendable () -> String?

    public init(transport: HTTPTransport = URLSessionTransport(), keyProvider: @escaping @Sendable () -> String?) {
        self.transport = transport
        self.keyProvider = keyProvider
    }

    public var hasKey: Bool { !(keyProvider() ?? "").isEmpty }

    // MARK: request construction (public so the self-test can pin it down)

    /// The exact JSON body of every chat call: flash model, thinking disabled, JSON output, no streaming.
    public static func requestBody(system: String, user: String, maxTokens: Int) throws -> Data {
        let body: [String: Any] = [
            "model": AIPolicy.model.rawValue,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            "stream": false,
            "temperature": 0,
            "max_tokens": maxTokens,
            "response_format": ["type": "json_object"],
            "thinking": ["type": "disabled"]
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private func makeRequest(url: URL, method: String, body: Data?) throws -> URLRequest {
        guard let key = keyProvider(), !key.isEmpty else { throw AIError.noKey }
        var request = URLRequest(url: url, timeoutInterval: AIPolicy.timeout)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    // MARK: calls

    public func chatJSON(system: String, user: String, maxTokens: Int) async throws -> ChatAnswer {
        let clipped = String(user.prefix(AIPolicy.maxInputCharacters))
        let body = try Self.requestBody(system: system, user: clipped, maxTokens: maxTokens)
        let request = try makeRequest(url: AIPolicy.chatURL, method: "POST", body: body)
        let (data, status) = try await perform(request)
        try Self.check(status: status, data: data)
        return try Self.parseChat(data)
    }

    public func balance() async throws -> [BalanceInfo] {
        let request = try makeRequest(url: AIPolicy.balanceURL, method: "GET", body: nil)
        let (data, status) = try await perform(request)
        try Self.check(status: status, data: data)
        struct Root: Decodable {
            struct Item: Decodable { let currency: String; let total_balance: String; let granted_balance: String; let topped_up_balance: String }
            let balance_infos: [Item]
        }
        let root = try JSONDecoder().decode(Root.self, from: data)
        return root.balance_infos.map { BalanceInfo(currency: $0.currency, total: $0.total_balance, granted: $0.granted_balance, toppedUp: $0.topped_up_balance) }
    }

    public func listModels() async throws -> [String] {
        let request = try makeRequest(url: AIPolicy.modelsURL, method: "GET", body: nil)
        let (data, status) = try await perform(request)
        try Self.check(status: status, data: data)
        struct Root: Decodable { struct Item: Decodable { let id: String }; let data: [Item] }
        return try JSONDecoder().decode(Root.self, from: data).data.map(\.id)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, status) = try await transport.send(request)
            return (data, status)
        } catch let error as AIError {
            throw error
        } catch {
            throw AIError.network((error as NSError).localizedDescription)
        }
    }

    // MARK: response handling (static and pure so it can be tested with canned JSON)

    public static func check(status: Int, data: Data) throws {
        switch status {
        case 200: return
        case 401: throw AIError.invalidKey
        case 402: throw AIError.insufficientBalance
        case 429: throw AIError.rateLimited
        case 400, 422: throw AIError.badRequest(errorMessage(in: data))
        case 500...599: throw AIError.server(status)
        default: throw AIError.network("HTTP \(status)")
        }
    }

    private static func errorMessage(in data: Data) -> String {
        struct Root: Decodable { struct E: Decodable { let message: String? }; let error: E? }
        let text = (try? JSONDecoder().decode(Root.self, from: data))?.error?.message ?? String(decoding: data.prefix(200), as: UTF8.self)
        return String(text.prefix(200))
    }

    public static func parseChat(_ data: Data) throws -> ChatAnswer {
        struct Root: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String?; let reasoning_content: String? }
                let message: Message
                let finish_reason: String?
            }
            struct Usage: Decodable {
                struct Details: Decodable { let reasoning_tokens: Int? }
                let prompt_tokens: Int?
                let completion_tokens: Int?
                let prompt_cache_hit_tokens: Int?
                let prompt_cache_miss_tokens: Int?
                let completion_tokens_details: Details?
            }
            let choices: [Choice]
            let usage: Usage?
        }
        guard let root = try? JSONDecoder().decode(Root.self, from: data), let choice = root.choices.first else {
            throw AIError.invalidJSON
        }
        let u = root.usage
        let prompt = u?.prompt_tokens ?? 0
        let hit = u?.prompt_cache_hit_tokens ?? 0
        let miss = u?.prompt_cache_miss_tokens ?? max(prompt - hit, 0)
        let reasoning = u?.completion_tokens_details?.reasoning_tokens ?? 0
        let usage = TokenUsage(promptTokens: prompt, cacheHitTokens: hit, cacheMissTokens: miss,
                               completionTokens: u?.completion_tokens ?? 0, reasoningTokens: reasoning)
        let showed = reasoning > 0 || !(choice.message.reasoning_content ?? "").isEmpty
        return ChatAnswer(content: choice.message.content ?? "", finishReason: choice.finish_reason, usage: usage, showedReasoning: showed)
    }
}
