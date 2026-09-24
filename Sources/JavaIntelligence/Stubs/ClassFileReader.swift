import Foundation

public enum ClassFileError: Error, Sendable {
    case badMagic
    case truncated
    case unsupportedConstantTag(UInt8)
    case badConstantPoolIndex(Int)
}

/// Controls how much of a class file `ClassFileReader` decodes. Library roots (JDK, JARs) only
/// need public API, so private/synthetic/bridge members are dropped and `Code` is never read.
public struct ClassFileReadOptions: Sendable {
    /// Drop private, synthetic and bridge members (used for library roots; kept for source-derived
    /// stubs isn't relevant since those come from ``JavaSourceStubBuilder`` instead).
    public var membersPublicAPIOnly: Bool
    public init(membersPublicAPIOnly: Bool = true) {
        self.membersPublicAPIOnly = membersPublicAPIOnly
    }
}

/// Decodes a JVM `.class` file (JVMS §4) into a ``JavaClassStub``, reading only the structural
/// data needed for completion: the constant pool, access flags, superclass/interfaces, and
/// field/method headers with their `Signature`, `Exceptions`, `MethodParameters`, `Deprecated`
/// and `RuntimeVisibleAnnotations` attributes. `Code` attributes (actual bytecode) are skipped
/// entirely — this is a stub reader, not a decompiler.
public enum ClassFileReader {
    public static func read(_ bytes: Data, origin: JavaStubOrigin, options: ClassFileReadOptions = ClassFileReadOptions()) throws -> JavaClassStub {
        var cursor = BinaryCursor(bytes)
        let magic = try cursor.readUInt32()
        guard magic == 0xCAFE_BABE else { throw ClassFileError.badMagic }
        _ = try cursor.readUInt16() // minor version
        _ = try cursor.readUInt16() // major version

        let pool = try ConstantPool(reading: &cursor)

        let accessFlags = try cursor.readUInt16()
        let thisClassIndex = try cursor.readUInt16()
        let superClassIndex = try cursor.readUInt16()

        let binaryName = try pool.className(at: thisClassIndex)
        let superBinaryName = superClassIndex == 0 ? nil : try? pool.className(at: superClassIndex)

        let interfaceCount = try cursor.readUInt16()
        var interfaceNames: [String] = []
        interfaceNames.reserveCapacity(Int(interfaceCount))
        for _ in 0..<interfaceCount {
            let idx = try cursor.readUInt16()
            interfaceNames.append(try pool.className(at: idx))
        }

        let fieldCount = try cursor.readUInt16()
        var fields: [JavaFieldStub] = []
        for _ in 0..<fieldCount {
            if let field = try readMember(&cursor, pool: pool, isMethod: false, options: options), case .field(let f) = field.kind {
                fields.append(f)
            }
        }

        let methodCount = try cursor.readUInt16()
        var methods: [JavaMethodStub] = []
        for _ in 0..<methodCount {
            if let method = try readMember(&cursor, pool: pool, isMethod: true, options: options), case .method(let m) = method.kind {
                methods.append(m)
            }
        }

        // Class attributes: Signature, InnerClasses, Deprecated, RuntimeVisibleAnnotations, Record.
        var classSignature: String?
        var isDeprecated = false
        var innerTypeNames: [String] = []
        var isRecord = false
        let hasEnumSuper = superBinaryName == "java/lang/Enum" || superBinaryName == "java.lang.Enum"

        let attrCount = try cursor.readUInt16()
        for _ in 0..<attrCount {
            let nameIndex = try cursor.readUInt16()
            let length = try cursor.readUInt32()
            let attrName = (try? pool.utf8(at: nameIndex)) ?? ""
            let attrStart = cursor.offset
            switch attrName {
            case "Signature":
                let idx = try cursor.readUInt16()
                classSignature = try? pool.utf8(at: idx)
            case "Deprecated":
                isDeprecated = true
            case "InnerClasses":
                let count = try cursor.readUInt16()
                for _ in 0..<count {
                    let innerIdx = try cursor.readUInt16()
                    let outerIdx = try cursor.readUInt16()
                    let nameIdx = try cursor.readUInt16()
                    _ = try cursor.readUInt16() // inner_class_access_flags
                    // Only direct, named members of *this* class (outer == this, name != 0 => not anonymous).
                    if outerIdx != 0, nameIdx != 0, outerIdx == thisClassIndex,
                       let innerBinary = try? pool.className(at: innerIdx) {
                        innerTypeNames.append(JavaTypeRef.qualifiedName(fromInternalName: innerBinary))
                    }
                }
            case "Record":
                isRecord = true
                // RecordComponent entries are skipped structurally; record accessors are already
                // emitted as normal public methods by javac, so no extra decoding is needed here.
                cursor.offset = attrStart + Int(length)
            default:
                break
            }
            cursor.offset = attrStart + Int(length)
        }

        let isInterface = (accessFlags & 0x0200) != 0
        let isAnnotation = (accessFlags & 0x2000) != 0
        let isEnum = (accessFlags & 0x4000) != 0 || hasEnumSuper
        let kind: JavaTypeKind = isAnnotation ? .annotationKind
            : isRecord ? .recordKind
            : isEnum ? .enumKind
            : isInterface ? .interfaceKind
            : .classKind

        let qualifiedBinary = binaryName.replacingOccurrences(of: "/", with: ".")
        let (qualifiedName, packageName, simpleName, outerQualifiedName) = Self.splitName(qualifiedBinary)

        var modifiers = JavaModifiers.fromClassAccessFlags(accessFlags)
        if isDeprecated { modifiers.insert(.deprecatedFlag) }

        var typeParameters: [JavaTypeParameter] = []
        var superclass: JavaTypeRef? = superBinaryName.map { .classType(qualifiedName: JavaTypeRef.qualifiedName(fromInternalName: $0), arguments: [], outer: nil) }
        var interfaces: [JavaTypeRef] = interfaceNames.map { .classType(qualifiedName: JavaTypeRef.qualifiedName(fromInternalName: $0), arguments: [], outer: nil) }

        if let sig = classSignature, let parsed = GenericSignatureParser.parseClassSignature(sig) {
            typeParameters = parsed.typeParameters
            superclass = parsed.superclass
            interfaces = parsed.interfaces
        }

        return JavaClassStub(
            binaryName: qualifiedBinary,
            qualifiedName: qualifiedName,
            simpleName: simpleName,
            packageName: packageName,
            outerQualifiedName: outerQualifiedName,
            kind: kind,
            modifiers: modifiers,
            typeParameters: typeParameters,
            superclass: kind == .interfaceKind ? nil : superclass,
            interfaces: interfaces,
            fields: fields,
            methods: methods,
            innerTypeNames: innerTypeNames,
            origin: origin
        )
    }

    /// Splits a binary name (package separated by '.', nested types separated by '$', both already
    /// converted from the class file's '/'-for-package form) into its parts. E.g.
    /// "java.util.Map$Entry" -> qualifiedName "java.util.Map.Entry", package "java.util",
    /// simpleName "Entry", outer "java.util.Map".
    private static func splitName(_ qualifiedBinary: String) -> (qualifiedName: String, packageName: String, simpleName: String, outerQualifiedName: String?) {
        let nestedParts = qualifiedBinary.components(separatedBy: "$")
        let topLevel = nestedParts[0]
        let packageName: String
        let topSimpleName: String
        if let lastDot = topLevel.range(of: ".", options: .backwards) {
            packageName = String(topLevel[..<lastDot.lowerBound])
            topSimpleName = String(topLevel[topLevel.index(after: lastDot.lowerBound)...])
        } else {
            packageName = ""
            topSimpleName = topLevel
        }
        let simpleChain = [topSimpleName] + nestedParts.dropFirst()
        let simpleName = simpleChain.last ?? topSimpleName
        let qualifiedName = packageName.isEmpty ? simpleChain.joined(separator: ".") : "\(packageName).\(simpleChain.joined(separator: "."))"
        let outerQualifiedName: String?
        if simpleChain.count > 1 {
            let outerChain = simpleChain.dropLast()
            outerQualifiedName = packageName.isEmpty ? outerChain.joined(separator: ".") : "\(packageName).\(outerChain.joined(separator: "."))"
        } else {
            outerQualifiedName = nil
        }
        return (qualifiedName, packageName, simpleName, outerQualifiedName)
    }

    // MARK: - Members

    private enum MemberKind {
        case field(JavaFieldStub)
        case method(JavaMethodStub)
    }
    private struct MemberResult { let kind: MemberKind }

    private static func readMember(_ cursor: inout BinaryCursor, pool: ConstantPool, isMethod: Bool, options: ClassFileReadOptions) throws -> MemberResult? {
        let accessFlags = try cursor.readUInt16()
        let nameIndex = try cursor.readUInt16()
        let descriptorIndex = try cursor.readUInt16()
        let name = (try? pool.utf8(at: nameIndex)) ?? "?"
        let descriptor = (try? pool.utf8(at: descriptorIndex)) ?? ""

        var signature: String?
        var isDeprecated = false
        var parameterNames: [String?]?

        let attrCount = try cursor.readUInt16()
        for _ in 0..<attrCount {
            let attrNameIndex = try cursor.readUInt16()
            let length = try cursor.readUInt32()
            let attrName = (try? pool.utf8(at: attrNameIndex)) ?? ""
            let attrStart = cursor.offset
            switch attrName {
            case "Signature":
                let idx = try cursor.readUInt16()
                signature = try? pool.utf8(at: idx)
            case "Deprecated":
                isDeprecated = true
            case "MethodParameters":
                let count = try cursor.readUInt8()
                var names: [String?] = []
                for _ in 0..<count {
                    let nIdx = try cursor.readUInt16()
                    _ = try cursor.readUInt16() // access_flags
                    names.append(nIdx == 0 ? nil : try? pool.utf8(at: nIdx))
                }
                parameterNames = names
            default:
                break
            }
            cursor.offset = attrStart + Int(length)
        }

        let modifiers = isMethod
            ? JavaModifiers.fromMethodAccessFlags(accessFlags)
            : JavaModifiers.fromFieldAccessFlags(accessFlags)
        var finalModifiers = modifiers
        if isDeprecated { finalModifiers.insert(.deprecatedFlag) }

        if options.membersPublicAPIOnly {
            if finalModifiers.contains(.synthetic) || finalModifiers.contains(.bridge) { return nil }
            if finalModifiers.contains(.privateFlag) || finalModifiers.isPackagePrivate { return nil }
            if name == "<clinit>" { return nil }
        }

        if isMethod {
            let isConstructor = name == "<init>"
            var params: [JavaParameterStub]
            var returnType: JavaTypeRef
            var typeParams: [JavaTypeParameter] = []
            var thrown: [JavaTypeRef] = []

            if let sig = signature, let parsed = GenericSignatureParser.parseMethodSignature(sig) {
                typeParams = parsed.typeParameters
                returnType = parsed.returnType
                thrown = parsed.thrownTypes
                params = zip(parsed.parameters, 0..<parsed.parameters.count).map { type, i in
                    JavaParameterStub(name: parameterNames?[safe: i] ?? nil, type: type)
                }
            } else if let decoded = DescriptorParser.parseMethodDescriptor(descriptor) {
                returnType = decoded.returnType
                params = zip(decoded.parameters, 0..<decoded.parameters.count).map { type, i in
                    JavaParameterStub(name: parameterNames?[safe: i] ?? nil, type: type)
                }
            } else {
                return nil
            }

            let displayName = isConstructor ? "<init>" : name
            return MemberResult(kind: .method(JavaMethodStub(
                name: displayName,
                typeParameters: typeParams,
                parameters: params,
                returnType: returnType,
                thrownTypes: thrown,
                modifiers: finalModifiers,
                isConstructor: isConstructor
            )))
        } else {
            let type: JavaTypeRef
            if let sig = signature {
                var idx = 0
                let bytes = Array(sig.utf8)
                type = fieldSignatureType(bytes, &idx) ?? DescriptorParser.parseFieldDescriptor(descriptor) ?? .classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil)
            } else {
                type = DescriptorParser.parseFieldDescriptor(descriptor) ?? .classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil)
            }
            return MemberResult(kind: .field(JavaFieldStub(name: name, type: type, modifiers: finalModifiers)))
        }
    }

    /// Field `Signature` attributes hold a bare `FieldTypeSignature` (no method wrapper), which
    /// `GenericSignatureParser`'s public entry points don't parse directly, so this small local
    /// helper reuses `parseMethodSignature`'s inner grammar by wrapping it as a synthetic 1-param
    /// method signature and pulling the parameter back out.
    private static func fieldSignatureType(_ bytes: [UInt8], _ idx: inout Int) -> JavaTypeRef? {
        let text = String(decoding: bytes, as: UTF8.self)
        guard let parsed = GenericSignatureParser.parseMethodSignature("(\(text))V") else { return nil }
        return parsed.parameters.first
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension JavaModifiers {
    static func fromClassAccessFlags(_ flags: UInt16) -> JavaModifiers {
        var m: JavaModifiers = []
        if flags & 0x0001 != 0 { m.insert(.publicFlag) }
        if flags & 0x0010 != 0 { m.insert(.finalFlag) }
        if flags & 0x0400 != 0 { m.insert(.abstractFlag) }
        if flags & 0x1000 != 0 { m.insert(.synthetic) }
        return m
    }

    static func fromFieldAccessFlags(_ flags: UInt16) -> JavaModifiers {
        var m: JavaModifiers = []
        if flags & 0x0001 != 0 { m.insert(.publicFlag) }
        if flags & 0x0002 != 0 { m.insert(.privateFlag) }
        if flags & 0x0004 != 0 { m.insert(.protectedFlag) }
        if flags & 0x0008 != 0 { m.insert(.staticFlag) }
        if flags & 0x0010 != 0 { m.insert(.finalFlag) }
        if flags & 0x1000 != 0 { m.insert(.synthetic) }
        if flags & 0x4000 != 0 { m.insert(.enumConstant) }
        return m
    }

    static func fromMethodAccessFlags(_ flags: UInt16) -> JavaModifiers {
        var m: JavaModifiers = []
        if flags & 0x0001 != 0 { m.insert(.publicFlag) }
        if flags & 0x0002 != 0 { m.insert(.privateFlag) }
        if flags & 0x0004 != 0 { m.insert(.protectedFlag) }
        if flags & 0x0008 != 0 { m.insert(.staticFlag) }
        if flags & 0x0010 != 0 { m.insert(.finalFlag) }
        if flags & 0x0400 != 0 { m.insert(.abstractFlag) }
        if flags & 0x0080 != 0 { m.insert(.varargs) }
        if flags & 0x1000 != 0 { m.insert(.synthetic) }
        if flags & 0x0040 != 0 { m.insert(.bridge) }
        return m
    }
}

/// A forward-only cursor over class-file bytes, big-endian per JVMS.
struct BinaryCursor {
    let data: [UInt8]
    var offset: Int = 0

    init(_ data: Data) {
        self.data = [UInt8](data)
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw ClassFileError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        guard offset + 2 <= data.count else { throw ClassFileError.truncated }
        let value = (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
        offset += 2
        return value
    }

    mutating func readUInt32() throws -> UInt32 {
        guard offset + 4 <= data.count else { throw ClassFileError.truncated }
        var value: UInt32 = 0
        for i in 0..<4 { value = (value << 8) | UInt32(data[offset + i]) }
        offset += 4
        return value
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard offset + count <= data.count else { throw ClassFileError.truncated }
        defer { offset += count }
        return Array(data[offset..<(offset + count)])
    }
}

/// The JVM constant pool (JVMS §4.4). Only the tags relevant to stub extraction are decoded fully;
/// unrecognized/irrelevant ones (integers, floats, method handles, dynamic constants, etc.) are
/// skipped structurally so the cursor stays in sync, but their contents aren't kept.
struct ConstantPool {
    private enum Entry {
        case utf8(String)
        case classRef(nameIndex: UInt16)
        case other
        /// Long/Double entries occupy two consecutive pool slots (JVMS §4.4.5); the following index
        /// is unusable and must be skipped by the reader.
        case wide
    }

    private var entries: [Entry] = [.other] // index 0 is unused

    init(reading cursor: inout BinaryCursor) throws {
        let count = try cursor.readUInt16()
        var i: UInt16 = 1
        while i < count {
            let tag = try cursor.readUInt8()
            switch tag {
            case 1: // Utf8
                let length = try cursor.readUInt16()
                let bytes = try cursor.readBytes(Int(length))
                entries.append(.utf8(Self.decodeModifiedUTF8(bytes)))
            case 7: // Class
                let nameIndex = try cursor.readUInt16()
                entries.append(.classRef(nameIndex: nameIndex))
            case 8, 16, 19, 20: // String, MethodType, Module, Package
                _ = try cursor.readUInt16()
                entries.append(.other)
            case 15: // MethodHandle
                _ = try cursor.readUInt8()
                _ = try cursor.readUInt16()
                entries.append(.other)
            case 3, 4: // Integer, Float
                _ = try cursor.readUInt32()
                entries.append(.other)
            case 5, 6: // Long, Double
                _ = try cursor.readUInt32()
                _ = try cursor.readUInt32()
                entries.append(.other)
                entries.append(.wide)
                i += 1
            case 9, 10, 11, 12, 17, 18: // Fieldref, Methodref, InterfaceMethodref, NameAndType, Dynamic, InvokeDynamic
                _ = try cursor.readUInt16()
                _ = try cursor.readUInt16()
                entries.append(.other)
            default:
                throw ClassFileError.unsupportedConstantTag(tag)
            }
            i += 1
        }
    }

    func utf8(at index: UInt16) throws -> String {
        guard index > 0, Int(index) < entries.count, case .utf8(let s) = entries[Int(index)] else {
            throw ClassFileError.badConstantPoolIndex(Int(index))
        }
        return s
    }

    func className(at index: UInt16) throws -> String {
        guard index > 0, Int(index) < entries.count, case .classRef(let nameIndex) = entries[Int(index)] else {
            throw ClassFileError.badConstantPoolIndex(Int(index))
        }
        return try utf8(at: nameIndex)
    }

    /// The JVM's modified UTF-8 differs from standard UTF-8 only for the NUL character and
    /// supplementary-plane characters; for the identifiers/descriptors read here (ASCII/BMP), a
    /// direct UTF-8 decode is correct and avoids implementing the full 6-byte surrogate encoding.
    private static func decodeModifiedUTF8(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}
