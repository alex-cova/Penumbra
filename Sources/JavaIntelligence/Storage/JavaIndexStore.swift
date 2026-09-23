import Foundation

/// A stamp used to detect whether an indexed source (a root, a JAR, a source file) has changed
/// since it was last indexed. Mirrors what `FileIndexingStamp` does in the handoff doc.
public struct JavaStamp: Hashable, Sendable, Codable {
    public let size: Int64
    public let modificationDate: TimeInterval

    public init(size: Int64, modificationDate: TimeInterval) {
        self.size = size
        self.modificationDate = modificationDate
    }

    public init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let date = values.contentModificationDate else {
            return nil
        }
        self.size = Int64(size)
        self.modificationDate = date.timeIntervalSince1970
    }
}

public enum JavaIndexStoreError: Error, Sendable {
    case badMagic
    case unsupportedFormatVersion(found: Int, expected: Int)
    case corrupt(String)
}

/// Persists a flat set of ``JavaClassStub`` values to a compact binary shard on disk, and reads
/// them back lazily: the header carries a name -> byte-offset table, so `classStub(named:)` only
/// decodes the one entry it needs instead of the whole shard. This is the on-disk equivalent of
/// `FileBasedIndexImpl`'s storage layer, scoped down to one shard per root/JAR/project.
///
/// Format (little-endian):
/// ```
/// magic: "PJIX" (4 bytes)
/// formatVersion: UInt32
/// stamp: Int64 size, Float64 modificationDate
/// entryCount: UInt32
/// stringTable: UInt32 count, then [UInt32 length + UTF8 bytes] * count
/// index: [UInt32 nameStringID, UInt32 byteOffset, UInt32 byteLength] * entryCount
/// entries: encoded JavaClassStub bodies, referenced by the index table
/// ```
public struct JavaIndexShardWriter {
    /// 2: source stubs of interfaces now record their `extends` list (v1 dropped it), so shards
    /// written by v1 must be rebuilt rather than read.
    public static let formatVersion: UInt32 = 2
    private static let magic: [UInt8] = Array("PJIX".utf8)

    public init() {}

    public func write(_ stubs: [JavaClassStub], stamp: JavaStamp, to url: URL) throws {
        var stringTable = StringTableBuilder()
        var entryBodies: [Data] = []
        entryBodies.reserveCapacity(stubs.count)
        var nameIDs: [UInt32] = []
        for stub in stubs {
            let body = StubCoder.encode(stub, stringTable: &stringTable)
            entryBodies.append(body)
            nameIDs.append(stringTable.id(for: stub.qualifiedName))
        }

        var out = Data()
        out.append(contentsOf: Self.magic)
        out.appendUInt32LE(Self.formatVersion)
        out.appendInt64LE(stamp.size)
        out.appendFloat64LE(stamp.modificationDate)
        out.appendUInt32LE(UInt32(stubs.count))

        let stringsData = stringTable.encoded()
        out.appendUInt32LE(UInt32(stringsData.count))
        out.append(stringsData)

        // Compute offsets relative to the start of the `entries` section.
        var offset: UInt32 = 0
        var offsets: [UInt32] = []
        for body in entryBodies {
            offsets.append(offset)
            offset += UInt32(body.count)
        }
        for (i, body) in entryBodies.enumerated() {
            out.appendUInt32LE(nameIDs[i])
            out.appendUInt32LE(offsets[i])
            out.appendUInt32LE(UInt32(body.count))
        }
        for body in entryBodies {
            out.append(body)
        }

        try out.write(to: url, options: .atomic)
    }
}

/// Reads a shard written by ``JavaIndexShardWriter``. The header (name table + offset index) is
/// parsed eagerly at `init`; individual class bodies are decoded lazily on `classStub(named:)`.
public final class JavaIndexShardReader: @unchecked Sendable {
    public let stamp: JavaStamp
    public let allQualifiedNames: [String]

    private let data: Data
    private let entriesBase: Int
    /// qualifiedName -> (byteOffset, byteLength) within `entries`.
    private let offsetTable: [String: (Int, Int)]
    private let stringTable: [String]

    public init(url: URL) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        self.data = data
        var cursor = 0
        guard data.count >= 4, Array(data.prefix(4)) == Array("PJIX".utf8) else {
            throw JavaIndexStoreError.badMagic
        }
        cursor = 4
        let version = data.readUInt32LE(at: cursor); cursor += 4
        guard version == JavaIndexShardWriter.formatVersion else {
            throw JavaIndexStoreError.unsupportedFormatVersion(found: Int(version), expected: Int(JavaIndexShardWriter.formatVersion))
        }
        let size = Int64(bitPattern: data.readUInt64LE(at: cursor)); cursor += 8
        let modBits = data.readUInt64LE(at: cursor); cursor += 8
        let modDate = Double(bitPattern: modBits)
        self.stamp = JavaStamp(size: size, modificationDate: modDate)

        let entryCount = Int(data.readUInt32LE(at: cursor)); cursor += 4

        let stringsLength = Int(data.readUInt32LE(at: cursor)); cursor += 4
        guard cursor + stringsLength <= data.count else { throw JavaIndexStoreError.corrupt("string table") }
        let stringsData = data.subdata(in: cursor..<(cursor + stringsLength))
        cursor += stringsLength
        self.stringTable = StringTableBuilder.decode(stringsData)

        var table: [String: (Int, Int)] = [:]
        table.reserveCapacity(entryCount)
        var names: [String] = []
        names.reserveCapacity(entryCount)
        for _ in 0..<entryCount {
            guard cursor + 12 <= data.count else { throw JavaIndexStoreError.corrupt("index table") }
            let nameID = Int(data.readUInt32LE(at: cursor))
            let byteOffset = Int(data.readUInt32LE(at: cursor + 4))
            let byteLength = Int(data.readUInt32LE(at: cursor + 8))
            cursor += 12
            guard nameID < self.stringTable.count else { throw JavaIndexStoreError.corrupt("name id") }
            let name = self.stringTable[nameID]
            table[name] = (byteOffset, byteLength)
            names.append(name)
        }
        self.offsetTable = table
        self.allQualifiedNames = names
        self.entriesBase = cursor
    }

    public func contains(_ qualifiedName: String) -> Bool {
        offsetTable[qualifiedName] != nil
    }

    public func classStub(named qualifiedName: String) -> JavaClassStub? {
        guard let (offset, length) = offsetTable[qualifiedName] else { return nil }
        let start = entriesBase + offset
        let end = start + length
        guard end <= data.count else { return nil }
        let body = data.subdata(in: start..<end)
        return StubCoder.decode(body, stringTable: stringTable)
    }
}

extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func appendUInt64LE(_ value: UInt64) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func appendInt64LE(_ value: Int64) {
        appendUInt64LE(UInt64(bitPattern: value))
    }
    mutating func appendFloat64LE(_ value: Double) {
        appendUInt64LE(value.bitPattern)
    }
}
