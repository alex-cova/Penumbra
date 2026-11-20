import Foundation

/// A class dump sub-record, with the values of its static fields.
struct HprofClassDumpRecord: Sendable {
    struct Field: Sendable {
        let nameID: UInt64
        let type: HprofBasicType
    }

    struct StaticField: Sendable {
        let nameID: UInt64
        let type: HprofBasicType
        /// The raw value, big-endian bytes read into the low bits (an id for `.object`).
        let value: UInt64
    }

    let id: UInt64
    let superID: UInt64
    let loaderID: UInt64
    let statics: [StaticField]
    /// Declared instance fields, in dump order.
    let fields: [Field]

    var declaredPrimitiveBytes: Int {
        fields.reduce(0) { $0 + ($1.type == .object ? 0 : $1.type.size(idSize: 8)) }
    }

    var declaredReferences: Int { fields.reduce(0) { $0 + ($1.type == .object ? 1 : 0) } }

    var staticPrimitiveBytes: Int {
        statics.reduce(0) { $0 + ($1.type == .object ? 0 : $1.type.size(idSize: 8)) }
    }

    var staticReferences: Int { statics.reduce(0) { $0 + ($1.type == .object ? 1 : 0) } }
}

/// Receives the sub-records of heap segments, in file order. Specialized per visitor, so the walk
/// costs no dynamic dispatch.
protocol HprofHeapVisitor {
    /// When true, `instance` gets the field bytes and `objectArray` the element ids; otherwise nil.
    var wantsContents: Bool { get }
    mutating func instance(id: UInt64, classID: UInt64, offset: Int64, fieldBytes: Int, fields: UnsafeRawPointer?)
    mutating func objectArray(id: UInt64, classID: UInt64, length: Int, offset: Int64, elements: UnsafeRawPointer?)
    mutating func primitiveArray(id: UInt64, type: HprofBasicType, length: Int, offset: Int64)
    mutating func classDump(_ record: HprofClassDumpRecord, offset: Int64)
    /// `first` and `second` are the root's extra words: thread serial and frame or stack trace serial.
    mutating func root(_ kind: HprofRootKind, id: UInt64, first: UInt32, second: UInt32)
}

enum HprofHeapWalker {
    /// Walks one HEAP_DUMP or HEAP_DUMP_SEGMENT body. An unknown sub-record ends the segment with
    /// `.malformed`, a record running past the file with `.truncated`; what came before was visited.
    static func walk<V: HprofHeapVisitor>(
        _ segment: Range<Int64>, reader: HprofByteReader, idSize I: Int, visitor: inout V
    ) throws {
        reader.seek(to: segment.lowerBound)
        let contents = visitor.wantsContents
        while reader.position < segment.upperBound {
            let recordStart = reader.position
            let tag = try reader.u1()
            switch tag {
            case HprofFormat.SubTag.instanceDump:
                let p = try reader.take(2 * I + 8)
                let id = HprofByteReader.id(p, 0, size: I)
                let classID = HprofByteReader.id(p, I + 4, size: I)
                let length = Int(HprofByteReader.u4(p, 2 * I + 4))
                let fields = contents && length > 0 ? try reader.peek(length) : nil
                try reader.skip(Int64(length))
                visitor.instance(id: id, classID: classID, offset: recordStart, fieldBytes: length, fields: fields)
            case HprofFormat.SubTag.objectArrayDump:
                let p = try reader.take(2 * I + 8)
                let id = HprofByteReader.id(p, 0, size: I)
                let length = Int(HprofByteReader.u4(p, I + 4))
                let classID = HprofByteReader.id(p, I + 8, size: I)
                let bytes = length * I
                let elements = contents && bytes > 0 ? try reader.peek(bytes) : nil
                try reader.skip(Int64(bytes))
                visitor.objectArray(id: id, classID: classID, length: length, offset: recordStart, elements: elements)
            case HprofFormat.SubTag.primitiveArrayDump:
                let p = try reader.take(I + 9)
                let id = HprofByteReader.id(p, 0, size: I)
                let length = Int(HprofByteReader.u4(p, I + 4))
                let rawType = p.load(fromByteOffset: I + 8, as: UInt8.self)
                guard let type = HprofBasicType(rawValue: rawType), type != .object else {
                    throw HprofError.malformed(at: recordStart, "primitive array of type \(rawType)")
                }
                try reader.skip(Int64(length) * Int64(type.size(idSize: I)))
                visitor.primitiveArray(id: id, type: type, length: length, offset: recordStart)
            case HprofFormat.SubTag.classDump:
                visitor.classDump(try readClassDump(reader, idSize: I, at: recordStart), offset: recordStart)
            default:
                guard let kind = HprofRootKind(subTag: tag) else {
                    throw HprofError.malformed(at: recordStart, String(format: "unknown heap record tag 0x%02X; the rest of this segment was skipped", tag))
                }
                let size = HeapDumpCensus.rootBodySize(kind, idSize: I)
                let p = try reader.take(size)
                let id = HprofByteReader.id(p, 0, size: I)
                let first = size >= I + 4 ? HprofByteReader.u4(p, I) : 0
                let second = size >= I + 8 ? HprofByteReader.u4(p, I + 4) : 0
                visitor.root(kind, id: id, first: kind == .jniGlobal ? 0 : first, second: kind == .jniGlobal ? 0 : second)
            }
        }
    }

    /// Reads a class dump whose tag has been consumed.
    static func readClassDump(_ reader: HprofByteReader, idSize I: Int, at offset: Int64) throws -> HprofClassDumpRecord {
        let p = try reader.take(7 * I + 8)
        let id = HprofByteReader.id(p, 0, size: I)
        let superID = HprofByteReader.id(p, I + 4, size: I)
        let loaderID = HprofByteReader.id(p, 2 * I + 4, size: I)
        func type(_ raw: UInt8) throws -> HprofBasicType {
            guard let type = HprofBasicType(rawValue: raw) else {
                throw HprofError.malformed(at: offset, "class dump field of type \(raw)")
            }
            return type
        }
        let constants = Int(try reader.u2())
        for _ in 0..<constants {
            let q = try reader.take(3)
            try reader.skip(Int64(try type(q.load(fromByteOffset: 2, as: UInt8.self)).size(idSize: I)))
        }
        let staticCount = Int(try reader.u2())
        var statics: [HprofClassDumpRecord.StaticField] = []
        statics.reserveCapacity(staticCount)
        for _ in 0..<staticCount {
            let q = try reader.take(I + 1)
            let nameID = HprofByteReader.id(q, 0, size: I)
            let fieldType = try type(q.load(fromByteOffset: I, as: UInt8.self))
            let size = fieldType.size(idSize: I)
            let v = try reader.take(size)
            statics.append(.init(nameID: nameID, type: fieldType, value: readValue(v, 0, size: size)))
        }
        let fieldCount = Int(try reader.u2())
        var fields: [HprofClassDumpRecord.Field] = []
        fields.reserveCapacity(fieldCount)
        for _ in 0..<fieldCount {
            let q = try reader.take(I + 1)
            fields.append(.init(nameID: HprofByteReader.id(q, 0, size: I), type: try type(q.load(fromByteOffset: I, as: UInt8.self))))
        }
        return HprofClassDumpRecord(id: id, superID: superID, loaderID: loaderID, statics: statics, fields: fields)
    }

    /// A big-endian value of 1, 2, 4 or 8 bytes, zero-extended.
    @inline(__always)
    static func readValue(_ p: UnsafeRawPointer, _ offset: Int, size: Int) -> UInt64 {
        switch size {
        case 1: return UInt64(p.load(fromByteOffset: offset, as: UInt8.self))
        case 2: return UInt64(HprofByteReader.u2(p, offset))
        case 4: return UInt64(HprofByteReader.u4(p, offset))
        default: return HprofByteReader.u8(p, offset)
        }
    }
}
