import Foundation

/// Splits one utterance into events: only cut where BOTH neighbours carry their own date/time and a title.
enum EventSplitter {
    private struct Piece {
        var text: String
        var hasDate: Bool
        var hasTime: Bool
        var hasTitle: Bool
        var hasDateTime: Bool { hasDate || hasTime }
    }

    private static let connectors = ["再然后", "然后", "接着", "另外", "还有", "以及"]
    private static let separators = CharacterSet(charactersIn: "，,。；;！!？?\n")

    static func split(_ raw: String) -> [String] {
        var text = TextNormalizer.normalize(raw)
        for c in connectors { text = text.replacingOccurrences(of: c, with: "，") }
        let rawPieces = text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard rawPieces.count > 1 else { return [TextNormalizer.normalize(raw)] }

        var groups: [[Piece]] = []
        var current: [Piece] = []
        for piece in rawPieces.map(analyze) {
            guard !current.isEmpty else { current = [piece]; continue }
            let curDate = current.contains { $0.hasDate }
            let curTime = current.contains { $0.hasTime }
            let curTitle = current.contains { $0.hasTitle }
            let curComplete = curTitle && (curDate || curTime)
            let pieceComplete = piece.hasTitle && piece.hasDateTime
            if (curComplete && pieceComplete) || (curDate && piece.hasDate) || (curTime && piece.hasTime) {
                groups.append(current)
                current = [piece]
            } else {
                current.append(piece)
            }
        }
        if !current.isEmpty { groups.append(current) }
        return groups.map { $0.map(\.text).joined(separator: "，") }
    }

    private static func analyze(_ s: String) -> Piece {
        let toks = Tokenizer.tokenize(s)
        var hasDate = false
        var hasTime = false
        for t in toks {
            if t.isDate { hasDate = true }
            if t.isClock || t.isPeriod { hasTime = true }
            if case .offset(let unit, _) = t.kind {
                switch unit {
                case .second, .minute, .hour: hasTime = true
                default: hasDate = true
                }
            }
        }
        let title = TitleExtractor.extract(from: s, removing: toks.map { $0.range })
        return Piece(text: s, hasDate: hasDate, hasTime: hasTime, hasTitle: !title.isEmpty)
    }
}

public enum NLParser {
    /// Parses typed or dictated text into one or more events.
    public static func parse(_ text: String, context: ParseContext) -> [ParsedEvent] {
        var results: [ParsedEvent] = []
        var inherited: Date?
        for segment in EventSplitter.split(text) {
            let out = DateTimeParser.parse(segment: segment, ctx: context, inheritDate: inherited)
            results.append(out.event)
            if let start = out.dateStart { inherited = start }
        }
        return results
    }
}
