import Foundation

/// Shows a protobuf response in the log the way `protoc --decode_raw` would: fields by number, nested
/// messages in braces, and a trailing comment with the other readings of a value. There is no schema,
/// so types are guessed from the wire format. The wire-format decoder follows Hextech's
/// `ProtobufViewerEngine` (itself a port of pawitp/protobuf-decoder), with its overflow traps and
/// signed-value mistakes fixed.
enum HTTPProtobuf {
    /// Bodies above this are left alone: `HTTPClient.formatResponse` runs on the main actor.
    static let maxDecodedBytes = 4 * 1024 * 1024

    private static let maxDepth = 64
    private static let maxFieldNumber = 0x1FFF_FFFF
    private static let maxShownBytes = 64
    private static let maxShownPackedValues = 64

    private static let mediaTypes: Set<String> = [
        "application/protobuf",
        "application/x-protobuf",
        "application/vnd.google.protobuf",
        "application/x-google-protobuf",
        "application/proto",
        "application/grpc",
        "application/grpc+proto",
        "application/grpc-web",
        "application/grpc-web+proto",
        "application/connect+proto",
    ]

    /// `grpc-web-text` is not listed: its body is Base64 text, not protobuf bytes.
    static func isProtobuf(contentType: String?) -> Bool {
        guard let mime = mediaType(of: contentType) else { return false }
        return mediaTypes.contains(mime)
    }

    /// The decoded body, or `nil` when nothing in it decodes (the caller keeps its placeholder).
    static func render(_ data: Data, contentType: String?, grpcEncoding: String? = nil) -> String? {
        guard !data.isEmpty else { return nil }
        guard data.count <= maxDecodedBytes else {
            return "// \(data.count) bytes of protobuf, too large to decode here"
        }
        let bytes = [UInt8](data)
        var lines: [String] = []

        if usesEnvelopes(contentType), let frames = envelopes(in: bytes) {
            for (index, frame) in frames.enumerated() {
                renderFrame(frame, number: index + 1, grpcEncoding: grpcEncoding, into: &lines)
            }
            return lines.joined(separator: "\n")
        }

        let message = decodeMessage(bytes, depth: 0)
        guard !message.fields.isEmpty else { return nil }
        render(message.fields, indent: 0, into: &lines)
        if message.consumed < bytes.count {
            lines.append(leftoverLine(bytes[message.consumed...]))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Content type

    private static func mediaType(of contentType: String?) -> String? {
        guard let contentType else { return nil }
        let essence = contentType
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return essence.isEmpty ? nil : essence
    }

    /// gRPC, gRPC-Web and Connect streams wrap every message in a 5-byte envelope.
    private static func usesEnvelopes(_ contentType: String?) -> Bool {
        guard let mime = mediaType(of: contentType) else { return false }
        return mime.hasPrefix("application/grpc") || mime == "application/connect+proto"
    }

    // MARK: - Envelopes

    private struct Frame {
        let flags: UInt8
        let payload: [UInt8]

        var isCompressed: Bool { flags & 0x01 != 0 }
        /// gRPC-Web trailers (0x80) and the Connect end-of-stream message (0x02).
        var isTrailer: Bool { flags & 0x82 != 0 }
    }

    /// `nil` when the body is not a whole number of well-formed envelopes.
    private static func envelopes(in bytes: [UInt8]) -> [Frame]? {
        var frames: [Frame] = []
        var offset = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 5 else { return nil }
            let flags = bytes[offset]
            guard flags & ~0x83 == 0 else { return nil }
            let length = bytes[offset + 1...offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            offset += 5
            guard length <= bytes.count - offset else { return nil }
            frames.append(Frame(flags: flags, payload: Array(bytes[offset..<offset + length])))
            offset += length
        }
        return frames.isEmpty ? nil : frames
    }

    private static func renderFrame(
        _ frame: Frame,
        number: Int,
        grpcEncoding: String?,
        into lines: inout [String]
    ) {
        let size = frame.payload.count
        if frame.isCompressed {
            let encoding = grpcEncoding.map { " (grpc-encoding: \($0))" } ?? ""
            lines.append("// message \(number): compressed\(encoding), not decoded")
            return
        }
        if frame.isTrailer {
            lines.append("// trailers (\(size) bytes)")
            let text = String(decoding: frame.payload, as: UTF8.self)
            lines.append(contentsOf: text.split(whereSeparator: \.isNewline).map(String.init))
            return
        }
        lines.append("// message \(number) (\(size) bytes)")
        let message = decodeMessage(frame.payload, depth: 0)
        render(message.fields, indent: 0, into: &lines)
        if message.consumed < size {
            lines.append(leftoverLine(frame.payload[message.consumed...]))
        }
    }

    // MARK: - Wire format

    private indirect enum Value {
        case varint(UInt64)
        case fixed32(UInt32)
        case fixed64(UInt64)
        case message([Field])
        case string(String)
        case packed([UInt64])
        case bytes([UInt8])
        case empty
    }

    private struct Field {
        let number: Int
        let value: Value
    }

    /// Reads fields until the bytes run out or one cannot be read; `consumed` is where it stopped.
    private static func decodeMessage(_ bytes: [UInt8], depth: Int) -> (fields: [Field], consumed: Int) {
        var fields: [Field] = []
        var offset = 0
        while offset < bytes.count {
            var cursor = offset
            guard let field = readField(bytes, cursor: &cursor, depth: depth) else { break }
            fields.append(field)
            offset = cursor
        }
        return (fields, offset)
    }

    private static func readField(_ bytes: [UInt8], cursor: inout Int, depth: Int) -> Field? {
        guard let key = readVarint(bytes, cursor: &cursor),
              let number = Int(exactly: key >> 3),
              number >= 1, number <= maxFieldNumber
        else { return nil }

        switch key & 0b111 {
        case 0:
            guard let value = readVarint(bytes, cursor: &cursor) else { return nil }
            return Field(number: number, value: .varint(value))
        case 1:
            guard let raw = readFixed(bytes, cursor: &cursor, count: 8) else { return nil }
            return Field(number: number, value: .fixed64(raw))
        case 2:
            guard let length = readVarint(bytes, cursor: &cursor),
                  let size = Int(exactly: length),
                  size <= bytes.count - cursor
            else { return nil }
            let payload = Array(bytes[cursor..<cursor + size])
            cursor += size
            return Field(number: number, value: classify(payload, depth: depth))
        case 5:
            guard let raw = readFixed(bytes, cursor: &cursor, count: 4) else { return nil }
            return Field(number: number, value: .fixed32(UInt32(truncatingIfNeeded: raw)))
        default:
            // Groups (3, 4) and the unassigned 6 and 7.
            return nil
        }
    }

    /// At most 10 bytes, and the tenth may only carry the top bit of a `UInt64`.
    private static func readVarint(_ bytes: [UInt8], cursor: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var index = cursor
        for position in 0..<10 {
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            index += 1
            if position == 9, byte > 1 { return nil }
            result |= UInt64(byte & 0x7F) << UInt64(position * 7)
            if byte & 0x80 == 0 {
                cursor = index
                return result
            }
        }
        return nil
    }

    private static func readFixed(_ bytes: [UInt8], cursor: inout Int, count: Int) -> UInt64? {
        guard count <= bytes.count - cursor else { return nil }
        var result: UInt64 = 0
        for position in 0..<count {
            result |= UInt64(bytes[cursor + position]) << UInt64(position * 8)
        }
        cursor += count
        return result
    }

    /// A payload is a nested message when every byte decodes; otherwise text, packed varints or bytes.
    private static func classify(_ payload: [UInt8], depth: Int) -> Value {
        if payload.isEmpty { return .empty }
        if depth < maxDepth {
            let nested = decodeMessage(payload, depth: depth + 1)
            if nested.consumed == payload.count, !nested.fields.isEmpty {
                return .message(nested.fields)
            }
        }
        if let text = readableText(payload) { return .string(text) }
        if let values = packedVarints(payload) { return .packed(values) }
        return .bytes(payload)
    }

    /// UTF-8 with no control characters other than tab, line feed and carriage return.
    private static func readableText(_ payload: [UInt8]) -> String? {
        guard let text = String(bytes: payload, encoding: .utf8) else { return nil }
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0D: continue
            case 0..<0x20, 0x7F: return nil
            default: continue
            }
        }
        return text
    }

    private static func packedVarints(_ payload: [UInt8]) -> [UInt64]? {
        var values: [UInt64] = []
        var cursor = 0
        while cursor < payload.count {
            guard let value = readVarint(payload, cursor: &cursor) else { return nil }
            values.append(value)
        }
        return values.isEmpty ? nil : values
    }

    // MARK: - Rendering

    private static func render(_ fields: [Field], indent: Int, into lines: inout [String]) {
        let pad = String(repeating: "  ", count: indent)
        for field in fields {
            let prefix = "\(pad)\(field.number)"
            switch field.value {
            case .message(let children):
                lines.append("\(prefix) {")
                render(children, indent: indent + 1, into: &lines)
                lines.append("\(pad)}")
            case .varint(let value):
                lines.append("\(prefix): \(value)\(comment(varintReadings(value)))")
            case .fixed32(let raw):
                let signed = Int32(bitPattern: raw)
                var readings: [String] = []
                if signed < 0 { readings.append("uint: \(raw)") }
                readings.append("float: \(Float(bitPattern: raw))")
                lines.append("\(prefix): \(signed)\(comment(readings))")
            case .fixed64(let raw):
                let signed = Int64(bitPattern: raw)
                var readings: [String] = []
                if signed < 0 { readings.append("uint: \(raw)") }
                readings.append("double: \(Double(bitPattern: raw))")
                lines.append("\(prefix): \(signed)\(comment(readings))")
            case .string(let text):
                lines.append("\(prefix): \(quoted(text))")
            case .packed(let values):
                lines.append("\(prefix): \(packedText(values))")
            case .bytes(let payload):
                lines.append("\(prefix): \(bytesText(payload))")
            case .empty:
                lines.append("\(prefix): \"\"")
            }
        }
    }

    private static func comment(_ readings: [String]) -> String {
        readings.isEmpty ? "" : "  // " + readings.joined(separator: ", ")
    }

    /// The signed readings of a varint that differ from the unsigned value shown first.
    private static func varintReadings(_ value: UInt64) -> [String] {
        var readings: [String] = []
        let twosComplement = Int64(bitPattern: value)
        if twosComplement < 0 { readings.append("int64: \(twosComplement)") }
        let zigzag = Int64(bitPattern: (value >> 1) ^ (0 &- (value & 1)))
        if UInt64(bitPattern: zigzag) != value { readings.append("sint: \(zigzag)") }
        return readings
    }

    private static func quoted(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    private static func packedText(_ values: [UInt64]) -> String {
        let shown = values.prefix(maxShownPackedValues).map(String.init).joined(separator: ", ")
        return values.count > maxShownPackedValues ? "[\(shown), …]" : "[\(shown)]"
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private static func bytesText(_ payload: [UInt8]) -> String {
        guard payload.count > maxShownBytes else { return "<\(hex(payload))>" }
        return "<\(hex(payload.prefix(maxShownBytes))) … (\(payload.count) bytes)>"
    }

    private static func leftoverLine(_ rest: ArraySlice<UInt8>) -> String {
        let shown = rest.count > maxShownBytes ? hex(rest.prefix(maxShownBytes)) + " …" : hex(rest)
        return "// \(rest.count) bytes could not be decoded: \(shown)"
    }
}
