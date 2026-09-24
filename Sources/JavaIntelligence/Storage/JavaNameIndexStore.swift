import Foundation

/// One indexed source file: its path relative to the source root, the stamp it was tokenized at,
/// and the identifiers it contains.
public struct JavaNameIndexEntry: Sendable, Equatable {
    public let relativePath: String
    public let stamp: JavaStamp
    public let identifiers: Set<String>

    public init(relativePath: String, stamp: JavaStamp, identifiers: Set<String>) {
        self.relativePath = relativePath
        self.stamp = stamp
        self.identifiers = identifiers
    }
}

/// Persists the identifier index of one source root (`refs.idx`): which files mention which
/// identifiers. Same style as ``JavaIndexShardWriter`` -- a shared string table, little-endian
/// integers, an atomic write -- with its own magic and format version.
///
/// Format (little-endian):
/// ```
/// magic: "PJRX" (4 bytes)
/// formatVersion: UInt32
/// fileCount: UInt32
/// stringTable: UInt32 byteLength, then the table (see StringTableBuilder)
/// files: [UInt32 pathStringID, Int64 size, Float64 modificationDate] * fileCount
/// identifierCount: UInt32
/// index: [UInt32 identifierStringID, UInt32 byteOffset, UInt32 fileCount] * identifierCount
/// postings: [UInt32 fileID] runs, referenced by the index table
/// ```
public struct JavaNameIndexShardWriter {
    public static let formatVersion: UInt32 = 1
    static let magic: [UInt8] = Array("PJRX".utf8)

    public init() {}

    public func write(_ entries: [JavaNameIndexEntry], to url: URL) throws {
        var stringTable = StringTableBuilder()
        var postings: [UInt32: [UInt32]] = [:]
        var pathIDs: [UInt32] = []
        pathIDs.reserveCapacity(entries.count)
        for (fileID, entry) in entries.enumerated() {
            pathIDs.append(stringTable.id(for: entry.relativePath))
            for identifier in entry.identifiers {
                postings[stringTable.id(for: identifier), default: []].append(UInt32(fileID))
            }
        }

        var out = Data()
        out.append(contentsOf: Self.magic)
        out.appendUInt32LE(Self.formatVersion)
        out.appendUInt32LE(UInt32(entries.count))
        let strings = stringTable.encoded()
        out.appendUInt32LE(UInt32(strings.count))
        out.append(strings)
        for (i, entry) in entries.enumerated() {
            out.appendUInt32LE(pathIDs[i])
            out.appendInt64LE(entry.stamp.size)
            out.appendFloat64LE(entry.stamp.modificationDate)
        }

        out.appendUInt32LE(UInt32(postings.count))
        var body = Data()
        for identifierID in postings.keys.sorted() {
            let fileIDs = postings[identifierID]!
            out.appendUInt32LE(identifierID)
            out.appendUInt32LE(UInt32(body.count))
            out.appendUInt32LE(UInt32(fileIDs.count))
            for fileID in fileIDs { body.appendUInt32LE(fileID) }
        }
        out.append(body)

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: url, options: .atomic)
    }
}

/// Reads a shard written by ``JavaNameIndexShardWriter``. The file table and the identifier
/// offset table are parsed at `init` (the file is memory-mapped); a posting list is only decoded
/// when its identifier is asked for.
public final class JavaNameIndexShardReader: @unchecked Sendable {
    /// Relative path and stamp of every indexed file, indexed by file id.
    public let files: [(relativePath: String, stamp: JavaStamp)]

    private let data: Data
    private let postingsBase: Int
    private let stringTable: [String]
    /// identifier -> (byteOffset, fileCount) within the postings section.
    private let postingTable: [String: (Int, Int)]

    public init(url: URL) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        self.data = data
        guard data.count >= 4, Array(data.prefix(4)) == JavaNameIndexShardWriter.magic else {
            throw JavaIndexStoreError.badMagic
        }
        var cursor = 4
        guard cursor + 8 <= data.count else { throw JavaIndexStoreError.corrupt("header") }
        let version = data.readUInt32LE(at: cursor); cursor += 4
        guard version == JavaNameIndexShardWriter.formatVersion else {
            throw JavaIndexStoreError.unsupportedFormatVersion(found: Int(version), expected: Int(JavaNameIndexShardWriter.formatVersion))
        }
        let fileCount = Int(data.readUInt32LE(at: cursor)); cursor += 4

        guard cursor + 4 <= data.count else { throw JavaIndexStoreError.corrupt("string table") }
        let stringsLength = Int(data.readUInt32LE(at: cursor)); cursor += 4
        guard cursor + stringsLength <= data.count else { throw JavaIndexStoreError.corrupt("string table") }
        let strings = StringTableBuilder.decode(data.subdata(in: cursor..<(cursor + stringsLength)))
        cursor += stringsLength
        self.stringTable = strings

        var files: [(String, JavaStamp)] = []
        files.reserveCapacity(fileCount)
        for _ in 0..<fileCount {
            guard cursor + 20 <= data.count else { throw JavaIndexStoreError.corrupt("file table") }
            let pathID = Int(data.readUInt32LE(at: cursor))
            let size = Int64(bitPattern: data.readUInt64LE(at: cursor + 4))
            let date = Double(bitPattern: data.readUInt64LE(at: cursor + 12))
            cursor += 20
            guard pathID < strings.count else { throw JavaIndexStoreError.corrupt("path id") }
            files.append((strings[pathID], JavaStamp(size: size, modificationDate: date)))
        }
        self.files = files

        guard cursor + 4 <= data.count else { throw JavaIndexStoreError.corrupt("index table") }
        let identifierCount = Int(data.readUInt32LE(at: cursor)); cursor += 4
        var table: [String: (Int, Int)] = [:]
        table.reserveCapacity(identifierCount)
        for _ in 0..<identifierCount {
            guard cursor + 12 <= data.count else { throw JavaIndexStoreError.corrupt("index table") }
            let id = Int(data.readUInt32LE(at: cursor))
            let offset = Int(data.readUInt32LE(at: cursor + 4))
            let count = Int(data.readUInt32LE(at: cursor + 8))
            cursor += 12
            guard id < strings.count else { throw JavaIndexStoreError.corrupt("identifier id") }
            table[strings[id]] = (offset, count)
        }
        self.postingTable = table
        self.postingsBase = cursor
    }

    /// Ids (indexes into ``files``) of the files that contain `identifier`.
    public func fileIDs(containing identifier: String) -> [Int] {
        guard let (offset, count) = postingTable[identifier] else { return [] }
        let start = postingsBase + offset
        guard start + count * 4 <= data.count else { return [] }
        var ids: [Int] = []
        ids.reserveCapacity(count)
        for i in 0..<count {
            let id = Int(data.readUInt32LE(at: start + i * 4))
            if id < files.count { ids.append(id) }
        }
        return ids
    }

    public func relativePaths(containing identifier: String) -> [String] {
        fileIDs(containing: identifier).map { files[$0].relativePath }
    }

    public var identifierCount: Int { postingTable.count }

    /// Inverts the postings back into per-file entries -- used by an incremental update to carry
    /// unchanged files over without re-tokenizing them.
    public func allEntries() -> [JavaNameIndexEntry] {
        var sets = [Set<String>](repeating: [], count: files.count)
        for identifier in postingTable.keys {
            for id in fileIDs(containing: identifier) { sets[id].insert(identifier) }
        }
        return files.enumerated().map { JavaNameIndexEntry(relativePath: $1.relativePath, stamp: $1.stamp, identifiers: sets[$0]) }
    }
}
