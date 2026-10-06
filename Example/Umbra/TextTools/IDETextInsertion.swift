import Foundation

/// Text that needs no selection: a command-palette entry that puts a fresh value at every caret
/// (and over every selection).
struct IDETextInsertion: Sendable {
    let id: String
    let title: String
    let make: @Sendable () -> String
}

enum IDETextInsertions {
    static let all: [IDETextInsertion] = [
        .init(id: "insert.uuid", title: "Insert UUID") { UUID().uuidString.lowercased() },
        .init(id: "insert.timestamp", title: "Insert Timestamp (ISO 8601)") { ISO8601DateFormatter().string(from: Date()) },
        .init(id: "insert.unixTime", title: "Insert Unix Timestamp") { String(Int64(Date().timeIntervalSince1970)) }
    ]
}
