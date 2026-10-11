import CryptoKit
import Foundation

public struct HexInspectorField: Sendable, Equatable {
    public var name: String
    public var text: String
    public var available: Bool

    public init(name: String, text: String, available: Bool) {
        self.name = name
        self.text = text
        self.available = available
    }
}

/// Interprets the bytes at the caret. Both byte orders are always present.
public enum HexInspector {
    public static let notEnough = "not enough bytes"

    public static func fields(bytes: [UInt8], littleEndianFirst: Bool) -> [HexInspectorField] {
        var rows: [HexInspectorField] = []
        rows.append(integer(bytes, name: "Int8", width: 1, signed: true, little: true))
        rows.append(integer(bytes, name: "UInt8", width: 1, signed: false, little: true))
        for width in [2, 4, 8] {
            let signedName = "Int\(width * 8)"
            let unsignedName = "UInt\(width * 8)"
            rows.append(contentsOf: endianPair(bytes, name: signedName, width: width, littleFirst: littleEndianFirst) { ordered, little in
                integer(ordered, name: "", width: width, signed: true, little: little).text
            })
            rows.append(contentsOf: endianPair(bytes, name: unsignedName, width: width, littleFirst: littleEndianFirst) { ordered, little in
                integer(ordered, name: "", width: width, signed: false, little: little).text
            })
        }
        rows.append(contentsOf: endianPair(bytes, name: "Float", width: 4, littleFirst: littleEndianFirst) { ordered, little in
            floatText(ordered, little: little)
        })
        rows.append(contentsOf: endianPair(bytes, name: "Double", width: 8, littleFirst: littleEndianFirst) { ordered, little in
            doubleText(ordered, little: little)
        })
        rows.append(character(bytes))
        rows.append(contentsOf: endianPair(bytes, name: "Unix time (s32)", width: 4, littleFirst: littleEndianFirst) { ordered, little in
            unix32(ordered, little: little)
        })
        rows.append(contentsOf: endianPair(bytes, name: "Unix time (s)", width: 8, littleFirst: littleEndianFirst) { ordered, little in
            unix64(ordered, little: little, scale: 1)
        })
        rows.append(contentsOf: endianPair(bytes, name: "Unix time (ms)", width: 8, littleFirst: littleEndianFirst) { ordered, little in
            unix64(ordered, little: little, scale: 1_000)
        })
        rows.append(contentsOf: endianPair(bytes, name: "Mac absolute", width: 8, littleFirst: littleEndianFirst) { ordered, little in
            macAbsolute(ordered, little: little)
        })
        rows.append(uuid(bytes))
        rows.append(binary(bytes))
        return rows
    }

    public static func selectionLength(_ count: Int64) -> (decimal: String, hex: String) {
        ("\(count)", "0x" + String(count, radix: 16).uppercased())
    }

    private static func endianPair(
        _ bytes: [UInt8],
        name: String,
        width: Int,
        littleFirst: Bool,
        value: ([UInt8], Bool) -> String
    ) -> [HexInspectorField] {
        let order: [Bool] = littleFirst ? [true, false] : [false, true]
        return order.map { little in
            let suffix = little ? " LE" : " BE"
            guard bytes.count >= width else {
                return HexInspectorField(name: name + suffix, text: notEnough, available: false)
            }
            let slice = Array(bytes.prefix(width))
            return HexInspectorField(name: name + suffix, text: value(slice, little), available: true)
        }
    }

    private static func integer(_ bytes: [UInt8], name: String, width: Int, signed: Bool, little: Bool) -> HexInspectorField {
        guard bytes.count >= width else {
            return HexInspectorField(name: name, text: notEnough, available: false)
        }
        let slice = Array(bytes.prefix(width))
        let text: String
        if signed {
            text = String(signedValue(slice, little: little))
        } else {
            text = String(unsignedValue(slice, little: little))
        }
        return HexInspectorField(name: name, text: text, available: true)
    }

    private static func unsignedValue(_ bytes: [UInt8], little: Bool) -> UInt64 {
        var value: UInt64 = 0
        if little {
            for (index, byte) in bytes.enumerated() {
                value |= UInt64(byte) << (index * 8)
            }
        } else {
            for byte in bytes {
                value = (value << 8) | UInt64(byte)
            }
        }
        return value
    }

    private static func signedValue(_ bytes: [UInt8], little: Bool) -> Int64 {
        let unsigned = unsignedValue(bytes, little: little)
        let bits = bytes.count * 8
        if bits >= 64 { return Int64(bitPattern: unsigned) }
        let sign = UInt64(1) << (bits - 1)
        if unsigned & sign == 0 { return Int64(unsigned) }
        let mask = (sign << 1) - 1
        return Int64(bitPattern: unsigned | ~mask)
    }

    private static func floatText(_ bytes: [UInt8], little: Bool) -> String {
        let bits = UInt32(truncatingIfNeeded: unsignedValue(Array(bytes.prefix(4)), little: little))
        return format(Double(Float(bitPattern: bits)))
    }

    private static func doubleText(_ bytes: [UInt8], little: Bool) -> String {
        let bits = unsignedValue(Array(bytes.prefix(8)), little: little)
        return format(Double(bitPattern: bits))
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.9g", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func character(_ bytes: [UInt8]) -> HexInspectorField {
        guard let first = bytes.first else {
            return HexInspectorField(name: "Character", text: notEnough, available: false)
        }
        var parts: [String] = []
        if let scalar = utf8Scalar(bytes) {
            parts.append("U+\(String(scalar.value, radix: 16, uppercase: true)) \(Character(scalar))")
        }
        let latin = HexPaneEncoding.latin1.glyph(for: first)
        parts.append("Latin-1 \(latin)")
        return HexInspectorField(name: "Character", text: parts.joined(separator: ", "), available: true)
    }

    private static func utf8Scalar(_ bytes: [UInt8]) -> Unicode.Scalar? {
        guard !bytes.isEmpty else { return nil }
        let needed: Int
        let lead = bytes[0]
        if lead < 0x80 { needed = 1 }
        else if lead & 0xE0 == 0xC0 { needed = 2 }
        else if lead & 0xF0 == 0xE0 { needed = 3 }
        else if lead & 0xF8 == 0xF0 { needed = 4 }
        else { return nil }
        guard bytes.count >= needed else { return nil }
        let data = Data(bytes.prefix(needed))
        guard let text = String(data: data, encoding: .utf8), text.unicodeScalars.count == 1 else { return nil }
        return text.unicodeScalars.first
    }

    private static func unix32(_ bytes: [UInt8], little: Bool) -> String {
        let seconds = Int32(bitPattern: UInt32(truncatingIfNeeded: unsignedValue(Array(bytes.prefix(4)), little: little)))
        return timestamp(Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    private static func unix64(_ bytes: [UInt8], little: Bool, scale: Double) -> String {
        let raw = Int64(bitPattern: unsignedValue(Array(bytes.prefix(8)), little: little))
        return timestamp(Date(timeIntervalSince1970: TimeInterval(raw) / scale))
    }

    private static func macAbsolute(_ bytes: [UInt8], little: Bool) -> String {
        let bits = unsignedValue(Array(bytes.prefix(8)), little: little)
        let seconds = Double(bitPattern: bits)
        return timestamp(Date(timeIntervalSinceReferenceDate: seconds))
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func uuid(_ bytes: [UInt8]) -> HexInspectorField {
        guard bytes.count >= 16 else {
            return HexInspectorField(name: "UUID", text: notEnough, available: false)
        }
        let value = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return HexInspectorField(name: "UUID", text: value.uuidString, available: true)
    }

    private static func binary(_ bytes: [UInt8]) -> HexInspectorField {
        guard let first = bytes.first else {
            return HexInspectorField(name: "Binary", text: notEnough, available: false)
        }
        let shown = bytes.prefix(4)
        let text = shown.map { byte in
            (0..<8).reversed().map { bit in ((byte >> bit) & 1) == 1 ? "1" : "0" }.joined()
        }.joined(separator: " ")
        _ = first
        return HexInspectorField(name: "Binary", text: text, available: true)
    }
}

public enum HexDigest {
    public static func md5(_ source: any HexByteSource, range: Range<Int64>) throws -> String {
        try hash(source, range: range) { Insecure.MD5() }
    }

    public static func sha1(_ source: any HexByteSource, range: Range<Int64>) throws -> String {
        try hash(source, range: range) { Insecure.SHA1() }
    }

    public static func sha256(_ source: any HexByteSource, range: Range<Int64>) throws -> String {
        try hash(source, range: range) { SHA256() }
    }

    private static func hash<Hasher: HashFunction>(
        _ source: any HexByteSource,
        range: Range<Int64>,
        make: () -> Hasher
    ) throws -> String {
        var hasher = make()
        var offset = max(0, range.lowerBound)
        let end = min(max(offset, range.upperBound), source.count)
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while offset < end {
            let want = Int(min(Int64(buffer.count), end - offset))
            let got = try buffer.withUnsafeMutableBytes { raw in
                try source.read(offset..<(offset + Int64(want)), into: raw)
            }
            guard got > 0 else { break }
            hasher.update(data: Data(buffer.prefix(got)))
            offset += Int64(got)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
