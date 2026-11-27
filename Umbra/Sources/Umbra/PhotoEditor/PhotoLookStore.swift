import Foundation

/// Saved looks ("presets") for the photo editor, replacing the reference's SwiftData
/// `SavedPhotoPreset` + `PhotoPresetRepository` (Umbra has no SwiftData stack). One JSON file of
/// look recipes; the in-memory list is owned by the Filters pane and reloaded after mutations.
struct PhotoLookStore: Sendable {
    struct Record: Codable, Sendable, Identifiable {
        var id: UUID = UUID()
        var name: String = "New Look"
        var sortIndex: Int = 0
        var dateCreated: Date = Date.now
        /// JSON encoding of `EditAdjustment.lookRecipe`.
        var recipeJSON: String = "{}"
    }

    static var fileURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("com.umbra.editor", isDirectory: true)
            .appendingPathComponent("PhotoEditor", isDirectory: true)
            .appendingPathComponent("looks.json")
    }

    /// All saved looks, oldest first.
    static func load(fileURL: URL = fileURL) -> [Record] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let records = (try? JSONDecoder().decode([Record].self, from: data)) ?? []
        return records.sorted { $0.sortIndex < $1.sortIndex }
    }

    @discardableResult
    static func add(name: String, adjustments: EditAdjustment, fileURL: URL = fileURL) -> [Record] {
        var records = load(fileURL: fileURL)
        var record = Record()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        record.name = trimmed.isEmpty ? "New Look" : trimmed
        record.recipeJSON = encode(adjustments.lookRecipe)
        record.sortIndex = (records.map(\.sortIndex).max() ?? -1) + 1
        records.append(record)
        persist(records, fileURL: fileURL)
        return records
    }

    @discardableResult
    static func remove(id: UUID, fileURL: URL = fileURL) -> [Record] {
        let records = load(fileURL: fileURL).filter { $0.id != id }
        persist(records, fileURL: fileURL)
        return records
    }

    @discardableResult
    static func rename(id: UUID, to name: String, fileURL: URL = fileURL) -> [Record] {
        var records = load(fileURL: fileURL)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = records.firstIndex(where: { $0.id == id }), !trimmed.isEmpty {
            records[index].name = trimmed
            persist(records, fileURL: fileURL)
        }
        return records
    }

    static func adjustments(for record: Record) -> EditAdjustment? {
        guard let data = record.recipeJSON.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(EditAdjustment.self, from: data)
    }

    private static func encode(_ adjustments: EditAdjustment) -> String {
        guard let data = try? JSONEncoder().encode(adjustments),
              let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    private static func persist(_ records: [Record], fileURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Best-effort; a failed write must never interrupt editing.
        }
    }
}
