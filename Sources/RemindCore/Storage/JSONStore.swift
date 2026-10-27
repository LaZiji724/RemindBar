import Foundation

/// Atomic JSON persistence with a one-generation backup. A corrupt main file falls back to the backup.
public final class JSONStore<T: Codable> {
    public let url: URL
    private let backupURL: URL

    public init(url: URL) {
        self.url = url
        self.backupURL = url.appendingPathExtension("bak")
    }

    private func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private func decode(_ file: URL) throws -> T {
        try makeDecoder().decode(T.self, from: Data(contentsOf: file))
    }

    /// Returns nil when nothing has been saved yet; throws when both files exist but neither can be read.
    public func load() throws -> T? {
        let fm = FileManager.default
        let hasMain = fm.fileExists(atPath: url.path)
        let hasBackup = fm.fileExists(atPath: backupURL.path)
        guard hasMain || hasBackup else { return nil }
        if hasMain, let value = try? decode(url) { return value }
        if hasBackup { return try decode(backupURL) }
        throw CocoaError(.fileReadCorruptFile)
    }

    public func save(_ value: T) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try makeEncoder().encode(value)
        // Only rotate a main file that is still readable, so a corrupt file never overwrites a good backup.
        if fm.fileExists(atPath: url.path), (try? decode(url)) != nil {
            try? fm.removeItem(at: backupURL)
            try? fm.copyItem(at: url, to: backupURL)
        }
        try data.write(to: url, options: .atomic)
    }
}
