import DatabaseKit
import Foundation

actor IDEDatabaseQueryHistory {
    struct Entry: Codable, Identifiable, Sendable {
        enum Status: String, Codable, Sendable {
            case completed = "Completed", failed = "Failed", cancelled = "Cancelled"
        }

        let id: UUID
        let source: UUID
        let date: Date
        let preview: String
        let status: Status
        let seconds: Double
    }

    struct Attempt: Sendable {
        let statement: String
        let status: Entry.Status
        let duration: Duration
        let date = Date.now

        init(statement: String, status: Entry.Status, duration: Duration) {
            self.statement = statement.utf8.prefix(32_769).count <= 32_768 ? statement : ""
            self.status = status
            self.duration = duration
        }
    }

    static let limit = 100
    private let url: URL
    private var cached: [Entry]?

    init(url: URL) {
        self.url = url
    }

    func entries(source: UUID) -> [Entry] {
        entries().filter { $0.source == source }
    }

    func record(_ attempts: [Attempt], source: UUID, engine: DatabaseEngine) {
        guard !attempts.isEmpty else { return }
        let recent = attempts.suffix(Self.limit).reversed().map { attempt in
            let time = attempt.duration.components
            return Entry(id: UUID(), source: source, date: attempt.date,
                         preview: Self.preview(attempt.statement, engine: engine), status: attempt.status,
                         seconds: Double(time.seconds) + Double(time.attoseconds) / 1e18)
        }
        persist(Array((recent + entries()).prefix(Self.limit)))
    }

    func remove(source: UUID) {
        let all = entries()
        let remaining = all.filter { $0.source != source }
        if remaining.count != all.count { persist(remaining) }
    }

    private func entries() -> [Entry] {
        if let cached { return cached }
        let values: [Entry]
        if let file = try? FileHandle(forReadingFrom: url) {
            defer { try? file.close() }
            let data = try? file.read(upToCount: 2_000_000)
            values = data.flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        } else {
            values = []
        }
        let recent = Array(values.prefix(Self.limit))
        cached = recent
        return recent
    }

    private func persist(_ entries: [Entry]) {
        cached = entries
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: url, options: .atomic)
        } catch {
            // The window can still show its in-memory history when Application Support is unavailable.
        }
    }

    nonisolated static func preview(_ statement: String, engine: DatabaseEngine) -> String {
        guard let dialect = SQLDialect(engine: engine) else { return "MongoDB filter" }
        guard !statement.isEmpty else { return "SQL statement · preview unavailable" }
        if engine == .mysql, statement.contains("\\") { return "SQL statement · preview unavailable" }
        let input = statement
        let text = input as NSString
        let tokens = SQLLexer(input, dialect: dialect).tokenize().filter { $0.kind != .comment && $0.kind != .directive }
        let allowed = ["SELECT", "WITH", "INSERT", "UPDATE", "DELETE", "EXPLAIN", "SHOW", "CREATE", "ALTER", "DROP",
                       "PRAGMA", "VALUES", "BEGIN", "COMMIT", "ROLLBACK", "SET", "RESET", "USE"]
        guard let first = tokens.first, first.kind == .word else { return "SQL statement · preview unavailable" }
        let keyword = text.substring(with: first.range).uppercased()
        guard allowed.contains(keyword) else { return "SQL statement · preview unavailable" }
        if tokens.contains(where: {
            $0.kind == .word && ["PASSWORD", "IDENTIFIED", "SECRET", "TOKEN"].contains(text.substring(with: $0.range).uppercased())
        }) {
            return keyword + " · sensitive statement"
        }
        let preview = tokens.prefix(200).map { token in
            switch token.kind {
            case .string, .number, .parameter, .quotedIdentifier: "?"
            default: text.substring(with: token.range)
            }
        }.joined(separator: " ")
        let redacted = SecretRedactor.redact(preview)
        return redacted.utf8.count > 1_024 || tokens.count > 200
            ? String(decoding: redacted.utf8.prefix(1_024), as: UTF8.self) + "…" : redacted
    }
}
