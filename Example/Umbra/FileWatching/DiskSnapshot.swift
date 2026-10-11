import CryptoKit
import Foundation

/// What a file on disk holds, enough to tell "changed" from "touched". A watcher event only says a
/// path was written; two snapshots with the same hash mean the bytes did not change (a `touch`, an
/// xattr write, a formatter that rewrote the same text, Umbra's own save).
struct DiskSnapshot: Equatable, Sendable {
    var size: UInt64
    var modificationDate: Date
    /// SHA-256 of the bytes, or of the first and last ``sampleLength`` bytes plus the size for a
    /// file over ``fullHashLimit``.
    var contentHash: Data

    static let fullHashLimit: UInt64 = 2 * 1024 * 1024
    static let sampleLength = 64 * 1024

    /// Same bytes. A sampled hash cannot see an edit in the middle that keeps the size, so above
    /// ``fullHashLimit`` the modification date must match too (a `touch` there counts as a change).
    func sameContent(as other: DiskSnapshot) -> Bool {
        guard size == other.size, contentHash == other.contentHash else { return false }
        return size <= Self.fullHashLimit || modificationDate == other.modificationDate
    }

    /// Reads `url` off the main actor. Nil when there is no regular file there (deleted, or a folder).
    static func capture(url: URL) async -> DiskSnapshot? {
        await Task.detached(priority: .utility) { captureNow(url: url) }.value
    }

    static func captureNow(url: URL) -> DiskSnapshot? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        var hasher = SHA256()
        if size > fullHashLimit {
            guard let head = try? handle.read(upToCount: sampleLength) else { return nil }
            hasher.update(data: head)
            guard (try? handle.seek(toOffset: size - UInt64(sampleLength))) != nil,
                  let tail = try? handle.read(upToCount: sampleLength) else { return nil }
            hasher.update(data: tail)
            withUnsafeBytes(of: size.bigEndian) { hasher.update(bufferPointer: $0) }
        } else {
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        }
        return DiskSnapshot(size: size, modificationDate: modified, contentHash: Data(hasher.finalize()))
    }
}
