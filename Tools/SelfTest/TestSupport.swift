import Foundation
import RemindCore

final class FakeTransport: HTTPTransport, @unchecked Sendable {
    enum Step { case reply(Int, String), fail(String) }
    var steps: [Step] = []
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        requests.append(request)
        guard !steps.isEmpty else { return (Data("{}".utf8), 200) }
        switch steps.removeFirst() {
        case .reply(let status, let body): return (Data(body.utf8), status)
        case .fail(let message): throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}

func chatJSON(_ content: String, finish: String = "stop", prompt: Int = 300, hit: Int = 250, completion: Int = 40,
                      reasoningTokens: Int? = nil, reasoningContent: String? = nil) -> String {
    var message: [String: Any] = ["role": "assistant", "content": content]
    if let reasoningContent { message["reasoning_content"] = reasoningContent }
    var usage: [String: Any] = ["prompt_tokens": prompt, "completion_tokens": completion, "total_tokens": prompt + completion,
                                "prompt_cache_hit_tokens": hit, "prompt_cache_miss_tokens": prompt - hit]
    if let reasoningTokens { usage["completion_tokens_details"] = ["reasoning_tokens": reasoningTokens] }
    let root: [String: Any] = ["choices": [["index": 0, "message": message, "finish_reason": finish]], "usage": usage]
    let data = (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    return String(decoding: data, as: UTF8.self)
}


@MainActor
func makeTestGate(_ transport: FakeTransport, key: String? = "sk-test", config: AIConfig = AIConfig(), now: Date = Fixture.now) -> AIGate {
    let client = DeepSeekClient(transport: transport, keyProvider: { key })
    return AIGate(client: client, ledger: UsageLedger(), cache: AICache(), config: { config }, clock: { now }, pause: { _ in })
}
