import Foundation
#if canImport(Compression)
import Compression
#endif

/// Errors from reading a ZIP-format archive (JAR, ct.sym, src.zip, jmod).
public enum ZipArchiveError: Error, Sendable {
    case notAZipFile
    case endOfCentralDirectoryNotFound
    case corruptCentralDirectory
    case unsupportedCompressionMethod(UInt16)
    case inflateFailed
    case entryNotFound(String)
}

/// One entry in a ZIP central directory.
public struct ZipEntry: Sendable {
    public let name: String
    public let compressionMethod: UInt16
    public let compressedSize: Int
    public let uncompressedSize: Int
    public let localHeaderOffset: Int
    public let crc32: UInt32
}

/// A minimal read-only ZIP archive reader used for JARs, `ct.sym`, `src.zip`, and `.jmod` files.
///
/// It memory-maps the file, parses the End Of Central Directory record (including the ZIP64
/// variant) and the central directory, and decompresses individual entries on demand — it never
/// decompresses the whole archive up front. Only "stored" (0) and "deflate" (8) compression
/// methods are supported, which covers everything the JDK and Gradle/Maven caches produce.
public final class ZipArchive: @unchecked Sendable {
    private let data: Data
    /// Entries indexed by name for O(1) lookup, built once at open time.
    public let entriesByName: [String: ZipEntry]
    public let entries: [ZipEntry]

    public convenience init(url: URL) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        try self.init(data: data)
    }

    public init(data: Data) throws {
        self.data = data
        let centralDirectory = try Self.locateCentralDirectory(in: data)
        var byName: [String: ZipEntry] = [:]
        var list: [ZipEntry] = []
        list.reserveCapacity(centralDirectory.count)
        for entry in centralDirectory {
            byName[entry.name] = entry
            list.append(entry)
        }
        self.entriesByName = byName
        self.entries = list
    }

    public func contains(_ name: String) -> Bool {
        entriesByName[name] != nil
    }

    /// Reads and decompresses one entry's full content.
    public func data(for name: String) throws -> Data {
        guard let entry = entriesByName[name] else {
            throw ZipArchiveError.entryNotFound(name)
        }
        return try data(for: entry)
    }

    public func data(for entry: ZipEntry) throws -> Data {
        let localHeader = try readLocalHeader(at: entry.localHeaderOffset)
        let start = localHeader.dataOffset
        let end = start + entry.compressedSize
        guard end <= data.count, start >= 0 else {
            throw ZipArchiveError.corruptCentralDirectory
        }
        let compressed = data.subdata(in: start..<end)
        switch entry.compressionMethod {
        case 0:
            return compressed
        case 8:
            return try Self.inflateRaw(compressed, expectedSize: entry.uncompressedSize)
        default:
            throw ZipArchiveError.unsupportedCompressionMethod(entry.compressionMethod)
        }
    }

    // MARK: - Local header

    private struct LocalHeader {
        let dataOffset: Int
    }

    /// Local file headers repeat name/extra field lengths that can differ subtly from the central
    /// directory's copies (e.g. Info-ZIP UTF-8 extras), so the data offset must be computed from
    /// the local header itself rather than assumed from the central directory sizes.
    private func readLocalHeader(at offset: Int) throws -> LocalHeader {
        guard offset + 30 <= data.count else { throw ZipArchiveError.corruptCentralDirectory }
        let signature = data.readUInt32LE(at: offset)
        guard signature == 0x0403_4b50 else { throw ZipArchiveError.corruptCentralDirectory }
        let nameLength = Int(data.readUInt16LE(at: offset + 26))
        let extraLength = Int(data.readUInt16LE(at: offset + 28))
        return LocalHeader(dataOffset: offset + 30 + nameLength + extraLength)
    }

    // MARK: - Central directory parsing

    private static func locateCentralDirectory(in data: Data) throws -> [ZipEntry] {
        guard data.count >= 22 else { throw ZipArchiveError.notAZipFile }
        guard let eocdOffset = findEndOfCentralDirectory(in: data) else {
            throw ZipArchiveError.endOfCentralDirectoryNotFound
        }

        var entryCount = Int(data.readUInt16LE(at: eocdOffset + 10))
        var cdOffset = Int(data.readUInt32LE(at: eocdOffset + 16))
        var cdSize = Int(data.readUInt32LE(at: eocdOffset + 12))

        // ZIP64: the classic EOCD fields are 0xFFFF/0xFFFFFFFF sentinels when a locator precedes it.
        if entryCount == 0xFFFF || cdOffset == 0xFFFF_FFFF || cdSize == 0xFFFF_FFFF {
            let locatorOffset = eocdOffset - 20
            if locatorOffset >= 0,
               data.readUInt32LE(at: locatorOffset) == 0x0706_4b50 {
                let zip64EocdOffset = Int(data.readUInt64LE(at: locatorOffset + 8))
                if zip64EocdOffset + 56 <= data.count,
                   data.readUInt32LE(at: zip64EocdOffset) == 0x0606_4b50 {
                    entryCount = Int(data.readUInt64LE(at: zip64EocdOffset + 32))
                    cdSize = Int(data.readUInt64LE(at: zip64EocdOffset + 40))
                    cdOffset = Int(data.readUInt64LE(at: zip64EocdOffset + 48))
                }
            }
        }

        guard cdOffset >= 0, cdOffset + cdSize <= data.count else {
            throw ZipArchiveError.corruptCentralDirectory
        }

        var entries: [ZipEntry] = []
        entries.reserveCapacity(entryCount)
        var cursor = cdOffset
        let cdEnd = cdOffset + cdSize
        while cursor + 46 <= cdEnd {
            guard data.readUInt32LE(at: cursor) == 0x0201_4b50 else { break }
            let compressionMethod = data.readUInt16LE(at: cursor + 10)
            var compressedSize = Int(data.readUInt32LE(at: cursor + 20))
            var uncompressedSize = Int(data.readUInt32LE(at: cursor + 24))
            let nameLength = Int(data.readUInt16LE(at: cursor + 28))
            let extraLength = Int(data.readUInt16LE(at: cursor + 30))
            let commentLength = Int(data.readUInt16LE(at: cursor + 32))
            var localHeaderOffset = Int(data.readUInt32LE(at: cursor + 42))
            let crc32 = data.readUInt32LE(at: cursor + 16)

            let nameStart = cursor + 46
            guard nameStart + nameLength <= data.count else { break }
            let nameData = data.subdata(in: nameStart..<(nameStart + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? String(decoding: nameData, as: UTF8.self)

            // ZIP64 extra field overrides sentinel-valued sizes/offset (order: uncompressed,
            // compressed, local header offset — only fields that were sentinels are present).
            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF || localHeaderOffset == 0xFFFF_FFFF {
                let extraStart = nameStart + nameLength
                if let zip64 = parseZip64Extra(
                    data: data, extraStart: extraStart, extraLength: extraLength,
                    needsUncompressed: uncompressedSize == 0xFFFF_FFFF,
                    needsCompressed: compressedSize == 0xFFFF_FFFF,
                    needsOffset: localHeaderOffset == 0xFFFF_FFFF
                ) {
                    if let v = zip64.uncompressedSize { uncompressedSize = v }
                    if let v = zip64.compressedSize { compressedSize = v }
                    if let v = zip64.localHeaderOffset { localHeaderOffset = v }
                }
            }

            entries.append(ZipEntry(
                name: name,
                compressionMethod: compressionMethod,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localHeaderOffset,
                crc32: crc32
            ))
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    private struct Zip64Extra {
        var uncompressedSize: Int?
        var compressedSize: Int?
        var localHeaderOffset: Int?
    }

    private static func parseZip64Extra(
        data: Data, extraStart: Int, extraLength: Int,
        needsUncompressed: Bool, needsCompressed: Bool, needsOffset: Bool
    ) -> Zip64Extra? {
        var cursor = extraStart
        let end = extraStart + extraLength
        while cursor + 4 <= end, cursor + 4 <= data.count {
            let headerID = data.readUInt16LE(at: cursor)
            let size = Int(data.readUInt16LE(at: cursor + 2))
            let fieldStart = cursor + 4
            guard fieldStart + size <= data.count, fieldStart + size <= end else { return nil }
            if headerID == 0x0001 {
                var result = Zip64Extra()
                var offset = fieldStart
                if needsUncompressed, offset + 8 <= fieldStart + size {
                    result.uncompressedSize = Int(data.readUInt64LE(at: offset))
                    offset += 8
                }
                if needsCompressed, offset + 8 <= fieldStart + size {
                    result.compressedSize = Int(data.readUInt64LE(at: offset))
                    offset += 8
                }
                if needsOffset, offset + 8 <= fieldStart + size {
                    result.localHeaderOffset = Int(data.readUInt64LE(at: offset))
                    offset += 8
                }
                return result
            }
            cursor = fieldStart + size
        }
        return nil
    }

    /// Scans backward from the end of the file for the EOCD signature. The comment field can be up
    /// to 65535 bytes, so this is bounded but not a fixed-offset read.
    private static func findEndOfCentralDirectory(in data: Data) -> Int? {
        let minSize = 22
        let maxCommentSize = 65_535
        let searchStart = max(0, data.count - minSize - maxCommentSize)
        var offset = data.count - minSize
        while offset >= searchStart {
            if data.readUInt32LE(at: offset) == 0x0605_4b50 {
                return offset
            }
            offset -= 1
        }
        return nil
    }

    // MARK: - Inflate

    private static func inflateRaw(_ compressed: Data, expectedSize: Int) throws -> Data {
        #if canImport(Compression)
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)
        let writtenCount: Int = output.withUnsafeMutableBytes { outBuffer in
            compressed.withUnsafeBytes { inBuffer -> Int in
                guard let outBase = outBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let inBase = inBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return compression_decode_buffer(
                    outBase, expectedSize,
                    inBase, compressed.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard writtenCount == expectedSize else {
            throw ZipArchiveError.inflateFailed
        }
        return output
        #else
        throw ZipArchiveError.inflateFailed
        #endif
    }
}

extension Data {
    func readUInt16LE(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        let a = self[startIndex + offset]
        let b = self[startIndex + offset + 1]
        return UInt16(a) | (UInt16(b) << 8)
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(self[startIndex + offset + i]) << (8 * i)
        }
        return value
    }

    func readUInt64LE(at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(self[startIndex + offset + i]) << (8 * i)
        }
        return value
    }
}
