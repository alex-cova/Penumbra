import DatabaseKit
import Foundation
import Observation

/// The data sources saved on this Mac. Passwords are not in the file.
@MainActor
@Observable
final class IDEDatabaseCatalog {
    private(set) var connections: [DatabaseConnection] = []
    let storeURL: URL

    init(storeURL: URL) {
        self.storeURL = storeURL
        connections = Self.read(from: storeURL)
    }

    static var defaultStoreURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("database-connections.json")
    }

    func connection(id: UUID) -> DatabaseConnection? {
        connections.first { $0.id == id }
    }

    func upsert(_ connection: DatabaseConnection) {
        var stored = connection
        if let index = connections.firstIndex(where: { $0.id == connection.id }) {
            stored.sortIndex = connections[index].sortIndex
            stored.lastStatement = connection.lastStatement.isEmpty
                ? connections[index].lastStatement
                : connection.lastStatement
            connections[index] = stored
        } else {
            stored.sortIndex = (connections.map(\.sortIndex).max() ?? -1) + 1
            connections.append(stored)
        }
        connections.sort { $0.sortIndex < $1.sortIndex }
        persist()
    }

    func updateLastStatement(id: UUID, _ statement: String) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].lastStatement = statement
        persist()
    }

    func remove(id: UUID) {
        connections.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(File(connections: connections)) else { return }
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: storeURL, options: .atomic)
    }

    private static func read(from url: URL) -> [DatabaseConnection] {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.connections.sorted { $0.sortIndex < $1.sortIndex }
    }

    private struct File: Codable {
        var connections: [DatabaseConnection]
    }
}
