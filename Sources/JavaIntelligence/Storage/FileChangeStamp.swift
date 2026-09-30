import Foundation

/// A file's modification date as last seen, so a store that keeps its file in memory can tell when
/// another writer changed it (another window's store, another process) and read it again before
/// reading or merging its own change. Without that, each store rewrites the whole file from what it
/// loaded at launch and silently drops what the others wrote.
public struct FileChangeStamp: Sendable, Equatable {
    private var date: Date?

    /// Takes the stamp of the file as it is now (nil when there is none).
    public init(url: URL) {
        date = Self.modificationDate(of: url)
    }

    /// True when the file was written, created or deleted since the stamp was taken or updated.
    public func hasChanged(at url: URL) -> Bool {
        Self.modificationDate(of: url) != date
    }

    /// Call after reading the file, or after this store wrote it itself.
    public mutating func update(at url: URL) {
        date = Self.modificationDate(of: url)
    }

    /// Read through `FileManager`: `URL.resourceValues` caches what it returned on the `URL` value,
    /// and a store asks about the same `URL` over and over, so it would keep seeing the first date.
    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
