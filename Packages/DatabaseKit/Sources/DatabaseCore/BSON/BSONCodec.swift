import Foundation

public enum BSONError: Error, Equatable, LocalizedError {
    case truncated
    case invalidLength(Int)
    case invalidType(UInt8)
    case invalidString
    case tooDeep
    case tooLarge(Int)
    case invalidKey(String)

    public var errorDescription: String? {
        switch self {
        case .truncated: "The BSON data ends early."
        case .invalidLength(let length): "The BSON data has an invalid length (\(length))."
        case .invalidType(let type): "The BSON data has an unknown type 0x\(String(type, radix: 16))."
        case .invalidString: "A BSON string is not terminated correctly."
        case .tooDeep: "The BSON document is nested too deeply."
        case .tooLarge(let size): "The BSON document is too large (\(size) bytes)."
        case .invalidKey(let key): "\"\(key)\" cannot be used as a BSON key (it contains a NUL character)."
        }
    }
}

/// Reads and writes BSON bytes. It reads data from a server, so every length is checked against
/// what remains and nesting is bounded; it never traps on malformed input.
public enum BSONCodec {
    /// MongoDB's own maximum is 16 MiB plus room for command overhead; this is a hard stop.
    public static let maximumDocumentSize = 64 * 1024 * 1024
    public static let maximumDepth = 100

    // MARK: Decoding

    public static func decode(_ bytes: [UInt8]) throws -> BSONDocument {
        guard bytes.count <= maximumDocumentSize else { throw BSONError.tooLarge(bytes.count) }
        var reader = Reader(bytes: bytes)
        let document = try reader.readDocument(depth: 0)
        return document
    }

    private struct Reader {
        let bytes: [UInt8]
        var position = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        var remaining: Int { bytes.count - position }

        mutating func byte() throws -> UInt8 {
            guard remaining >= 1 else { throw BSONError.truncated }
            defer { position += 1 }
            return bytes[position]
        }

        mutating func int32() throws -> Int32 {
            guard remaining >= 4 else { throw BSONError.truncated }
            var value: UInt32 = 0
            for offset in 0..<4 { value |= UInt32(bytes[position + offset]) << (8 * UInt32(offset)) }
            position += 4
            return Int32(bitPattern: value)
        }

        mutating func int64() throws -> Int64 {
            guard remaining >= 8 else { throw BSONError.truncated }
            var value: UInt64 = 0
            for offset in 0..<8 { value |= UInt64(bytes[position + offset]) << (8 * UInt64(offset)) }
            position += 8
            return Int64(bitPattern: value)
        }

        mutating func take(_ count: Int) throws -> [UInt8] {
            guard count >= 0, remaining >= count else { throw BSONError.truncated }
            defer { position += count }
            return Array(bytes[position..<(position + count)])
        }

        mutating func cString() throws -> String {
            guard let end = bytes[position...].firstIndex(of: 0) else { throw BSONError.truncated }
            let text = String(decoding: bytes[position..<end], as: UTF8.self)
            position = end + 1
            return text
        }

        mutating func string() throws -> String {
            let length = Int(try int32())
            guard length >= 1 else { throw BSONError.invalidLength(length) }
            let content = try take(length)
            guard content.last == 0 else { throw BSONError.invalidString }
            return String(decoding: content.dropLast(), as: UTF8.self)
        }

        mutating func readDocument(depth: Int) throws -> BSONDocument {
            guard depth <= BSONCodec.maximumDepth else { throw BSONError.tooDeep }
            let start = position
            let size = Int(try int32())
            guard size >= 5, size <= bytes.count - start else { throw BSONError.invalidLength(size) }
            let end = start + size
            var fields: [BSONField] = []
            while true {
                let type = try byte()
                if type == 0 {
                    guard position == end else { throw BSONError.invalidLength(size) }
                    return BSONDocument(fields)
                }
                let key = try cString()
                fields.append(BSONField(key, try readValue(type: type, depth: depth)))
                guard position < end else { throw BSONError.truncated }
            }
        }

        mutating func readValue(type: UInt8, depth: Int) throws -> BSONValue {
            switch type {
            case 0x01:
                return .double(Double(bitPattern: UInt64(bitPattern: try int64())))
            case 0x02:
                return .string(try string())
            case 0x03:
                return .document(try readDocument(depth: depth + 1))
            case 0x04:
                return .array(try readDocument(depth: depth + 1).fields.map(\.value))
            case 0x05:
                let length = Int(try int32())
                guard length >= 0 else { throw BSONError.invalidLength(length) }
                let subtype = try byte()
                var content = try take(length)
                if subtype == 0x02, content.count >= 4 {
                    // The deprecated "old binary" subtype wraps its payload in a second length.
                    content = Array(content.dropFirst(4))
                    return .binary(subtype: 0x02, bytes: content)
                }
                return .binary(subtype: subtype, bytes: content)
            case 0x06:
                return .undefined
            case 0x07:
                return .objectId(try take(12))
            case 0x08:
                return .bool(try byte() != 0)
            case 0x09:
                return .date(milliseconds: try int64())
            case 0x0A:
                return .null
            case 0x0B:
                return .regex(pattern: try cString(), options: try cString())
            case 0x0C:
                return .dbPointer(namespace: try string(), id: try take(12))
            case 0x0D:
                return .javascript(try string())
            case 0x0E:
                return .symbol(try string())
            case 0x0F:
                _ = try int32()
                let code = try string()
                return .javascriptWithScope(code: code, scope: try readDocument(depth: depth + 1))
            case 0x10:
                return .int32(try int32())
            case 0x11:
                let increment = UInt32(bitPattern: try int32())
                let seconds = UInt32(bitPattern: try int32())
                return .timestamp(increment: increment, seconds: seconds)
            case 0x12:
                return .int64(try int64())
            case 0x13:
                guard let value = Decimal128Value(bytes: try take(16)) else { throw BSONError.truncated }
                return .decimal128(value)
            case 0xFF:
                return .minKey
            case 0x7F:
                return .maxKey
            default:
                throw BSONError.invalidType(type)
            }
        }
    }

    // MARK: Encoding

    public static func encode(_ document: BSONDocument) throws -> [UInt8] {
        var output: [UInt8] = []
        try write(document, to: &output, depth: 0)
        guard output.count <= maximumDocumentSize else { throw BSONError.tooLarge(output.count) }
        return output
    }

    private static func write(_ document: BSONDocument, to output: inout [UInt8], depth: Int) throws {
        guard depth <= maximumDepth else { throw BSONError.tooDeep }
        let start = output.count
        output.append(contentsOf: [0, 0, 0, 0])
        for field in document.fields {
            try writeElement(key: field.key, value: field.value, to: &output, depth: depth)
        }
        output.append(0)
        patchLength(&output, at: start)
    }

    private static func patchLength(_ output: inout [UInt8], at start: Int) {
        let length = UInt32(output.count - start)
        for offset in 0..<4 { output[start + offset] = UInt8(truncatingIfNeeded: length >> (8 * UInt32(offset))) }
    }

    private static func writeElement(key: String, value: BSONValue, to output: inout [UInt8], depth: Int) throws {
        func header(_ type: UInt8) throws {
            guard !key.utf8.contains(0) else { throw BSONError.invalidKey(key) }
            output.append(type)
            output.append(contentsOf: key.utf8)
            output.append(0)
        }
        switch value {
        case .double(let number):
            try header(0x01); appendInt64(Int64(bitPattern: number.bitPattern), to: &output)
        case .string(let text):
            try header(0x02); appendString(text, to: &output)
        case .document(let nested):
            try header(0x03); try write(nested, to: &output, depth: depth + 1)
        case .array(let items):
            try header(0x04)
            let document = BSONDocument(items.enumerated().map { BSONField(String($0.offset), $0.element) })
            try write(document, to: &output, depth: depth + 1)
        case .binary(let subtype, let bytes):
            try header(0x05)
            if subtype == 0x02 {
                appendInt32(Int32(bytes.count + 4), to: &output)
                output.append(subtype)
                appendInt32(Int32(bytes.count), to: &output)
            } else {
                appendInt32(Int32(bytes.count), to: &output)
                output.append(subtype)
            }
            output.append(contentsOf: bytes)
        case .undefined:
            try header(0x06)
        case .objectId(let bytes):
            guard bytes.count == 12 else { throw BSONError.invalidLength(bytes.count) }
            try header(0x07); output.append(contentsOf: bytes)
        case .bool(let flag):
            try header(0x08); output.append(flag ? 1 : 0)
        case .date(let milliseconds):
            try header(0x09); appendInt64(milliseconds, to: &output)
        case .null:
            try header(0x0A)
        case .regex(let pattern, let options):
            guard !pattern.utf8.contains(0), !options.utf8.contains(0) else { throw BSONError.invalidKey(pattern) }
            try header(0x0B)
            output.append(contentsOf: pattern.utf8); output.append(0)
            // Options are stored in alphabetical order.
            output.append(contentsOf: String(options.sorted()).utf8); output.append(0)
        case .dbPointer(let namespace, let id):
            guard id.count == 12 else { throw BSONError.invalidLength(id.count) }
            try header(0x0C); appendString(namespace, to: &output); output.append(contentsOf: id)
        case .javascript(let code):
            try header(0x0D); appendString(code, to: &output)
        case .symbol(let text):
            try header(0x0E); appendString(text, to: &output)
        case .javascriptWithScope(let code, let scope):
            try header(0x0F)
            let start = output.count
            output.append(contentsOf: [0, 0, 0, 0])
            appendString(code, to: &output)
            try write(scope, to: &output, depth: depth + 1)
            patchLength(&output, at: start)
        case .int32(let number):
            try header(0x10); appendInt32(number, to: &output)
        case .timestamp(let increment, let seconds):
            try header(0x11)
            appendInt32(Int32(bitPattern: increment), to: &output)
            appendInt32(Int32(bitPattern: seconds), to: &output)
        case .int64(let number):
            try header(0x12); appendInt64(number, to: &output)
        case .decimal128(let decimal):
            try header(0x13); output.append(contentsOf: decimal.bytes)
        case .minKey:
            try header(0xFF)
        case .maxKey:
            try header(0x7F)
        }
    }

    private static func appendInt32(_ value: Int32, to output: inout [UInt8]) {
        let bits = UInt32(bitPattern: value)
        for offset in 0..<4 { output.append(UInt8(truncatingIfNeeded: bits >> (8 * UInt32(offset)))) }
    }

    private static func appendInt64(_ value: Int64, to output: inout [UInt8]) {
        let bits = UInt64(bitPattern: value)
        for offset in 0..<8 { output.append(UInt8(truncatingIfNeeded: bits >> (8 * UInt64(offset)))) }
    }

    private static func appendString(_ text: String, to output: inout [UInt8]) {
        appendInt32(Int32(text.utf8.count + 1), to: &output)
        output.append(contentsOf: text.utf8)
        output.append(0)
    }
}
