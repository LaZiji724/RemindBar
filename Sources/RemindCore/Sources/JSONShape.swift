import Foundation

/// Describes the STRUCTURE of a JSON document (field names, types, enum-like values) without its content, so
/// an API can be calibrated without reading anyone's course names or assignment titles.
public enum JSONShape {
    /// Values of these keys are kept verbatim because they are protocol vocabulary, not personal content.
    private static let vocabulary: Set<String> = [
        "plannable_type", "context_type", "workflow_state", "type", "status", "code", "state", "submission_types",
        "late", "missing", "submitted", "excused", "graded", "needs_grading", "marked_complete", "dismissed"
    ]

    public static func describe(_ jsonText: String, maxItems: Int = 2) -> String {
        guard let data = jsonText.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return "(not JSON, \(jsonText.count) characters)"
        }
        var lines: [String] = []
        render(object, key: nil, indent: 0, maxItems: maxItems, into: &lines)
        return lines.joined(separator: "\n")
    }

    private static func render(_ value: Any, key: String?, indent: Int, maxItems: Int, into lines: inout [String]) {
        let pad = String(repeating: "  ", count: indent)
        let label = key.map { "\($0): " } ?? ""
        switch value {
        case let dict as [String: Any]:
            lines.append("\(pad)\(label){")
            for k in dict.keys.sorted() { render(dict[k]!, key: k, indent: indent + 1, maxItems: maxItems, into: &lines) }
            lines.append("\(pad)}")
        case let array as [Any]:
            lines.append("\(pad)\(label)[ \(array.count) items")
            for element in array.prefix(maxItems) { render(element, key: nil, indent: indent + 1, maxItems: maxItems, into: &lines) }
            if array.count > maxItems { lines.append("\(pad)  … \(array.count - maxItems) more") }
            lines.append("\(pad)]")
        case let string as String:
            if let key, vocabulary.contains(key) {
                lines.append("\(pad)\(label)\"\(string)\"")
            } else if looksLikeDate(string) {
                lines.append("\(pad)\(label)<date \(shapeOfDate(string))>")
            } else {
                lines.append("\(pad)\(label)<string, \(string.count) chars>")
            }
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                lines.append("\(pad)\(label)\(number.boolValue)")
            } else if let key, vocabulary.contains(key) {
                lines.append("\(pad)\(label)\(number)")
            } else {
                lines.append("\(pad)\(label)<number>")
            }
        case is NSNull:
            lines.append("\(pad)\(label)null")
        default:
            lines.append("\(pad)\(label)<\(type(of: value))>")
        }
    }

    private static func looksLikeDate(_ s: String) -> Bool {
        s.range(of: #"^\d{4}-\d{2}-\d{2}([T ]\d{2}:\d{2}(:\d{2})?(\.\d+)?(Z|[+-]\d{2}:?\d{2})?)?$"#, options: .regularExpression) != nil
    }

    /// "2026-10-30T15:59:00Z" -> "YYYY-MM-DDTHH:MM:SSZ" (format only)
    private static func shapeOfDate(_ s: String) -> String {
        String(s.map { $0.isNumber ? "N" : $0 }).replacingOccurrences(of: "NNNN-NN-NN", with: "YYYY-MM-DD")
            .replacingOccurrences(of: "NN:NN:NN", with: "HH:MM:SS").replacingOccurrences(of: "NN:NN", with: "HH:MM")
    }
}
