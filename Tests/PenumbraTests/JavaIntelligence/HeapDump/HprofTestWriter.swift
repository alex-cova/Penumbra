import Foundation
@testable import JavaIntelligence

/// Writes exact HPROF files for tests, so every count, size and offset has a known answer and no
/// real dump has to live in the repository.
struct HprofTestWriter {
    var idSize = 8
    var version = "JAVA PROFILE 1.0.2"
    var timestampMillis: UInt64 = 1_763_000_000_000
    private(set) var records = Data()

    init(idSize: Int = 8, version: String = "JAVA PROFILE 1.0.2") {
        self.idSize = idSize
        self.version = version
    }

    mutating func string(_ id: UInt64, _ text: String) {
        var body = Data()
        body.appendID(id, size: idSize)
        body.append(Data(text.utf8))
        record(HprofFormat.Tag.utf8.rawValue, body)
    }

    /// A class name (internal form, `java/lang/String`) with its string record. `nameID` defaults to
    /// a value derived from the class id so callers need not invent one.
    mutating func loadClass(_ classID: UInt64, name: String, nameID: UInt64? = nil, serial: UInt32 = 1) {
        let nameID = nameID ?? (classID &+ 0x1_0000_0000)
        string(nameID, name)
        var body = Data()
        body.appendU4(serial)
        body.appendID(classID, size: idSize)
        body.appendU4(0)
        body.appendID(nameID, size: idSize)
        record(HprofFormat.Tag.loadClass.rawValue, body)
    }

    mutating func stackTrace() {
        var body = Data()
        body.appendU4(1)
        body.appendU4(1)
        body.appendU4(0)
        record(HprofFormat.Tag.stackTrace.rawValue, body)
    }

    /// A STACK_FRAME naming its method, signature and file by new string records.
    mutating func stackFrame(_ id: UInt64, method: String, signature: String, file: String?, classSerial: UInt32, line: Int32) {
        let methodID = id &+ 0x2_0000_0000, signatureID = id &+ 0x3_0000_0000, fileID = id &+ 0x4_0000_0000
        string(methodID, method)
        string(signatureID, signature)
        if let file { string(fileID, file) }
        var body = Data()
        for value in [id, methodID, signatureID, file == nil ? 0 : fileID] { body.appendID(value, size: idSize) }
        body.appendU4(classSerial)
        body.appendU4(UInt32(bitPattern: line))
        record(HprofFormat.Tag.stackFrame.rawValue, body)
    }

    /// A STACK_TRACE of `frames`, innermost first.
    mutating func stackTrace(serial: UInt32, threadSerial: UInt32, frames: [UInt64]) {
        var body = Data()
        body.appendU4(serial)
        body.appendU4(threadSerial)
        body.appendU4(UInt32(frames.count))
        for frame in frames { body.appendID(frame, size: idSize) }
        record(HprofFormat.Tag.stackTrace.rawValue, body)
    }

    mutating func segment(_ build: (inout HeapSegmentWriter) -> Void) {
        var segment = HeapSegmentWriter(idSize: idSize)
        build(&segment)
        record(HprofFormat.Tag.heapDumpSegment.rawValue, segment.bytes)
    }

    mutating func heapDumpEnd() {
        record(HprofFormat.Tag.heapDumpEnd.rawValue, Data())
    }

    mutating func record(_ tag: UInt8, _ body: Data) {
        records.append(tag)
        records.appendU4(0)
        records.appendU4(UInt32(body.count))
        records.append(body)
    }

    func data() -> Data {
        var out = Data(version.utf8)
        out.append(0)
        out.appendU4(UInt32(idSize))
        out.appendU8(timestampMillis)
        out.append(records)
        return out
    }

    func write(to url: URL) throws {
        try data().write(to: url)
    }
}

struct HeapSegmentWriter {
    let idSize: Int
    var bytes = Data()

    /// A class dump. Static fields carry a zero value of their type.
    mutating func classDump(
        _ id: UInt64, superID: UInt64 = 0, loaderID: UInt64 = 0,
        statics: [HprofBasicType] = [], fields: [HprofBasicType] = [], constants: [HprofBasicType] = []
    ) {
        bytes.append(HprofFormat.SubTag.classDump)
        bytes.appendID(id, size: idSize)
        bytes.appendU4(0)
        bytes.appendID(superID, size: idSize)
        bytes.appendID(loaderID, size: idSize)
        for _ in 0..<4 { bytes.appendID(0, size: idSize) }
        let instanceBytes = fields.reduce(0) { $0 + $1.size(idSize: idSize) }
        bytes.appendU4(UInt32(instanceBytes))
        bytes.appendU2(UInt16(constants.count))
        for (index, type) in constants.enumerated() {
            bytes.appendU2(UInt16(index))
            bytes.append(type.rawValue)
            bytes.append(Data(count: type.size(idSize: idSize)))
        }
        bytes.appendU2(UInt16(statics.count))
        for (index, type) in statics.enumerated() {
            bytes.appendID(UInt64(0x5000 + index), size: idSize)
            bytes.append(type.rawValue)
            bytes.append(Data(count: type.size(idSize: idSize)))
        }
        bytes.appendU2(UInt16(fields.count))
        for (index, type) in fields.enumerated() {
            bytes.appendID(UInt64(0x6000 + index), size: idSize)
            bytes.append(type.rawValue)
        }
    }

    /// An instance whose field block is `fieldBytes` zero bytes (the class chain's HPROF field size).
    mutating func instance(_ id: UInt64, classID: UInt64, fieldBytes: Int) {
        bytes.append(HprofFormat.SubTag.instanceDump)
        bytes.appendID(id, size: idSize)
        bytes.appendU4(0)
        bytes.appendID(classID, size: idSize)
        bytes.appendU4(UInt32(fieldBytes))
        bytes.append(Data(count: fieldBytes))
    }

    mutating func objectArray(_ id: UInt64, classID: UInt64, elements: [UInt64]) {
        bytes.append(HprofFormat.SubTag.objectArrayDump)
        bytes.appendID(id, size: idSize)
        bytes.appendU4(0)
        bytes.appendU4(UInt32(elements.count))
        bytes.appendID(classID, size: idSize)
        for element in elements { bytes.appendID(element, size: idSize) }
    }

    mutating func primitiveArray(_ id: UInt64, type: HprofBasicType, length: Int) {
        bytes.append(HprofFormat.SubTag.primitiveArrayDump)
        bytes.appendID(id, size: idSize)
        bytes.appendU4(0)
        bytes.appendU4(UInt32(length))
        bytes.append(type.rawValue)
        bytes.append(Data(count: length * type.size(idSize: idSize)))
    }

    mutating func root(_ kind: HprofRootKind, _ id: UInt64) {
        let tag: UInt8
        switch kind {
        case .unknown: tag = HprofFormat.SubTag.rootUnknown
        case .jniGlobal: tag = HprofFormat.SubTag.rootJNIGlobal
        case .jniLocal: tag = HprofFormat.SubTag.rootJNILocal
        case .javaFrame: tag = HprofFormat.SubTag.rootJavaFrame
        case .nativeStack: tag = HprofFormat.SubTag.rootNativeStack
        case .stickyClass: tag = HprofFormat.SubTag.rootStickyClass
        case .threadBlock: tag = HprofFormat.SubTag.rootThreadBlock
        case .monitorUsed: tag = HprofFormat.SubTag.rootMonitorUsed
        case .threadObject: tag = HprofFormat.SubTag.rootThreadObject
        }
        bytes.append(tag)
        bytes.appendID(id, size: idSize)
        bytes.append(Data(count: HeapDumpCensus.rootBodySize(kind, idSize: idSize) - idSize))
    }

    /// A root with its two extra words (thread serial, then frame number or stack trace serial).
    mutating func root(_ kind: HprofRootKind, _ id: UInt64, first: UInt32, second: UInt32) {
        let tag: UInt8
        switch kind {
        case .jniLocal: tag = HprofFormat.SubTag.rootJNILocal
        case .javaFrame: tag = HprofFormat.SubTag.rootJavaFrame
        case .threadObject: tag = HprofFormat.SubTag.rootThreadObject
        default:
            root(kind, id)
            return
        }
        bytes.append(tag)
        bytes.appendID(id, size: idSize)
        bytes.appendU4(first)
        bytes.appendU4(second)
    }

    mutating func raw(_ data: Data) {
        bytes.append(data)
    }
}

extension Data {
    mutating func appendU2(_ value: UInt16) { Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) } }
    mutating func appendU4(_ value: UInt32) { Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) } }
    mutating func appendU8(_ value: UInt64) { Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) } }

    mutating func appendID(_ value: UInt64, size: Int) {
        if size == 8 { appendU8(value) } else { appendU4(UInt32(truncatingIfNeeded: value)) }
    }
}

/// A field value as an instance record stores it.
enum HprofTestValue {
    case ref(UInt64)
    case int(Int32)
    case long(Int64)
    case byte(Int8)
    case bool(Bool)
    case char(UInt16)

    var type: HprofBasicType {
        switch self {
        case .ref: return .object
        case .int: return .int
        case .long: return .long
        case .byte: return .byte
        case .bool: return .boolean
        case .char: return .char
        }
    }

    func append(to data: inout Data, idSize: Int) {
        switch self {
        case .ref(let id): data.appendID(id, size: idSize)
        case .int(let value): data.appendU4(UInt32(bitPattern: value))
        case .long(let value): data.appendU8(UInt64(bitPattern: value))
        case .byte(let value): data.append(UInt8(bitPattern: value))
        case .bool(let value): data.append(value ? 1 : 0)
        case .char(let value): data.appendU2(value)
        }
    }
}

extension HprofTestWriter {
    /// The id of a field name's string record, written the first time a name is asked for.
    mutating func name(_ text: String, cache: inout [String: UInt64]) -> UInt64 {
        if let id = cache[text] { return id }
        let id = UInt64(0x7000_0000 + cache.count)
        cache[text] = id
        string(id, text)
        return id
    }
}

extension HeapSegmentWriter {
    /// A class dump with named fields and statics with values.
    mutating func classDump(
        _ id: UInt64, superID: UInt64 = 0, loaderID: UInt64 = 0,
        namedStatics: [(nameID: UInt64, value: HprofTestValue)] = [],
        namedFields: [(nameID: UInt64, type: HprofBasicType)] = []
    ) {
        bytes.append(HprofFormat.SubTag.classDump)
        bytes.appendID(id, size: idSize)
        bytes.appendU4(0)
        bytes.appendID(superID, size: idSize)
        bytes.appendID(loaderID, size: idSize)
        for _ in 0..<4 { bytes.appendID(0, size: idSize) }
        bytes.appendU4(UInt32(namedFields.reduce(0) { $0 + $1.type.size(idSize: idSize) }))
        bytes.appendU2(0)
        bytes.appendU2(UInt16(namedStatics.count))
        for field in namedStatics {
            bytes.appendID(field.nameID, size: idSize)
            bytes.append(field.value.type.rawValue)
            field.value.append(to: &bytes, idSize: idSize)
        }
        bytes.appendU2(UInt16(namedFields.count))
        for field in namedFields {
            bytes.appendID(field.nameID, size: idSize)
            bytes.append(field.type.rawValue)
        }
    }

    /// An instance with these values, in record order (the class's fields, then its supers').
    mutating func instance(_ id: UInt64, classID: UInt64, values: [HprofTestValue]) {
        var fields = Data()
        for value in values { value.append(to: &fields, idSize: idSize) }
        bytes.append(HprofFormat.SubTag.instanceDump)
        bytes.appendID(id, size: idSize)
        bytes.appendU4(0)
        bytes.appendID(classID, size: idSize)
        bytes.appendU4(UInt32(fields.count))
        bytes.append(fields)
    }

    /// A primitive array with its element bytes as given (already in dump order).
    mutating func primitiveArray(_ id: UInt64, type: HprofBasicType, count: Int, elements: Data) {
        bytes.append(HprofFormat.SubTag.primitiveArrayDump)
        bytes.appendID(id, size: idSize)
        bytes.appendU4(0)
        bytes.appendU4(UInt32(count))
        bytes.append(type.rawValue)
        bytes.append(elements)
    }
}
