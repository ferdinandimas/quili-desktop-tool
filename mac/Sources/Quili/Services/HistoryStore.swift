import Foundation

/// One finished request, kept so it can be looked at (and copied) later in the History window.
struct HistoryEntry: Codable, Identifiable {
    let id: String
    let time: Date
    /// "paraphrase", "translate" or "summarize".
    let kind: String
    /// The name of the app that was in front when the request ran, if known.
    let app: String?
    /// The text sent (cut to 2000 characters; empty for Slack thread summaries).
    let original: String
    let result: String

    var title: String {
        switch kind {
        case "translate": return "Translate to English"
        case "summarize": return "Summarize"
        default: return "Paraphrase"
        }
    }
}

/// The last 10 requests, newest first, in `~/Library/Application Support/Quili/history.json` (`%APPDATA%\Quili\history.json`
/// on Windows). Only written while "Keep my last 10 rewrites" is on.
final class HistoryStore: @unchecked Sendable {
    static let shared = HistoryStore()
    static let limit = 10, originalLimit = 2000, resultLimit = 20_000

    private let lock = NSLock()
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Quili")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    private func read() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([HistoryEntry].self, from: data)) ?? []
    }

    private func write(_ entries: [HistoryEntry]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) { try? data.write(to: url, options: .atomic) }
    }

    func entries() -> [HistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    func add(kind: String, app: String?, original: String, result: String) {
        lock.lock(); defer { lock.unlock() }
        let cut = original.count > Self.originalLimit ? String(original.prefix(Self.originalLimit)) + "…" : original
        let entry = HistoryEntry(id: UUID().uuidString, time: Date(), kind: kind, app: app, original: cut,
                                 result: String(result.prefix(Self.resultLimit)))
        write(Array(([entry] + read()).prefix(Self.limit)))
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }
}
