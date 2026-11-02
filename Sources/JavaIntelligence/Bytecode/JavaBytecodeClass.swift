import Foundation

/// What one method's bytecode refers to. Owners are JVM internal names (`java/util/List`).
public enum JavaBytecodeReference: Hashable, Sendable {
    case method(owner: String, name: String, descriptor: String)
    case field(owner: String, name: String, descriptor: String, isWrite: Bool)
    /// `new`, `checkcast`, `instanceof`, array creation and a class literal.
    case type(owner: String)
}

/// A class file reduced to what a reference search needs: its place in the hierarchy, its members,
/// and, when bodies were asked for, the references inside each method. No instruction is kept.
public struct JavaBytecodeClass: Sendable {
    public struct Member: Hashable, Sendable {
        public let name: String
        public let descriptor: String
        public let access: UInt16
        public var isSynthetic: Bool { access & 0x1000 != 0 }
        public var isStatic: Bool { access & 0x0008 != 0 }
    }

    public let name: String
    public let superName: String?
    public let interfaces: [String]
    public let access: UInt16
    public let fields: [Member]
    public let methods: [Member]
    /// Parallel to ``methods``; empty arrays when parsed without bodies.
    public let references: [[JavaBytecodeReference]]

    public var isInterface: Bool { access & 0x0200 != 0 }
}

/// Parses the constant pool, members and `Code` attributes of a class file (JVMS §4). Everything is
/// bounds-checked: a truncated or hostile file yields `nil`, never a trap.
public enum JavaBytecodeReader {
    public static func parse(_ data: Data, includeBodies: Bool) -> JavaBytecodeClass? {
        var reader = Reader(bytes: [UInt8](data))
        return try? read(&reader, includeBodies: includeBodies)
    }

    // MARK: - Reader

    private struct Truncated: Error {}

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func u1() throws -> Int {
            guard offset < bytes.count else { throw Truncated() }
            defer { offset += 1 }
            return Int(bytes[offset])
        }

        mutating func u2() throws -> Int {
            guard offset + 2 <= bytes.count else { throw Truncated() }
            defer { offset += 2 }
            return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
        }

        mutating func u4() throws -> Int {
            guard offset + 4 <= bytes.count else { throw Truncated() }
            defer { offset += 4 }
            var value = 0
            for index in 0..<4 { value = value << 8 | Int(bytes[offset + index]) }
            return value
        }

        mutating func skip(_ count: Int) throws {
            guard count >= 0, offset + count <= bytes.count else { throw Truncated() }
            offset += count
        }

        mutating func slice(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, offset + count <= bytes.count else { throw Truncated() }
            defer { offset += count }
            return bytes[offset..<(offset + count)]
        }
    }

    // MARK: - Constant pool

    private enum Constant {
        case none
        case utf8(String)
        case classRef(Int)
        case nameAndType(name: Int, descriptor: Int)
        case fieldRef(classIndex: Int, nameAndType: Int)
        case methodRef(classIndex: Int, nameAndType: Int)
        case methodHandle(referenceIndex: Int)
        case invokeDynamic(bootstrap: Int)
    }

    private static func readPool(_ reader: inout Reader) throws -> [Constant] {
        let count = try reader.u2()
        var pool = [Constant](repeating: .none, count: max(count, 1))
        var index = 1
        while index < count {
            let tag = try reader.u1()
            switch tag {
            case 1:
                let length = try reader.u2()
                pool[index] = .utf8(String(decoding: try reader.slice(length), as: UTF8.self))
            case 7:
                pool[index] = .classRef(try reader.u2())
            case 8, 16, 19, 20:
                try reader.skip(2)
            case 15:
                try reader.skip(1)
                pool[index] = .methodHandle(referenceIndex: try reader.u2())
            case 3, 4:
                try reader.skip(4)
            case 5, 6:
                try reader.skip(8)
                index += 1
            case 9:
                pool[index] = .fieldRef(classIndex: try reader.u2(), nameAndType: try reader.u2())
            case 10, 11:
                pool[index] = .methodRef(classIndex: try reader.u2(), nameAndType: try reader.u2())
            case 12:
                pool[index] = .nameAndType(name: try reader.u2(), descriptor: try reader.u2())
            case 17:
                try reader.skip(4)
            case 18:
                let bootstrap = try reader.u2()
                try reader.skip(2)
                pool[index] = .invokeDynamic(bootstrap: bootstrap)
            default:
                throw Truncated()
            }
            index += 1
        }
        return pool
    }

    private struct Pool {
        let constants: [Constant]

        func utf8(_ index: Int) -> String? {
            guard constants.indices.contains(index), case .utf8(let text) = constants[index] else { return nil }
            return text
        }

        func className(_ index: Int) -> String? {
            guard constants.indices.contains(index), case .classRef(let name) = constants[index] else { return nil }
            return utf8(name)
        }

        func nameAndType(_ index: Int) -> (name: String, descriptor: String)? {
            guard constants.indices.contains(index),
                  case .nameAndType(let name, let descriptor) = constants[index],
                  let n = utf8(name), let d = utf8(descriptor) else { return nil }
            return (n, d)
        }

        func method(_ index: Int) -> JavaBytecodeReference? {
            guard constants.indices.contains(index), case .methodRef(let owner, let nt) = constants[index],
                  let ownerName = className(owner), let (name, descriptor) = nameAndType(nt) else { return nil }
            return .method(owner: ownerName, name: name, descriptor: descriptor)
        }

        func field(_ index: Int, isWrite: Bool) -> JavaBytecodeReference? {
            guard constants.indices.contains(index), case .fieldRef(let owner, let nt) = constants[index],
                  let ownerName = className(owner), let (name, descriptor) = nameAndType(nt) else { return nil }
            return .field(owner: ownerName, name: name, descriptor: descriptor, isWrite: isWrite)
        }

        /// The method a `MethodHandle` constant points at (`Foo::bar`, a lambda body).
        func handleTarget(_ index: Int) -> JavaBytecodeReference? {
            guard constants.indices.contains(index), case .methodHandle(let reference) = constants[index] else { return nil }
            return method(reference)
        }
    }

    // MARK: - Class

    private static func read(_ reader: inout Reader, includeBodies: Bool) throws -> JavaBytecodeClass {
        guard try reader.u4() == 0xCAFE_BABE else { throw Truncated() }
        try reader.skip(4)
        let pool = Pool(constants: try readPool(&reader))
        let access = try reader.u2()
        guard let name = pool.className(try reader.u2()) else { throw Truncated() }
        let superIndex = try reader.u2()
        let superName = superIndex == 0 ? nil : pool.className(superIndex)
        var interfaces: [String] = []
        for _ in 0..<(try reader.u2()) {
            if let interface = pool.className(try reader.u2()) { interfaces.append(interface) }
        }

        var fields: [JavaBytecodeClass.Member] = []
        for _ in 0..<(try reader.u2()) {
            let flags = try reader.u2()
            let memberName = pool.utf8(try reader.u2()) ?? ""
            let descriptor = pool.utf8(try reader.u2()) ?? ""
            for _ in 0..<(try reader.u2()) {
                try reader.skip(2)
                try reader.skip(try reader.u4())
            }
            fields.append(.init(name: memberName, descriptor: descriptor, access: UInt16(flags)))
        }

        struct RawMethod {
            var member: JavaBytecodeClass.Member
            var code: ArraySlice<UInt8>?
        }
        var raw: [RawMethod] = []
        for _ in 0..<(try reader.u2()) {
            let flags = try reader.u2()
            let memberName = pool.utf8(try reader.u2()) ?? ""
            let descriptor = pool.utf8(try reader.u2()) ?? ""
            var code: ArraySlice<UInt8>?
            for _ in 0..<(try reader.u2()) {
                let attributeName = pool.utf8(try reader.u2()) ?? ""
                let length = try reader.u4()
                if includeBodies, attributeName == "Code" {
                    code = try reader.slice(length)
                } else {
                    try reader.skip(length)
                }
            }
            raw.append(RawMethod(member: .init(name: memberName, descriptor: descriptor, access: UInt16(flags)), code: code))
        }

        // Class attributes: only BootstrapMethods matters, for method references.
        var bootstraps: [[Int]] = []
        for _ in 0..<(try reader.u2()) {
            let attributeName = pool.utf8(try reader.u2()) ?? ""
            let length = try reader.u4()
            guard includeBodies, attributeName == "BootstrapMethods" else {
                try reader.skip(length)
                continue
            }
            let end = reader.offset + length
            for _ in 0..<(try reader.u2()) {
                try reader.skip(2)
                var arguments: [Int] = []
                for _ in 0..<(try reader.u2()) { arguments.append(try reader.u2()) }
                bootstraps.append(arguments)
            }
            reader.offset = end
        }

        var references: [[JavaBytecodeReference]] = []
        if includeBodies {
            for method in raw {
                guard let code = method.code else {
                    references.append([])
                    continue
                }
                references.append(decodeCode(code, pool: pool, bootstraps: bootstraps))
            }
        }
        return JavaBytecodeClass(
            name: name, superName: superName, interfaces: interfaces, access: UInt16(access),
            fields: fields, methods: raw.map(\.member), references: references
        )
    }

    // MARK: - Code

    /// Walks a `Code` attribute's instructions and collects what they refer to, in order, once each.
    private static func decodeCode(
        _ attribute: ArraySlice<UInt8>, pool: Pool, bootstraps: [[Int]]
    ) -> [JavaBytecodeReference] {
        let bytes = [UInt8](attribute)
        guard bytes.count >= 8 else { return [] }
        let codeLength = Int(bytes[4]) << 24 | Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7])
        guard codeLength >= 0, 8 + codeLength <= bytes.count else { return [] }
        let code = bytes[8..<(8 + codeLength)].map { $0 }

        func u2(_ at: Int) -> Int? {
            at + 1 < code.count ? Int(code[at]) << 8 | Int(code[at + 1]) : nil
        }
        func s4(_ at: Int) -> Int? {
            guard at + 3 < code.count else { return nil }
            let value = Int32(bitPattern: UInt32(code[at]) << 24 | UInt32(code[at + 1]) << 16
                | UInt32(code[at + 2]) << 8 | UInt32(code[at + 3]))
            return Int(value)
        }

        var found: [JavaBytecodeReference] = []
        var seen = Set<JavaBytecodeReference>()
        func add(_ reference: JavaBytecodeReference?) {
            if let reference, seen.insert(reference).inserted { found.append(reference) }
        }

        var pc = 0
        while pc < code.count {
            let opcode = Int(code[pc])
            var length = instructionLength(opcode)
            switch opcode {
            case 0x12: // ldc
                if pc + 1 < code.count, let owner = pool.className(Int(code[pc + 1])) { add(.type(owner: owner)) }
            case 0x13: // ldc_w
                if let index = u2(pc + 1), let owner = pool.className(index) { add(.type(owner: owner)) }
            case 0xb2, 0xb4: // getstatic, getfield
                if let index = u2(pc + 1) { add(pool.field(index, isWrite: false)) }
            case 0xb3, 0xb5: // putstatic, putfield
                if let index = u2(pc + 1) { add(pool.field(index, isWrite: true)) }
            case 0xb6, 0xb7, 0xb8, 0xb9: // invokes
                if let index = u2(pc + 1) { add(pool.method(index)) }
            case 0xba: // invokedynamic: the method handles among its bootstrap arguments
                if let index = u2(pc + 1), pool.constants.indices.contains(index),
                   case .invokeDynamic(let bootstrap) = pool.constants[index], bootstraps.indices.contains(bootstrap) {
                    for argument in bootstraps[bootstrap] { add(pool.handleTarget(argument)) }
                }
            case 0xbb, 0xbd, 0xc0, 0xc1, 0xc5: // new, anewarray, checkcast, instanceof, multianewarray
                if let index = u2(pc + 1), let owner = pool.className(index) { add(.type(owner: owner)) }
            case 0xaa: // tableswitch
                let base = (pc + 4) & ~3
                guard let low = s4(base + 4), let high = s4(base + 8), high >= low else { return found }
                length = base + 12 + (high - low + 1) * 4 - pc
            case 0xab: // lookupswitch
                let base = (pc + 4) & ~3
                guard let pairs = s4(base + 4), pairs >= 0 else { return found }
                length = base + 8 + pairs * 8 - pc
            case 0xc4: // wide
                length = pc + 1 < code.count && code[pc + 1] == 0x84 ? 6 : 4
            default:
                break
            }
            guard length > 0 else { return found }
            pc += length
        }
        return found
    }

    /// Total bytes of the instruction at `opcode`, 0 for an opcode that does not exist. The
    /// variable-length ones (`tableswitch`, `lookupswitch`, `wide`) are sized by the caller.
    private static func instructionLength(_ opcode: Int) -> Int {
        switch opcode {
        case 0x00...0x0f: return 1
        case 0x10: return 2
        case 0x11: return 3
        case 0x12: return 2
        case 0x13, 0x14: return 3
        case 0x15...0x19: return 2
        case 0x1a...0x35: return 1
        case 0x36...0x3a: return 2
        case 0x3b...0x83: return 1
        case 0x84: return 3
        case 0x85...0x98: return 1
        case 0x99...0xa8: return 3
        case 0xa9: return 2
        case 0xaa, 0xab, 0xc4: return 1
        case 0xac...0xb1: return 1
        case 0xb2...0xb8: return 3
        case 0xb9, 0xba: return 5
        case 0xbb: return 3
        case 0xbc: return 2
        case 0xbd: return 3
        case 0xbe, 0xbf: return 1
        case 0xc0, 0xc1: return 3
        case 0xc2, 0xc3: return 1
        case 0xc5: return 4
        case 0xc6, 0xc7: return 3
        case 0xc8, 0xc9: return 5
        default: return 0
        }
    }
}
