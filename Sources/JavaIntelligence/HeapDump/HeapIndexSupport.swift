import Darwin
import Foundation

/// What an object number is.
public enum HeapObjectKind: UInt8, Sendable {
    /// Number 0: the root of the dominator tree (phase 3), parent of the GC roots.
    case superRoot = 0
    case instance = 1
    case objectArray = 2
    case primitiveArray = 3
    /// A `java.lang.Class` mirror (a class dump).
    case classObject = 4
}

/// A class of the index: a class dump, or a synthetic group (primitive arrays of one type, all
/// class mirrors, objects whose class is missing from the dump).
public struct HeapClass: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case loaded
        case primitiveArray(HprofBasicType)
        case classMirrors
        case unknown
    }

    public struct Field: Sendable, Hashable {
        public let name: String
        public let type: HprofBasicType
    }

    public struct StaticField: Sendable, Hashable {
        public let name: String
        public let type: HprofBasicType
        /// The raw value: an object id for `.object`, the bits of the primitive otherwise.
        public let value: UInt64
    }

    public let id: UInt64
    public let name: String
    public let superID: UInt64
    public internal(set) var superIndex: Int32
    public let loaderID: UInt64
    /// The class dump record's offset in the dump file; -1 for a synthetic group.
    public let dumpOffset: Int64
    public let kind: Kind
    /// Declared instance fields, in dump order (the superclass's are on the superclass).
    public let fields: [Field]
    public let statics: [StaticField]
}

/// Every class of the dump with its names resolved, plus the synthetic groups. Index 0 is the
/// unknown class, so a missing class dump never breaks a lookup.
struct ClassTable: Sendable {
    var entries: [HeapClass]
    var indexByID: [UInt64: Int32]
    /// By `HprofBasicType.rawValue` (0...11); -1 where there is no such type.
    var primitiveArrayIndex: [Int32]
    var mirrorGroup: Int32

    struct ReferenceLayout: Sendable {
        struct Slot: Sendable {
            let offset: UInt32
            let isWeak: Bool
        }

        /// Where each reference sits in an instance's field bytes, this class's fields first.
        let slots: [Slot]
        /// The field bytes of an instance in the dump (references at the id size).
        let fieldBytes: Int
    }

    static func make(
        records: [HprofClassDumpRecord], offsets: [Int64], fd: Int32, fileSize: Int64,
        topLevel: HeapDumpCensus.TopLevel, idSize: Int
    ) throws -> ClassTable {
        var nameIDs = Set<UInt64>()
        for record in records {
            for field in record.fields { nameIDs.insert(field.nameID) }
            for field in record.statics { nameIDs.insert(field.nameID) }
        }
        let fieldNames = try HeapDumpCensus.readStrings(fd: fd, fileSize: fileSize, ids: nameIDs, topLevel: topLevel)
        let classNames = try HeapDumpCensus.readClassNames(fd: fd, fileSize: fileSize, topLevel: topLevel)
        func name(_ id: UInt64) -> String { fieldNames[id] ?? "<field 0x\(String(id, radix: 16))>" }

        var entries: [HeapClass] = [HeapClass(
            id: 0, name: "<unknown class>", superID: 0, superIndex: -1, loaderID: 0, dumpOffset: -1,
            kind: .unknown, fields: [], statics: []
        )]
        var indexByID: [UInt64: Int32] = [:]
        for (record, offset) in zip(records, offsets) where indexByID[record.id] == nil {
            indexByID[record.id] = Int32(entries.count)
            entries.append(HeapClass(
                id: record.id,
                name: classNames[record.id] ?? String(format: "<unknown class 0x%llx>", record.id),
                superID: record.superID, superIndex: -1, loaderID: record.loaderID, dumpOffset: offset, kind: .loaded,
                fields: record.fields.map { HeapClass.Field(name: name($0.nameID), type: $0.type) },
                statics: record.statics.map { HeapClass.StaticField(name: name($0.nameID), type: $0.type, value: $0.value) }
            ))
        }
        for index in entries.indices where entries[index].superID != 0 {
            entries[index].superIndex = indexByID[entries[index].superID] ?? -1
        }
        var primitive = [Int32](repeating: -1, count: 12)
        for type in HprofBasicType.allCases where type != .object {
            primitive[Int(type.rawValue)] = Int32(entries.count)
            entries.append(HeapClass(
                id: 0, name: type.arrayName, superID: 0, superIndex: -1, loaderID: 0, dumpOffset: -1,
                kind: .primitiveArray(type), fields: [], statics: []
            ))
        }
        let mirrors = Int32(entries.count)
        entries.append(HeapClass(
            id: 0, name: "java.lang.Class", superID: 0, superIndex: -1, loaderID: 0, dumpOffset: -1,
            kind: .classMirrors, fields: [], statics: []
        ))
        return ClassTable(entries: entries, indexByID: indexByID, primitiveArrayIndex: primitive, mirrorGroup: mirrors)
    }

    /// For every class: the reference slots of its instances (class first, then each superclass,
    /// as HPROF writes them). `Reference.referent` is weak.
    func referenceLayouts(idSize: Int) -> [ReferenceLayout] {
        entries.indices.map { index in
            var slots: [ReferenceLayout.Slot] = []
            var offset = 0
            var cursor = Int32(index)
            var seen = Set<Int32>()
            while cursor >= 0, Int(cursor) < entries.count, seen.insert(cursor).inserted {
                let entry = entries[Int(cursor)]
                guard case .loaded = entry.kind else { break }
                let isReference = entry.name == "java.lang.ref.Reference"
                for field in entry.fields {
                    if field.type == .object {
                        slots.append(.init(offset: UInt32(offset), isWeak: isReference && field.name == "referent"))
                    }
                    offset += field.type.size(idSize: idSize)
                }
                cursor = entry.superIndex
            }
            return ReferenceLayout(slots: slots, fieldBytes: offset)
        }
    }

    // MARK: - Persistence

    func write(to url: URL) throws {
        var writer = HeapBinaryWriter()
        writer.u32(0x4843_4C53) // "HCLS"
        writer.u32(UInt32(entries.count))
        writer.u32(UInt32(bitPattern: mirrorGroup))
        for value in primitiveArrayIndex { writer.u32(UInt32(bitPattern: value)) }
        for entry in entries {
            writer.u64(entry.id)
            writer.string(entry.name)
            writer.u64(entry.superID)
            writer.u32(UInt32(bitPattern: entry.superIndex))
            writer.u64(entry.loaderID)
            writer.u64(UInt64(bitPattern: entry.dumpOffset))
            switch entry.kind {
            case .loaded: writer.u8(0); writer.u8(0)
            case .primitiveArray(let type): writer.u8(1); writer.u8(type.rawValue)
            case .classMirrors: writer.u8(2); writer.u8(0)
            case .unknown: writer.u8(3); writer.u8(0)
            }
            writer.u32(UInt32(entry.fields.count))
            for field in entry.fields {
                writer.string(field.name)
                writer.u8(field.type.rawValue)
            }
            writer.u32(UInt32(entry.statics.count))
            for field in entry.statics {
                writer.string(field.name)
                writer.u8(field.type.rawValue)
                writer.u64(field.value)
            }
        }
        try writer.data.write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> ClassTable {
        var reader = try HeapBinaryReader(Data(contentsOf: url))
        guard try reader.u32() == 0x4843_4C53 else { throw HeapIndexError.corrupt("classes.bin") }
        let count = Int(try reader.u32())
        let mirrors = Int32(bitPattern: try reader.u32())
        var primitive: [Int32] = []
        for _ in 0..<12 { primitive.append(Int32(bitPattern: try reader.u32())) }
        var entries: [HeapClass] = []
        entries.reserveCapacity(count)
        var indexByID: [UInt64: Int32] = [:]
        func type(_ raw: UInt8) throws -> HprofBasicType {
            guard let type = HprofBasicType(rawValue: raw) else { throw HeapIndexError.corrupt("classes.bin type \(raw)") }
            return type
        }
        for index in 0..<count {
            let id = try reader.u64()
            let name = try reader.string()
            let superID = try reader.u64()
            let superIndex = Int32(bitPattern: try reader.u32())
            let loaderID = try reader.u64()
            let dumpOffset = Int64(bitPattern: try reader.u64())
            let kindTag = try reader.u8()
            let kindValue = try reader.u8()
            let kind: HeapClass.Kind
            switch kindTag {
            case 0: kind = .loaded
            case 1: kind = .primitiveArray(try type(kindValue))
            case 2: kind = .classMirrors
            default: kind = .unknown
            }
            var fields: [HeapClass.Field] = []
            for _ in 0..<Int(try reader.u32()) {
                fields.append(.init(name: try reader.string(), type: try type(try reader.u8())))
            }
            var statics: [HeapClass.StaticField] = []
            for _ in 0..<Int(try reader.u32()) {
                statics.append(.init(name: try reader.string(), type: try type(try reader.u8()), value: try reader.u64()))
            }
            if case .loaded = kind, indexByID[id] == nil { indexByID[id] = Int32(index) }
            entries.append(HeapClass(
                id: id, name: name, superID: superID, superIndex: superIndex, loaderID: loaderID,
                dumpOffset: dumpOffset, kind: kind, fields: fields, statics: statics
            ))
        }
        return ClassTable(entries: entries, indexByID: indexByID, primitiveArrayIndex: primitive, mirrorGroup: mirrors)
    }
}

/// Object id → number: a bucket table on the address bits narrows the sorted id array to a few
/// entries, then a binary search. No hash table of a hundred million entries.
final class HeapIDLookup: @unchecked Sendable {
    let ids: HeapMappedArray<UInt64>
    /// `[minID, shift, bucketCount, first number of bucket 0, …, end]`.
    private let table: HeapMappedArray<UInt64>
    private let minID: UInt64
    private let maxID: UInt64
    private let shift: UInt64
    private let bucketCount: Int

    private init(ids: HeapMappedArray<UInt64>, table: HeapMappedArray<UInt64>) {
        self.ids = ids
        self.table = table
        minID = table[0]
        shift = table[1]
        bucketCount = Int(table[2])
        maxID = ids.count > 1 ? ids[ids.count - 1] : 0
    }

    static func build(ids: HeapMappedArray<UInt64>, directory: URL) throws -> HeapIDLookup {
        let total = ids.count
        let objects = total - 1
        var buckets = 1
        while buckets < objects, buckets < 1 << 20 { buckets <<= 1 }
        let minID = objects > 0 ? ids[1] : 0
        let span = objects > 0 ? ids[total - 1] - minID : 0
        let bits = span == 0 ? 0 : UInt64(64 - span.leadingZeroBitCount)
        let bucketBits = UInt64(buckets.trailingZeroBitCount)
        let shift = bits > bucketBits ? bits - bucketBits : 0
        let table = try HeapMappedArray<UInt64>.create(directory.appendingPathComponent(HeapIndexBuilder.Files.lookup), count: buckets + 4)
        table[0] = minID
        table[1] = shift
        table[2] = UInt64(buckets)
        var bucket = 0
        for n in 1..<max(total, 1) {
            let b = Int((ids[n] - minID) >> shift)
            while bucket <= b {
                table[3 + bucket] = UInt64(n)
                bucket += 1
            }
        }
        while bucket <= buckets {
            table[3 + bucket] = UInt64(total)
            bucket += 1
        }
        try table.flush()
        return HeapIDLookup(ids: ids, table: table)
    }

    static func open(ids: HeapMappedArray<UInt64>, directory: URL) throws -> HeapIDLookup {
        let url = directory.appendingPathComponent(HeapIndexBuilder.Files.lookup)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let count = ((attributes[.size] as? Int) ?? 0) / 8
        guard count >= 4 else { throw HeapIndexError.corrupt("lookup.u32") }
        return HeapIDLookup(ids: ids, table: try HeapMappedArray<UInt64>.open(url, count: count))
    }

    @inline(__always)
    func number(of id: UInt64) -> Int32? {
        guard ids.count > 1, id >= minID, id <= maxID else { return nil }
        let b = Int((id - minID) >> shift)
        guard b < bucketCount else { return nil }
        var low = Int(table[3 + b])
        var high = Int(table[4 + b])
        while low < high {
            let mid = (low + high) >> 1
            let value = ids[mid]
            if value == id { return Int32(mid) }
            if value < id { low = mid + 1 } else { high = mid }
        }
        return nil
    }
}

/// `meta.json` of an index: what it was built from and what it holds.
struct HeapIndexMeta: Codable, Equatable {
    struct DumpStamp: Codable, Equatable {
        let path: String
        let size: Int64
        let modified: Double
        let inode: UInt64

        init(_ url: URL) throws {
            var info = stat()
            guard stat(url.path, &info) == 0 else { throw HprofError.cannotOpen(String(cString: strerror(errno))) }
            path = url.standardizedFileURL.path
            size = Int64(info.st_size)
            modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            inode = UInt64(info.st_ino)
        }
    }

    let formatVersion: Int
    let dump: DumpStamp
    let idSize: Int
    let objectCount: Int
    let edgeCount: Int
    let classCount: Int
    let rootCount: Int
    let layoutHeader: Int
    let layoutReference: Int
    let danglingReferences: Int
    let reachableCount: Int
    let reachableBytes: Int64
    let weaklyReachableCount: Int
    let weaklyReachableBytes: Int64
    let unreachableCount: Int
    let unreachableBytes: Int64
    let buildSeconds: Double
    let createdAt: Date
}

struct HeapBinaryWriter {
    private(set) var data = Data()

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ value: UInt64) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

    mutating func string(_ value: String) {
        let bytes = Array(value.utf8)
        u32(UInt32(bytes.count))
        data.append(contentsOf: bytes)
    }
}

struct HeapBinaryReader {
    private let data: [UInt8]
    private var position = 0

    init(_ data: Data) throws {
        self.data = [UInt8](data)
    }

    private mutating func bytes(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, position + count <= data.count else { throw HeapIndexError.corrupt("truncated table") }
        defer { position += count }
        return data[position..<position + count]
    }

    mutating func u8() throws -> UInt8 { try bytes(1).first! }

    mutating func u32() throws -> UInt32 {
        try bytes(4).reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    mutating func u64() throws -> UInt64 {
        try bytes(8).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    mutating func string() throws -> String {
        let count = Int(try u32())
        return String(decoding: try bytes(count), as: UTF8.self)
    }
}
