import Foundation

/// "Any website + an AI that reads it", built to spend as little as possible:
/// unchanged page → nothing; changed page → only the NEW lines that mention homework or dates;
/// lines the local parser can read (a title and a date on one line) never reach the AI;
/// the rest goes to DeepSeek in one small call, capped per site and per day.
@MainActor
public final class WebPageSource {
    public struct Result: Equatable {
        public var items: [RemoteItem] = []
        public var fingerprint: String
        public var lines: [String]
        /// False when the page looks the same as last time.
        public var changed: Bool
        /// Whether the stored snapshot may move forward. It stays put when the AI step could not run, so the
        /// same lines are tried again next time instead of being forgotten.
        public var advanceSnapshot: Bool
        public var aiAttempted = false
        public var aiEmptyStreak: Int
        public var aiPausedUntil: Date?
        public var note: String
    }

    private let session: WebSessionFetching
    private let ai: AIService?
    private let context: () -> ParseContext

    public init(session: WebSessionFetching, ai: AIService?, context: @escaping () -> ParseContext) {
        self.session = session
        self.ai = ai
        self.context = context
    }

    public func check(_ watcher: WatcherConfig) async throws -> Result {
        guard let url = URL(string: watcher.url), url.host != nil else { throw SourceError.badResponse("网址不对") }
        let raw = try await session.pageText(url: url)
        let ctx = context()
        let lines = PageText.lines(from: raw)
        guard !lines.isEmpty else { throw SourceError.badResponse("页面上没有读到文字（可能还没登录，或页面还没加载出来）") }

        let fingerprint = PageText.fingerprint(lines)
        var result = Result(fingerprint: fingerprint, lines: lines, changed: true, advanceSnapshot: true,
                            aiEmptyStreak: watcher.aiEmptyStreak, aiPausedUntil: watcher.aiPausedUntil, note: "")
        if fingerprint == watcher.pageHash {
            result.changed = false
            result.note = "页面没有变化"
            return result
        }

        let added = PageText.addedLines(old: watcher.pageLines, new: lines)
        let candidates = PageText.candidates(added)
        guard !candidates.isEmpty else {
            result.note = "页面有变化，但没有新的作业信息"
            return result
        }

        let local = PageExtractor.localItems(from: candidates, watcherID: watcher.id, context: ctx)
        result.items = local.items.map { var i = $0; i.url = watcher.url; return i }
        var known = Set(result.items.map(\.key))
        var note = local.items.isEmpty ? "" : "本地读懂 \(local.items.count) 项"

        // Only lines the local parser could not read, and only if there is something to ask.
        let leftovers = local.remaining
        if !leftovers.isEmpty {
            if let pausedUntil = watcher.aiPausedUntil, pausedUntil > ctx.now {
                note += (note.isEmpty ? "" : "；") + "AI 暂停中（连续几次没发现新作业）"
            } else if let ai {
                result.aiAttempted = true
                switch await ai.extractAssignments(lines: leftovers, hint: watcher.hint, context: ctx, sourceID: watcher.id) {
                case .items(let found, _):
                    var fresh = 0
                    for a in found {
                        let key = PageExtractor.itemKey(watcherID: watcher.id, title: a.title, due: a.due)
                        guard known.insert(key).inserted else { continue }
                        result.items.append(RemoteItem(key: key, title: a.title, course: a.course, due: a.due, url: watcher.url))
                        fresh += 1
                    }
                    if fresh == 0 {
                        result.aiEmptyStreak += 1
                        if result.aiEmptyStreak >= 3 {
                            result.aiPausedUntil = ctx.now.addingTimeInterval(24 * 3_600)
                            result.aiEmptyStreak = 0
                        }
                    } else {
                        result.aiEmptyStreak = 0
                    }
                    note += (note.isEmpty ? "" : "；") + "AI 读到 \(fresh) 项"
                case .skipped(let reason):
                    result.advanceSnapshot = false
                    note += (note.isEmpty ? "" : "；") + reason.message
                case .failed(let error):
                    result.advanceSnapshot = false
                    note += (note.isEmpty ? "" : "；") + error.message
                }
            } else {
                result.advanceSnapshot = false
                note += (note.isEmpty ? "" : "；") + "有看不懂的内容，设置 DeepSeek Key 后可以让 AI 读"
            }
        }
        result.note = note
        return result
    }
}
