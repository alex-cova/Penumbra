import Foundation

/// Drafts the user put aside (⌃S in the message field) to write something else first, per project:
/// `stash.json` beside the project's conversations, with the images of each draft in
/// `stash-images/<id>/`. Readable by the user alone, like the prompt history. Newest first; at most
/// `limit`, the oldest dropped with its images.
@MainActor @Observable
final class IDEAgentPromptStash {
    static let limit = 20

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        var text: String
        var createdAt: Date
        var images: [StashedImage] = []

        /// The first line, for the list.
        var title: String {
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            if line.isEmpty { return images.count == 1 ? "1 image" : "\(images.count) images" }
            return line.count <= 80 ? line : String(line.prefix(79)) + "…"
        }
    }

    struct StashedImage: Codable, Equatable {
        var mediaType: String
        var width: Double
        var height: Double
        /// The file name inside the entry's image folder. In-memory stashes keep the bytes instead.
        var file: String?
        var data: Data?
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private let limit: Int

    /// With no file the stash lives only as long as this object (tests, a window with no saved state).
    init(file: URL?, limit: Int = IDEAgentPromptStash.limit) {
        self.file = file
        self.limit = limit
        load()
    }

    /// Puts a draft aside. Blank text with no images is ignored.
    @discardableResult
    func add(text: String, images: [IDEAttachedImage], now: Date = Date()) -> Entry? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return nil }
        var entry = Entry(text: text, createdAt: now)
        entry.images = images.enumerated().map { index, image in
            var stashed = StashedImage(
                mediaType: image.mediaType, width: image.pixelSize.width, height: image.pixelSize.height)
            if let folder = imageFolder(for: entry.id) {
                let name = "\(index).\(Self.fileExtension(image.mediaType))"
                if Self.writePrivately(image.data, to: folder.appendingPathComponent(name)) { stashed.file = name }
            } else {
                stashed.data = image.data
            }
            return stashed
        }
        entries.insert(entry, at: 0)
        while entries.count > limit { removeFiles(of: entries.removeLast()) }
        save()
        return entry
    }

    /// Takes a draft out of the stash: its text and the images that could still be read.
    func take(_ id: UUID) -> (text: String, images: [IDEAttachedImage])? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let entry = entries.remove(at: index)
        let images = entry.images.compactMap { stashed -> IDEAttachedImage? in
            let data = stashed.data ?? stashed.file.flatMap { name in
                imageFolder(for: entry.id).flatMap { try? Data(contentsOf: $0.appendingPathComponent(name)) }
            }
            guard let data else { return nil }
            return IDEAttachedImage(
                mediaType: stashed.mediaType, data: data, pixelSize: CGSize(width: stashed.width, height: stashed.height))
        }
        removeFiles(of: entry)
        save()
        return (entry.text, images)
    }

    func remove(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        removeFiles(of: entries.remove(at: index))
        save()
    }

    // MARK: - Disk

    private var imagesRoot: URL? { file?.deletingLastPathComponent().appendingPathComponent("stash-images", isDirectory: true) }

    private func imageFolder(for id: UUID) -> URL? {
        imagesRoot?.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func removeFiles(of entry: Entry) {
        if let folder = imageFolder(for: entry.id) { try? FileManager.default.removeItem(at: folder) }
    }

    private func load() {
        guard let file, let data = try? Data(contentsOf: file),
              let decoded = try? JSONDecoder().decode([Entry].self, from: data)
        else { return }
        entries = Array(decoded.prefix(limit))
    }

    private func save() {
        guard let file else { return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        _ = Self.writePrivately(data, to: file)
    }

    /// Writes a file the user alone can read, in a folder only they can open.
    @discardableResult
    private static func writePrivately(_ data: Data, to url: URL) -> Bool {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }

    private static func fileExtension(_ mediaType: String) -> String {
        switch mediaType {
        case "image/png": "png"
        case "image/jpeg": "jpg"
        case "image/gif": "gif"
        case "image/webp": "webp"
        default: "img"
        }
    }
}
