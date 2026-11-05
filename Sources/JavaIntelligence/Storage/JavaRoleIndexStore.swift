import Foundation

/// One indexed source file: its path relative to the source root, the stamp its roles were read
/// at, and every identifier's roles there.
public struct JavaRoleIndexEntry: Sendable, Equatable {
    public let relativePath: String
    public let stamp: JavaStamp
    /// Identifier text to its role bitmask (`JavaIdentifierRoles.rawValue`).
    public let roles: [String: UInt8]

    public init(relativePath: String, stamp: JavaStamp, roles: [String: UInt8]) {
        self.relativePath = relativePath
        self.stamp = stamp
        self.roles = roles
    }
}

/// Persists the role index of one source root (`roles.idx`): which files use which identifiers
/// in which syntactic roles. Same style as ``JavaNameIndexShardWriter`` -- a shared string
/// table, little-endian integers, an atomic write -- with its own magic and format version.
///
/// Format (little-endian):
/// ```
/// magic: "PROL" (4 bytes)
/// formatVersion: UInt32
/// fileCount: UInt32
/// stringTable: UInt32 byteLength, then the table (see StringTableBuilder)
/// files: [UInt32 pathStringID, Int64 size, Float64 modificationDate] * fileCount
/// identifierCount: UInt32
/// index: [UInt32 identifierStringID, UInt32 byteOffset, UInt32 postingCount] * identifierCount
/// postings: [UInt32 fileID, UInt32 roleMask] runs, referenced by the index table
/// ```
public struct JavaRoleIndexShardWriter {
    public static let formatVersion: UInt32 = 1
    static let magic: [UInt8] = Array("PROL".utf8)

    public init() {}

    public func write(_ entries: [JavaRoleIndexEntry], to url: URL) throws {
        var stringTable = StringTableBuilder()
        var postings: [UInt32: [(fileID: UInt32, mask: UInt32)]] = [:]
        var pathIDs: [UInt32] = []
        pathIDs.reserveCapacity(entries.count)
        for (fileID, entry) in entries.enumerated() {
            pathIDs.append(stringTable.id(for: entry.relativePath))
            for (identifier, mask) in entry.roles {
                postings[stringTable.id(for: identifier), default: []].append((UInt32(fileID), UInt32(mask)))
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
            let pairs = postings[identifierID]!
            out.appendUInt32LE(identifierID)
            out.appendUInt32LE(UInt32(body.count))
            out.appendUInt32LE(UInt32(pairs.count))
            for pair in pairs {
                body.appendUInt32LE(pair.fileID)
                body.appendUInt32LE(pair.mask)
            }
        }
        out.append(body)

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: url, options: .atomic)
    }

    /// Rewrites a readable shard without turning postings back into strings. `removing` is the set
    /// of old file ids to drop (deleted or edited). `replacing` is those edited files plus new
    /// ones, already role-read. Surviving files keep dense new ids; their posting runs are copied
    /// and translated. When orphaned strings pass a quarter of the string table, falls back to
    /// ``write(_:to:)``.
    @discardableResult
    public func rewrite(
        from reader: JavaRoleIndexShardReader, removing: Set<Int>, replacing: [JavaRoleIndexEntry], to url: URL
    ) throws -> JavaRoleIndexShardReader {
        // An edited file arrives as both a removal (its old id) and a replacement entry; a
        // replacing path always wins over any surviving file of the same name.
        var removing = removing
        var survivingByPath: [String: Int] = [:]
        for (id, file) in reader.files.enumerated() where !removing.contains(id) {
            survivingByPath[file.relativePath] = id
        }
        for entry in replacing {
            if let old = survivingByPath[entry.relativePath] { removing.insert(old) }
        }

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

        var runs: [UInt32: [(fileID: UInt32, mask: UInt32)]] = [:]
        runs.reserveCapacity(reader.postingRuns.count)
        for run in reader.postingRuns {
            var copied: [(fileID: UInt32, mask: UInt32)] = []
            copied.reserveCapacity(run.count)
            for (fileID, mask) in reader.postingPairs(offset: run.offset, count: run.count) {
                let mapped = Int(fileID)
                guard mapped < translate.count else { continue }
                let newID = translate[mapped]
                if newID >= 0 { copied.append((UInt32(newID), mask)) }
            }
            if !copied.isEmpty { runs[run.stringID] = copied }
        }
        for (entry, fileID) in zip(replacing, replacingIDs) {
            for (identifier, mask) in entry.roles {
                runs[intern(identifier), default: []].append((fileID, UInt32(mask)))
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
            return try JavaRoleIndexShardReader(url: url)
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
            let pairs = runs[identifierID]!
            let offset = body.count
            out.appendUInt32LE(identifierID)
            out.appendUInt32LE(UInt32(offset))
            out.appendUInt32LE(UInt32(pairs.count))
            for pair in pairs {
                body.appendUInt32LE(pair.fileID)
                body.appendUInt32LE(pair.mask)
            }
            let index = Int(identifierID)
            if index < strings.count { table[strings[index]] = (offset, pairs.count) }
            runList.append((identifierID, offset, pairs.count))
        }
        out.append(body)

        var files: [(relativePath: String, stamp: JavaStamp)] = []
        files.reserveCapacity(newFiles.count)
        for file in newFiles {
            let index = Int(file.pathID)
            guard index < strings.count else { throw JavaIndexStoreError.corrupt("path id") }
            files.append((strings[index], file.stamp))
        }
        let built = JavaRoleIndexShardReader(
            files: files, stringTable: strings, encodedStringTable: stringBytes,
            postingRuns: runList, postingTable: table, postings: body
        )

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try out.write(to: url, options: .atomic)
        return built
    }

    private func entries(
        files: [(pathID: UInt32, stamp: JavaStamp)], runs: [UInt32: [(fileID: UInt32, mask: UInt32)]], strings: [String]
    ) -> [JavaRoleIndexEntry] {
        var roles = [[String: UInt8]](repeating: [:], count: files.count)
        for (stringID, pairs) in runs {
            let index = Int(stringID)
            guard index < strings.count else { continue }
            let name = strings[index]
            for pair in pairs where Int(pair.fileID) < roles.count {
                roles[Int(pair.fileID)][name, default: 0] |= UInt8(pair.mask & 0xFF)
            }
        }
        return files.enumerated().map { index, file in
            JavaRoleIndexEntry(relativePath: strings[Int(file.pathID)], stamp: file.stamp, roles: roles[index])
        }.sorted { $0.relativePath < $1.relativePath }
    }
}

/// Reads a shard written by ``JavaRoleIndexShardWriter``. The file table and the identifier
/// offset table are parsed at `init` (the file is memory-mapped); a posting list is only decoded
/// when its identifier is asked for.
public final class JavaRoleIndexShardReader: @unchecked Sendable {
    /// Relative path and stamp of every indexed file, indexed by file id.
    public let files: [(relativePath: String, stamp: JavaStamp)]

    private let data: Data
    private let postingsBase: Int
    /// Decoded string table. Ids are indexes; an incremental rewrite appends new strings after these.
    let stringTable: [String]
    /// `StringTableBuilder.encoded()` bytes, including the leading count, so a rewrite can copy them.
    let encodedStringTable: Data
    /// One posting run per identifier: string id, byte offset, pair count.
    let postingRuns: [(stringID: UInt32, offset: Int, count: Int)]
    /// identifier -> (byteOffset, pairCount) within the postings section.
    private let postingTable: [String: (Int, Int)]

    public init(url: URL) throws {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        self.data = data
        guard data.count >= 4, Array(data.prefix(4)) == JavaRoleIndexShardWriter.magic else {
            throw JavaIndexStoreError.badMagic
        }
        var cursor = 4
        guard cursor + 8 <= data.count else { throw JavaIndexStoreError.corrupt("header") }
        let version = data.readUInt32LE(at: cursor); cursor += 4
        guard version == JavaRoleIndexShardWriter.formatVersion else {
            throw JavaIndexStoreError.unsupportedFormatVersion(found: Int(version), expected: Int(JavaRoleIndexShardWriter.formatVersion))
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

    /// Raw (file id, role mask) pairs of one posting run, in stored order.
    func postingPairs(offset: Int, count: Int) -> [(fileID: UInt32, mask: UInt32)] {
        let start = postingsBase + offset
        guard count > 0, start + count * 8 <= data.count else { return [] }
        var pairs: [(UInt32, UInt32)] = []
        pairs.reserveCapacity(count)
        for index in 0..<count {
            pairs.append((data.readUInt32LE(at: start + index * 8), data.readUInt32LE(at: start + index * 8 + 4)))
        }
        return pairs
    }

    /// Ids (indexes into ``files``) of the files that use `identifier` in one of `roles`.
    public func fileIDs(containing identifier: String, roles: JavaIdentifierRoles) -> [Int] {
        guard let (offset, count) = postingTable[identifier], !roles.isEmpty else { return [] }
        let wanted = UInt32(roles.rawValue)
        let start = postingsBase + offset
        guard start + count * 8 <= data.count else { return [] }
        var ids: [Int] = []
        ids.reserveCapacity(count)
        for index in 0..<count {
            let id = Int(data.readUInt32LE(at: start + index * 8))
            let mask = data.readUInt32LE(at: start + index * 8 + 4)
            if id < files.count, mask & wanted != 0 { ids.append(id) }
        }
        return ids
    }

    /// Ids of the files that mention `identifier` in any role.
    public func fileIDs(containing identifier: String) -> [Int] {
        fileIDs(containing: identifier, roles: .all)
    }

    public func relativePaths(containing identifier: String, roles: JavaIdentifierRoles) -> [String] {
        fileIDs(containing: identifier, roles: roles).map { files[$0].relativePath }
    }

    public var identifierCount: Int { postingTable.count }

    /// Inverts the postings back into per-file entries. Incremental updates copy posting runs
    /// instead; this remains for the round-trip test.
    public func allEntries() -> [JavaRoleIndexEntry] {
        var roles = [[String: UInt8]](repeating: [:], count: files.count)
        for identifier in postingTable.keys {
            guard let (offset, count) = postingTable[identifier] else { continue }
            let start = postingsBase + offset
            guard start + count * 8 <= data.count else { continue }
            for index in 0..<count {
                let id = Int(data.readUInt32LE(at: start + index * 8))
                let mask = UInt8(data.readUInt32LE(at: start + index * 8 + 4) & 0xFF)
                if id < roles.count { roles[id][identifier, default: 0] |= mask }
            }
        }
        return files.enumerated().map { JavaRoleIndexEntry(relativePath: $1.relativePath, stamp: $1.stamp, roles: roles[$0]) }
    }
}
