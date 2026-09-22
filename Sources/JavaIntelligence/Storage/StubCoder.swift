import Foundation

/// Encodes/decodes a ``JavaClassStub`` to/from a compact binary body, used by
/// ``JavaIndexShardWriter``/``JavaIndexShardReader``. All strings are interned through the shard's
/// shared string table (passed in as `inout` while writing, and as a resolved `[String]` while
/// reading) rather than being repeated inline.
///
/// The read/write helpers below thread `ByteWriter`/`ByteReader` through explicit `inout`
/// parameters rather than capturing them in closures: Swift's exclusivity checking rejects a
/// mutating call whose closure argument also takes the same captured variable `inout` (the
/// combinator call and the closure's own access overlap). Passing the cursor as a fresh parameter
/// into each nested closure sidesteps that -- it's the same storage, but not a *captured* one.
enum StubCoder {
    // MARK: - Encode

    static func encode(_ stub: JavaClassStub, stringTable: inout StringTableBuilder) -> Data {
        var w = ByteWriter()
        encodeStub(stub, &w, &stringTable)
        return w.data
    }

    private static func encodeStub(_ stub: JavaClassStub, _ w: inout ByteWriter, _ st: inout StringTableBuilder) {
        w.writeString(stub.binaryName, &st)
        w.writeString(stub.qualifiedName, &st)
        w.writeString(stub.simpleName, &st)
        w.writeString(stub.packageName, &st)
        w.writeOptionalString(stub.outerQualifiedName, &st)
        w.writeUInt8(stub.kind.rawValue)
        w.writeUInt16(stub.modifiers.rawValue)
        writeTypeParameters(stub.typeParameters, &w, &st)
        writeOptional(stub.superclass, &w, &st, writeType)
        writeArray(stub.interfaces, &w, &st, writeType)
        writeArray(stub.fields, &w, &st, writeField)
        writeArray(stub.methods, &w, &st, writeMethod)
        writeArray(stub.innerTypeNames, &w, &st) { name, w, st in w.writeString(name, &st) }
        writeOrigin(stub.origin, &w, &st)
        w.writeOptionalString(stub.javadoc, &st)
    }

    /// Writes an array with an explicit `(element, inout ByteWriter, inout StringTableBuilder)`
    /// encoder, so nested arrays/optionals never need to capture `w`/`st` from an enclosing scope.
    private static func writeArray<T>(
        _ array: [T], _ w: inout ByteWriter, _ st: inout StringTableBuilder,
        _ encode: (T, inout ByteWriter, inout StringTableBuilder) -> Void
    ) {
        w.writeUInt32(UInt32(array.count))
        for e in array { encode(e, &w, &st) }
    }

    private static func writeOptional<T>(
        _ value: T?, _ w: inout ByteWriter, _ st: inout StringTableBuilder,
        _ encode: (T, inout ByteWriter, inout StringTableBuilder) -> Void
    ) {
        if let value {
            w.writeUInt8(1)
            encode(value, &w, &st)
        } else {
            w.writeUInt8(0)
        }
    }

    private static func writeType(_ type: JavaTypeRef, _ w: inout ByteWriter, _ st: inout StringTableBuilder) {
        switch type {
        case .primitive(let p):
            w.writeUInt8(0)
            w.writeString(p.rawValue, &st)
        case .void:
            w.writeUInt8(1)
        case .classType(let qualifiedName, let arguments, let outer):
            w.writeUInt8(2)
            w.writeString(qualifiedName, &st)
            writeArray(arguments, &w, &st, writeTypeArgument)
            writeOptional(outer, &w, &st, writeType)
        case .array(let element):
            w.writeUInt8(3)
            writeType(element, &w, &st)
        case .typeVariable(let name):
            w.writeUInt8(4)
            w.writeString(name, &st)
        case .wildcard(let bound):
            w.writeUInt8(5)
            writeOptional(bound, &w, &st, writeWildcardBound)
        case .unresolved(let simpleName, let arguments):
            w.writeUInt8(6)
            w.writeString(simpleName, &st)
            writeArray(arguments, &w, &st, writeTypeArgument)
        }
    }

    private static func writeTypeArgument(_ arg: JavaTypeArgument, _ w: inout ByteWriter, _ st: inout StringTableBuilder) {
        switch arg {
        case .type(let t):
            w.writeUInt8(0)
            writeType(t, &w, &st)
        case .wildcard(let bound):
            w.writeUInt8(1)
            writeOptional(bound, &w, &st, writeWildcardBound)
        }
    }

    private static func writeWildcardBound(_ bound: JavaWildcardBound, _ w: inout ByteWriter, _ st: inout StringTableBuilder) {
        switch bound {
        case .extends(let t):
            w.writeUInt8(0)
            writeType(t, &w, &st)
        case .superBound(let t):
            w.writeUInt8(1)
            writeType(t, &w, &st)
        }
    }

    private static func writeTypeParameters(_ params: [JavaTypeParameter], _ w: inout ByteWriter, _ st: inout StringTableBuilder) {
        writeArray(params, &w, &st) { p, w, st in
            w.writeString(p.name, &st)
            writeArray(p.bounds, &w, &st, writeType)
        }
    }

    private static func writeField(_ field: JavaFieldStub, _ w: inout ByteWriter, _ st: inout StringTableBuilder) {
        w.writeString(field.name, &st)
        writeType(field.type, &w, &st)
        w.writeUInt16(field.modifiers.rawValue)
        w.writeOptionalString(field.javadoc, &st)
    }

    private static func writeMethod(_ method: JavaMethodStub, _ w: inout ByteWriter, _ st: inout StringTableBuilder) {
        w.writeString(method.name, &st)
        writeTypeParameters(method.typeParameters, &w, &st)
        writeArray(method.parameters, &w, &st) { p, w, st in
            w.writeOptionalString(p.name, &st)
            writeType(p.type, &w, &st)
        }
        writeType(method.returnType, &w, &st)
        writeArray(method.thrownTypes, &w, &st, writeType)
        w.writeUInt16(method.modifiers.rawValue)
        w.writeUInt8(method.isConstructor ? 1 : 0)
        w.writeOptionalString(method.javadoc, &st)
    }

    private static func writeOrigin(_ origin: JavaStubOrigin, _ w: inout ByteWriter, _ st: inout StringTableBuilder) {
        switch origin {
        case .jdkModule(let module):
            w.writeUInt8(0)
            w.writeString(module, &st)
        case .jar(let url):
            w.writeUInt8(1)
            w.writeString(url.path, &st)
        case .source(let url, let nameRange):
            w.writeUInt8(2)
            w.writeString(url.path, &st)
            w.writeUInt32(UInt32(nameRange.lowerBound))
            w.writeUInt32(UInt32(nameRange.upperBound))
        }
    }

    // MARK: - Decode

    static func decode(_ data: Data, stringTable: [String]) -> JavaClassStub? {
        var r = ByteReader(data)
        return decodeStub(&r, stringTable)
    }

    private static func decodeStub(_ r: inout ByteReader, _ st: [String]) -> JavaClassStub? {
        guard let binaryName = r.readString(st),
              let qualifiedName = r.readString(st),
              let simpleName = r.readString(st),
              let packageName = r.readString(st) else { return nil }
        let outerQualifiedName = r.readOptionalString(st)
        guard let kindRaw = r.readUInt8(), let kind = JavaTypeKind(rawValue: kindRaw) else { return nil }
        guard let modifiersRaw = r.readUInt16() else { return nil }
        let modifiers = JavaModifiers(rawValue: modifiersRaw)
        guard let typeParameters = readTypeParameters(&r, st) else { return nil }
        guard let superclassOpt = readOptional(&r, st, readType) else { return nil }
        guard let interfaces = readArray(&r, st, readType) else { return nil }
        guard let fields = readArray(&r, st, readField) else { return nil }
        guard let methods = readArray(&r, st, readMethod) else { return nil }
        guard let innerTypeNames = readArray(&r, st, { r, st in r.readString(st) }) else { return nil }
        guard let origin = readOrigin(&r, st) else { return nil }
        let javadoc = r.readOptionalString(st)

        return JavaClassStub(
            binaryName: binaryName, qualifiedName: qualifiedName, simpleName: simpleName,
            packageName: packageName, outerQualifiedName: outerQualifiedName, kind: kind,
            modifiers: modifiers, typeParameters: typeParameters, superclass: flattenOptional(superclassOpt),
            interfaces: interfaces, fields: fields, methods: methods,
            innerTypeNames: innerTypeNames, origin: origin, javadoc: javadoc
        )
    }

    /// Reads an array with an explicit `(inout ByteReader, [String]) -> T?` decoder (mirrors
    /// `writeArray`). Returns `nil` (propagating failure) if any element or the count is missing.
    private static func readArray<T>(
        _ r: inout ByteReader, _ st: [String],
        _ decode: (inout ByteReader, [String]) -> T?
    ) -> [T]? {
        guard let count = r.readUInt32() else { return nil }
        var result: [T] = []
        result.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let e = decode(&r, st) else { return nil }
            result.append(e)
        }
        return result
    }

    /// Reads an optional value, distinguishing decode failure (outer `nil`) from "value absent"
    /// (`.some(nil)`) from "value present" (`.some(.some(x))`) -- callers use `flattenOptional`
    /// to collapse the last two cases into a plain `T?` once they've confirmed decode success.
    private static func readOptional<T>(
        _ r: inout ByteReader, _ st: [String],
        _ decode: (inout ByteReader, [String]) -> T?
    ) -> T?? {
        guard let present = r.readUInt8() else { return nil }
        guard present == 1 else { return .some(nil) }
        guard let value = decode(&r, st) else { return nil }
        return .some(value)
    }

    private static func readType(_ r: inout ByteReader, _ st: [String]) -> JavaTypeRef? {
        guard let tag = r.readUInt8() else { return nil }
        switch tag {
        case 0:
            guard let raw = r.readString(st), let p = JavaPrimitive(rawValue: raw) else { return nil }
            return .primitive(p)
        case 1:
            return .void
        case 2:
            guard let qualifiedName = r.readString(st) else { return nil }
            guard let arguments = readArray(&r, st, readTypeArgument) else { return nil }
            guard let outerOpt = readOptional(&r, st, readType) else { return nil }
            return .classType(qualifiedName: qualifiedName, arguments: arguments, outer: flattenOptional(outerOpt))
        case 3:
            guard let element = readType(&r, st) else { return nil }
            return .array(element: element)
        case 4:
            guard let name = r.readString(st) else { return nil }
            return .typeVariable(name: name)
        case 5:
            guard let boundOpt = readOptional(&r, st, readWildcardBound) else { return nil }
            return .wildcard(bound: flattenOptional(boundOpt))
        case 6:
            guard let simpleName = r.readString(st) else { return nil }
            guard let arguments = readArray(&r, st, readTypeArgument) else { return nil }
            return .unresolved(simpleName: simpleName, arguments: arguments)
        default:
            return nil
        }
    }

    private static func readTypeArgument(_ r: inout ByteReader, _ st: [String]) -> JavaTypeArgument? {
        guard let tag = r.readUInt8() else { return nil }
        switch tag {
        case 0:
            guard let t = readType(&r, st) else { return nil }
            return .type(t)
        case 1:
            guard let boundOpt = readOptional(&r, st, readWildcardBound) else { return nil }
            return .wildcard(flattenOptional(boundOpt))
        default:
            return nil
        }
    }

    private static func readWildcardBound(_ r: inout ByteReader, _ st: [String]) -> JavaWildcardBound? {
        guard let tag = r.readUInt8() else { return nil }
        switch tag {
        case 0:
            guard let t = readType(&r, st) else { return nil }
            return .extends(t)
        case 1:
            guard let t = readType(&r, st) else { return nil }
            return .superBound(t)
        default:
            return nil
        }
    }

    private static func readTypeParameters(_ r: inout ByteReader, _ st: [String]) -> [JavaTypeParameter]? {
        readArray(&r, st) { r, st -> JavaTypeParameter? in
            guard let name = r.readString(st) else { return nil }
            guard let bounds = readArray(&r, st, readType) else { return nil }
            return JavaTypeParameter(name: name, bounds: bounds)
        }
    }

    private static func readField(_ r: inout ByteReader, _ st: [String]) -> JavaFieldStub? {
        guard let name = r.readString(st) else { return nil }
        guard let type = readType(&r, st) else { return nil }
        guard let modifiersRaw = r.readUInt16() else { return nil }
        let javadoc = r.readOptionalString(st)
        return JavaFieldStub(name: name, type: type, modifiers: JavaModifiers(rawValue: modifiersRaw), javadoc: javadoc)
    }

    private static func readMethod(_ r: inout ByteReader, _ st: [String]) -> JavaMethodStub? {
        guard let name = r.readString(st) else { return nil }
        guard let typeParameters = readTypeParameters(&r, st) else { return nil }
        guard let parameters = readArray(&r, st, { r, st -> JavaParameterStub? in
            let pname = r.readOptionalString(st)
            guard let type = readType(&r, st) else { return nil }
            return JavaParameterStub(name: pname, type: type)
        }) else { return nil }
        guard let returnType = readType(&r, st) else { return nil }
        guard let thrownTypes = readArray(&r, st, readType) else { return nil }
        guard let modifiersRaw = r.readUInt16() else { return nil }
        guard let isConstructorRaw = r.readUInt8() else { return nil }
        let javadoc = r.readOptionalString(st)
        return JavaMethodStub(
            name: name, typeParameters: typeParameters, parameters: parameters,
            returnType: returnType, thrownTypes: thrownTypes,
            modifiers: JavaModifiers(rawValue: modifiersRaw), isConstructor: isConstructorRaw == 1,
            javadoc: javadoc
        )
    }

    private static func readOrigin(_ r: inout ByteReader, _ st: [String]) -> JavaStubOrigin? {
        guard let tag = r.readUInt8() else { return nil }
        switch tag {
        case 0:
            guard let module = r.readString(st) else { return nil }
            return .jdkModule(module)
        case 1:
            guard let path = r.readString(st) else { return nil }
            return .jar(URL(fileURLWithPath: path))
        case 2:
            guard let path = r.readString(st) else { return nil }
            guard let lower = r.readUInt32(), let upper = r.readUInt32() else { return nil }
            return .source(URL(fileURLWithPath: path), nameRange: Int(lower)..<Int(upper))
        default:
            return nil
        }
    }
}

/// Collapses `T??` (decode-failure vs. absent-vs-present, see `StubCoder.readOptional`) into a
/// plain `T?` once the outer `nil` (decode failure) has already been checked by the caller's
/// `guard let`.
private func flattenOptional<T>(_ value: T??) -> T? {
    switch value {
    case .some(.some(let v)): return v
    default: return nil
    }
}

/// Interns strings while a shard is being written, so repeated names (types, packages, parameter
/// names) are stored once. Shared by ``JavaIndexShardWriter`` and ``StubCoder``.
public struct StringTableBuilder {
    var table = StringTableInternal()
    public init() {}

    mutating func id(for string: String) -> UInt32 {
        table.id(for: string)
    }

    func encoded() -> Data {
        table.encoded()
    }

    /// Decodes a string table produced by `encoded()` back into an index-addressable array.
    static func decode(_ data: Data) -> [String] {
        var cursor = 0
        guard cursor + 4 <= data.count else { return [] }
        let count = Int(data.readUInt32LE(at: cursor)); cursor += 4
        var result: [String] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            guard cursor + 4 <= data.count else { break }
            let length = Int(data.readUInt32LE(at: cursor)); cursor += 4
            guard cursor + length <= data.count else { break }
            let bytes = data.subdata(in: cursor..<(cursor + length))
            result.append(String(decoding: bytes, as: UTF8.self))
            cursor += length
        }
        return result
    }
}

struct StringTableInternal {
    private var strings: [String] = []
    private var ids: [String: UInt32] = [:]

    mutating func id(for string: String) -> UInt32 {
        if let existing = ids[string] { return existing }
        let id = UInt32(strings.count)
        strings.append(string)
        ids[string] = id
        return id
    }

    func encoded() -> Data {
        var out = Data()
        out.appendUInt32LE(UInt32(strings.count))
        for s in strings {
            let bytes = Array(s.utf8)
            out.appendUInt32LE(UInt32(bytes.count))
            out.append(contentsOf: bytes)
        }
        return out
    }
}

// MARK: - Byte writer/reader primitives (little-endian, length-prefixed strings by string-table ID)

struct ByteWriter {
    var data = Data()

    mutating func writeUInt8(_ v: UInt8) { data.append(v) }
    mutating func writeUInt16(_ v: UInt16) {
        var val = v.littleEndian
        Swift.withUnsafeBytes(of: &val) { data.append(contentsOf: $0) }
    }
    mutating func writeUInt32(_ v: UInt32) { data.appendUInt32LE(v) }

    mutating func writeString(_ s: String, _ st: inout StringTableBuilder) {
        writeUInt32(st.id(for: s))
    }
    mutating func writeOptionalString(_ s: String?, _ st: inout StringTableBuilder) {
        if let s {
            writeUInt8(1)
            writeString(s, &st)
        } else {
            writeUInt8(0)
        }
    }
}

struct ByteReader {
    let bytes: [UInt8]
    var offset = 0

    init(_ data: Data) { self.bytes = [UInt8](data) }

    mutating func readUInt8() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }
    mutating func readUInt16() -> UInt16? {
        guard offset + 2 <= bytes.count else { return nil }
        let v = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        offset += 2
        return v
    }
    mutating func readUInt32() -> UInt32? {
        guard offset + 4 <= bytes.count else { return nil }
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(bytes[offset + i]) << (8 * i) }
        offset += 4
        return v
    }
    mutating func readString(_ st: [String]) -> String? {
        guard let id = readUInt32(), Int(id) < st.count else { return nil }
        return st[Int(id)]
    }
    mutating func readOptionalString(_ st: [String]) -> String? {
        guard let present = readUInt8() else { return nil }
        guard present == 1 else { return nil }
        return readString(st)
    }
}
