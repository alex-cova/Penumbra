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

    /// Rewrites a readable shard without turning postings back into strings. `removing` is the set
    /// of old file ids to drop (deleted or edited). `replacing` is those edited files plus new
    /// ones, already tokenized. Surviving files keep dense new ids; their posting runs are copied
    /// and translated. When orphaned strings pass a quarter of the string table, falls back to
    /// ``write(_:to:)``.
    @discardableResult
    public func rewrite(
        from reader: JavaNameIndexShardReader, removing: Set<Int>, replacing: [JavaNameIndexEntry], to url: URL
    ) throws -> JavaNameIndexShardReader {
        var strings = reader.stringTable
        let oldStringCount = strings.count
        var idByString: [String: UInt32] = [:]
        idByString.reserveCapacity(strings.count + replacing.count)
        for (index, string) in strings.enumerated() { idByString[string] = UInt32(index) }
        func intern(_ string: String) -> UInt32 {
            if let existing = idByString[string] { return existing }
            let id = UInt32(strings.count)
            strings.append(string)
            idByString[string] = id
            return id
        }

        var translate = [Int32](repeating: -1, count: reader.files.count)
        var newFiles: [(pathID: UInt32, stamp: JavaStamp)] = []
        newFiles.reserveCapacity(reader.files.count + replacing.count)
        for (old, file) in reader.files.enumerated() where !removing.contains(old) {
            translate[old] = Int32(newFiles.count)
            newFiles.append((intern(file.relativePath), file.stamp))
        }
        var replacingIDs: [UInt32] = []
        replacingIDs.reserveCapacity(replacing.count)
        for entry in replacing {
            replacingIDs.append(UInt32(newFiles.count))
            newFiles.append((intern(entry.relativePath), entry.stamp))
        }

        var runs: [UInt32: [UInt32]] = [:]
        runs.reserveCapacity(reader.postingRuns.count)
        for run in reader.postingRuns {
            var copied: [UInt32] = []
            copied.reserveCapacity(run.count)
            for old in reader.postingFileIDs(offset: run.offset, count: run.count) {
                let mapped = Int(old)
                guard mapped < translate.count else { continue }
                let newID = translate[mapped]
                if newID >= 0 { copied.append(UInt32(newID)) }
            }
            if !copied.isEmpty { runs[run.stringID] = copied }
        }
        for (entry, fileID) in zip(replacing, replacingIDs) {
            for identifier in entry.identifiers {
                runs[intern(identifier), default: []].append(fileID)
            }
        }

        var referenced = Set<UInt32>()
        referenced.reserveCapacity(newFiles.count + runs.count)
        for file in newFiles { referenced.insert(file.pathID) }
        for id in runs.keys { referenced.insert(id) }
        let orphans = strings.count - referenced.count
        if strings.count > 0, orphans * 4 > strings.count {
            let rebuilt = entries(files: newFiles, runs: runs, strings: strings)
            try write(rebuilt, to: url)
            return try JavaNameIndexShardReader(url: url)
        }

        var out = Data()
        out.append(contentsOf: Self.magic)
        out.appendUInt32LE(Self.formatVersion)
        out.appendUInt32LE(UInt32(newFiles.count))
        var stringBytes = Data()
        stringBytes.appendUInt32LE(UInt32(strings.count))
        if reader.encodedStringTable.count >= 4 {
            stringBytes.append(reader.encodedStringTable.dropFirst(4))
        }
        for string in strings[oldStringCount...] {
            let bytes = Array(string.utf8)
            stringBytes.appendUInt32LE(UInt32(bytes.count))
            stringBytes.append(contentsOf: bytes)
        }
        out.appendUInt32LE(UInt32(stringBytes.count))
        out.append(stringBytes)
        for file in newFiles {
            out.appendUInt32LE(file.pathID)
            out.appendInt64LE(file.stamp.size)
            out.appendFloat64LE(file.stamp.modificationDate)
        }

        out.appendUInt32LE(UInt32(runs.count))
        var body = Data()
        var table: [String: (Int, Int)] = [:]
        var runList: [(stringID: UInt32, offset: Int, count: Int)] = []
        table.reserveCapacity(runs.count)
        runList.reserveCapacity(runs.count)
        for identifierID in runs.keys.sorted() {
            let fileIDs = runs[identifierID]!
            let offset = body.count
            out.appendUInt32LE(identifierID)
            out.appendUInt32LE(UInt32(offset))
            out.appendUInt32LE(UInt32(fileIDs.count))
            for fileID in fileIDs { body.appendUInt32LE(fileID) }
            let index = Int(identifierID)
            if index < strings.count { table[strings[index]] = (offset, fileIDs.count) }
            runList.append((identifierID, offset, fileIDs.count))
        }
        out.append(body)

        var files: [(relativePath: String, stamp: JavaStamp)] = []
        files.reserveCapacity(newFiles.count)
        for file in newFiles {
            let index = Int(file.pathID)
            guard index < strings.count else { throw JavaIndexStoreError.corrupt("path id") }
            files.append((strings[index], file.stamp))
        }
        let built = JavaNameIndexShardReader(
            files: files, stringTable: strings, encodedStringTable: stringBytes,
            postingRuns: runList, postingTable: table, postings: body
        )

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: url, options: .atomic)
        return built
    }

    private func entries(
        files: [(pathID: UInt32, stamp: JavaStamp)], runs: [UInt32: [UInt32]], strings: [String]
    ) -> [JavaNameIndexEntry] {
        var sets = [Set<String>](repeating: [], count: files.count)
        for (stringID, fileIDs) in runs {
            let index = Int(stringID)
            guard index < strings.count else { continue }
            let name = strings[index]
            for fileID in fileIDs where Int(fileID) < sets.count {
                sets[Int(fileID)].insert(name)
            }
        }
        return files.enumerated().map { index, file in
            JavaNameIndexEntry(relativePath: strings[Int(file.pathID)], stamp: file.stamp, identifiers: sets[index])
        }.sorted { $0.relativePath < $1.relativePath }
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
    /// Decoded string table. Ids are indexes; an incremental rewrite appends new strings after these.
    let stringTable: [String]
    /// `StringTableBuilder.encoded()` bytes, including the leading count, so a rewrite can copy them.
    let encodedStringTable: Data
    /// One posting run per identifier: string id, byte offset, file count.
    let postingRuns: [(stringID: UInt32, offset: Int, count: Int)]
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
        let encodedStrings = data.subdata(in: cursor..<(cursor + stringsLength))
        let strings = StringTableBuilder.decode(encodedStrings)
        cursor += stringsLength
        self.stringTable = strings
        self.encodedStringTable = encodedStrings

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
        var runs: [(stringID: UInt32, offset: Int, count: Int)] = []
        runs.reserveCapacity(identifierCount)
        for _ in 0..<identifierCount {
            guard cursor + 12 <= data.count else { throw JavaIndexStoreError.corrupt("index table") }
            let id = data.readUInt32LE(at: cursor)
            let offset = Int(data.readUInt32LE(at: cursor + 4))
            let count = Int(data.readUInt32LE(at: cursor + 8))
            cursor += 12
            guard Int(id) < strings.count else { throw JavaIndexStoreError.corrupt("identifier id") }
            table[strings[Int(id)]] = (offset, count)
            runs.append((id, offset, count))
        }
        self.postingTable = table
        self.postingRuns = runs
        self.postingsBase = cursor
    }

    /// A reader over tables a rewrite already built, so a save does not decode the string table it
    /// just wrote. Posting offsets are relative to `postings`, which is the postings section alone.
    init(
        files: [(relativePath: String, stamp: JavaStamp)],
        stringTable: [String],
        encodedStringTable: Data,
        postingRuns: [(stringID: UInt32, offset: Int, count: Int)],
        postingTable: [String: (Int, Int)],
        postings: Data
    ) {
        self.files = files
        self.data = postings
        self.postingsBase = 0
        self.stringTable = stringTable
        self.encodedStringTable = encodedStringTable
        self.postingRuns = postingRuns
        self.postingTable = postingTable
    }

    /// Raw file ids of one posting run, in stored order.
    func postingFileIDs(offset: Int, count: Int) -> [UInt32] {
        let start = postingsBase + offset
        guard count > 0, start + count * 4 <= data.count else { return [] }
        var ids: [UInt32] = []
        ids.reserveCapacity(count)
        for index in 0..<count {
            ids.append(data.readUInt32LE(at: start + index * 4))
        }
        return ids
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

    /// Inverts the postings back into per-file entries. Incremental updates copy posting runs
    /// instead; this remains for the round-trip test.
    public func allEntries() -> [JavaNameIndexEntry] {
        var sets = [Set<String>](repeating: [], count: files.count)
        for identifier in postingTable.keys {
            for id in fileIDs(containing: identifier) { sets[id].insert(identifier) }
        }
        return files.enumerated().map { JavaNameIndexEntry(relativePath: $1.relativePath, stamp: $1.stamp, identifiers: sets[$0]) }
    }
}
