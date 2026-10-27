import Foundation
import CryptoKit

public struct AICall: Codable, Equatable, Sendable {
    public var at: Date
    public var purpose: String
    public var sourceID: String?
    public var usage: TokenUsage
    public var finishReason: String?
    /// "ok" or the failure kind ("truncated", "invalidJSON", "emptyContent", "reasoning"…).
    public var outcome: String

    public init(at: Date, purpose: String, sourceID: String?, usage: TokenUsage, finishReason: String?, outcome: String) {
        self.at = at
        self.purpose = purpose
        self.sourceID = sourceID
        self.usage = usage
        self.finishReason = finishReason
        self.outcome = outcome
    }
}

public struct AILedgerState: Codable, Equatable, Sendable {
    public var calls: [AICall] = []
    /// Set when a response proved that thinking was not disabled; all AI calls stop until the user clears it.
    public var breakerReason: String?
    public var breakerAt: Date?

    public init() {}
}

/// Every token ever spent through this app, with daily / monthly sums for the budget gate.
public final class UsageLedger {
    public private(set) var state: AILedgerState
    private let store: JSONStore<AILedgerState>?
    private let calendar: Calendar

    public init(store: JSONStore<AILedgerState>? = nil, calendar: Calendar = .reminder) {
        self.store = store
        self.calendar = calendar
        self.state = (try? store?.load() ?? nil) ?? AILedgerState()
    }

    public func record(_ call: AICall) {
        state.calls.append(call)
        // Keep 90 days and at most 500 calls.
        let cutoff = call.at.addingTimeInterval(-90 * 86_400)
        state.calls.removeAll { $0.at < cutoff }
        if state.calls.count > 500 { state.calls.removeFirst(state.calls.count - 500) }
        try? store?.save(state)
    }

    public func tokens(on day: Date) -> Int {
        state.calls.filter { calendar.isDate($0.at, inSameDayAs: day) }.reduce(0) { $0 + $1.usage.total }
    }

    public func tokens(inMonthOf date: Date) -> Int {
        state.calls.filter { calendar.isDate($0.at, equalTo: date, toGranularity: .month) }.reduce(0) { $0 + $1.usage.total }
    }

    public func cost(inMonthOf date: Date) -> Double {
        state.calls.filter { calendar.isDate($0.at, equalTo: date, toGranularity: .month) }.reduce(0) { $0 + $1.usage.estimatedCost }
    }

    public func calls(on day: Date, sourceID: String) -> Int {
        state.calls.filter { $0.sourceID == sourceID && calendar.isDate($0.at, inSameDayAs: day) }.count
    }

    public var recent: [AICall] { Array(state.calls.suffix(12).reversed()) }
    public var breakerReason: String? { state.breakerReason }

    public func openBreaker(reason: String, at date: Date = Date()) {
        state.breakerReason = reason
        state.breakerAt = date
        try? store?.save(state)
    }

    public func closeBreaker() {
        state.breakerReason = nil
        state.breakerAt = nil
        try? store?.save(state)
    }
}

/// Results of earlier calls, so the same text is never billed twice.
public struct AICacheState: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var content: String
        public var at: Date
    }
    public var entries: [String: Entry] = [:]
    public init() {}
}

public final class AICache {
    private var state: AICacheState
    private let store: JSONStore<AICacheState>?

    public init(store: JSONStore<AICacheState>? = nil) {
        self.store = store
        self.state = (try? store?.load() ?? nil) ?? AICacheState()
    }

    public static func key(_ parts: String...) -> String {
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    public func get(_ key: String, now: Date) -> String? {
        guard let entry = state.entries[key], now.timeIntervalSince(entry.at) < AIPolicy.cacheLifetime else { return nil }
        return entry.content
    }

    public func set(_ key: String, content: String, now: Date) {
        state.entries[key] = AICacheState.Entry(content: content, at: now)
        state.entries = state.entries.filter { now.timeIntervalSince($0.value.at) < AIPolicy.cacheLifetime }
        if state.entries.count > 500 {
            let keep = state.entries.sorted { $0.value.at > $1.value.at }.prefix(400)
            state.entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        try? store?.save(state)
    }
}
