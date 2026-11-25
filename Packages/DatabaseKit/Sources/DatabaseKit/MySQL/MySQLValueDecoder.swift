import DatabaseCore
import Foundation

/// Turns MySQL text and prepared-statement cells into a `DatabaseValue`.
///
/// The text protocol sends every value as bytes of text, so the column's type code, its
/// `UNSIGNED` flag and its character set decide what the bytes mean. The character set is what
/// tells a `TEXT` column (a blob type with a text charset) from a `BLOB` (charset 63, `binary`);
/// the old display code guessed this by trying to read the bytes as UTF-8.
///
/// Pure and driver-free, so it is tested without a server.
public enum MySQLValueDecoder {
    /// MySQL's `binary` pseudo character set: raw bytes, not text.
    public static let binaryCharset: UInt16 = 63

    public static func decode(
        typeCode: UInt8, isUnsigned: Bool, charset: UInt16, bytes: [UInt8]?,
        limits: ValueLimits = .standard, binaryProtocol: Bool = false
    ) -> DatabaseValue {
        guard let bytes else { return .null }
        if binaryProtocol, let value = decodeFixedWidth(typeCode, isUnsigned: isUnsigned, bytes: bytes) {
            return value
        }
        let isBinary = charset == binaryCharset
        switch typeCode {
        case Code.tiny, Code.short, Code.long, Code.longlong, Code.int24, Code.year:
            let text = String(decoding: bytes, as: UTF8.self)
            if isUnsigned, let value = UInt64(text) {
                return value <= UInt64(Int64.max) ? .int(Int64(value)) : .uint(value)
            }
            if let value = Int64(text) { return .int(value) }
            return .text(text)
        case Code.decimal, Code.newdecimal:
            return .decimal(String(decoding: bytes, as: UTF8.self))
        case Code.float, Code.double:
            let text = String(decoding: bytes, as: UTF8.self)
            return Double(text).map { .double($0) } ?? .text(text)
        case Code.date, Code.newdate:
            return .temporal(String(decoding: bytes, as: UTF8.self), .date)
        case Code.time, Code.time2:
            return .temporal(String(decoding: bytes, as: UTF8.self), .time)
        case Code.datetime, Code.datetime2:
            return .temporal(String(decoding: bytes, as: UTF8.self), .timestamp)
        case Code.timestamp, Code.timestamp2:
            // A MySQL TIMESTAMP is stored in UTC and shown in the session time zone, with no
            // zone in the text. It is not marked "with zone" because the text carries none.
            return .temporal(String(decoding: bytes, as: UTF8.self), .timestamp)
        case Code.json:
            return text(bytes, limits: limits, json: true)
        case Code.bit, Code.geometry:
            return binary(bytes, limits: limits)
        case Code.tinyBlob, Code.mediumBlob, Code.longBlob, Code.blob,
             Code.varchar, Code.varString, Code.string:
            return isBinary ? binary(bytes, limits: limits) : text(bytes, limits: limits, json: false)
        case Code.enumeration, Code.set:
            return .text(String(decoding: bytes, as: UTF8.self))
        default:
            return isBinary ? binary(bytes, limits: limits) : text(bytes, limits: limits, json: false)
        }
    }

    private static func decodeFixedWidth(_ type: UInt8, isUnsigned: Bool, bytes: [UInt8]) -> DatabaseValue? {
        func littleEndian(_ offset: Int, _ length: Int) -> UInt64 {
            bytes.dropFirst(offset).prefix(length).enumerated().reduce(0) { value, byte in
                value | UInt64(byte.element) << (byte.offset * 8)
            }
        }
        switch (type, bytes.count) {
        case (Code.tiny, 1), (Code.short, 2), (Code.year, 2),
             (Code.long, 4), (Code.int24, 4), (Code.longlong, 8):
            let bits = littleEndian(0, bytes.count)
            if isUnsigned || type == Code.year {
                return Int64(exactly: bits).map(DatabaseValue.int) ?? .uint(bits)
            }
            let shift = 64 - bytes.count * 8
            return .int(Int64(bitPattern: bits << shift) >> shift)
        case (Code.float, 4): return .double(Double(Float(bitPattern: UInt32(littleEndian(0, 4)))))
        case (Code.double, 8): return .double(Double(bitPattern: littleEndian(0, 8)))
        case (Code.date, 0), (Code.newdate, 0): return .temporal("0000-00-00", .date)
        case (Code.date, 4), (Code.newdate, 4):
            return .temporal(String(format: "%04d-%02d-%02d", Int(littleEndian(0, 2)), Int(bytes[2]), Int(bytes[3])), .date)
        case (Code.datetime, _), (Code.datetime2, _), (Code.timestamp, _), (Code.timestamp2, _):
            let date = bytes.count >= 4
                ? String(format: "%04d-%02d-%02d", Int(littleEndian(0, 2)), Int(bytes[2]), Int(bytes[3]))
                : "0000-00-00"
            let time = bytes.count >= 7
                ? String(format: "%02d:%02d:%02d", Int(bytes[4]), Int(bytes[5]), Int(bytes[6]))
                : "00:00:00"
            let fraction = bytes.count == 11 ? String(format: ".%06d", Int(littleEndian(7, 4))) : ""
            return .temporal("\(date) \(time)\(fraction)", .timestamp)
        case (Code.time, 0), (Code.time2, 0): return .temporal("00:00:00", .time)
        case (Code.time, 8), (Code.time, 12), (Code.time2, 8), (Code.time2, 12):
            let hours = 24 * Int(littleEndian(1, 4)) + Int(bytes[5])
            let time = String(format: "%02d:%02d:%02d", hours, Int(bytes[6]), Int(bytes[7]))
            let fraction = bytes.count == 12 ? String(format: ".%06d", Int(littleEndian(8, 4))) : ""
            return .temporal((bytes[0] == 0 ? "" : "-") + time + fraction, .time)
        default: return nil
        }
    }

    /// A readable name for a column type, for headers and the type indicator.
    public static func typeName(typeCode: UInt8, isUnsigned: Bool, charset: UInt16) -> String {
        let isBinary = charset == binaryCharset
        let base: String
        switch typeCode {
        case Code.tiny: base = "tinyint"
        case Code.short: base = "smallint"
        case Code.int24: base = "mediumint"
        case Code.long: base = "int"
        case Code.longlong: base = "bigint"
        case Code.year: base = "year"
        case Code.decimal, Code.newdecimal: base = "decimal"
        case Code.float: base = "float"
        case Code.double: base = "double"
        case Code.date, Code.newdate: base = "date"
        case Code.time, Code.time2: base = "time"
        case Code.datetime, Code.datetime2: base = "datetime"
        case Code.timestamp, Code.timestamp2: base = "timestamp"
        case Code.json: base = "json"
        case Code.bit: base = "bit"
        case Code.geometry: base = "geometry"
        case Code.enumeration: base = "enum"
        case Code.set: base = "set"
        case Code.tinyBlob: base = isBinary ? "tinyblob" : "tinytext"
        case Code.mediumBlob: base = isBinary ? "mediumblob" : "mediumtext"
        case Code.longBlob: base = isBinary ? "longblob" : "longtext"
        case Code.blob: base = isBinary ? "blob" : "text"
        case Code.varchar, Code.varString: base = isBinary ? "varbinary" : "varchar"
        case Code.string: base = isBinary ? "binary" : "char"
        default: base = "type \(typeCode)"
        }
        let integers: Set<UInt8> = [Code.tiny, Code.short, Code.int24, Code.long, Code.longlong]
        return isUnsigned && integers.contains(typeCode) ? base + " unsigned" : base
    }

    private static func text(_ bytes: [UInt8], limits: ValueLimits, json: Bool) -> DatabaseValue {
        guard bytes.count > limits.maxTextBytes else {
            let string = String(decoding: bytes, as: UTF8.self)
            return json ? .json(string) : .text(string)
        }
        var end = limits.maxTextBytes
        while end > 0, (bytes[end] & 0xC0) == 0x80 { end -= 1 }
        return .truncated(preview: String(decoding: bytes[0..<end], as: UTF8.self), fullCount: bytes.count)
    }

    private static func binary(_ bytes: [UInt8], limits: ValueLimits) -> DatabaseValue {
        .bytes(count: bytes.count, prefix: Array(bytes.prefix(limits.binaryPrefix)))
    }

    /// MySQL wire type codes (`enum_field_types`).
    enum Code {
        static let decimal: UInt8 = 0x00, tiny: UInt8 = 0x01, short: UInt8 = 0x02
        static let long: UInt8 = 0x03, float: UInt8 = 0x04, double: UInt8 = 0x05
        static let timestamp: UInt8 = 0x07, longlong: UInt8 = 0x08, int24: UInt8 = 0x09
        static let date: UInt8 = 0x0A, time: UInt8 = 0x0B, datetime: UInt8 = 0x0C
        static let year: UInt8 = 0x0D, newdate: UInt8 = 0x0E, varchar: UInt8 = 0x0F
        static let bit: UInt8 = 0x10, timestamp2: UInt8 = 0x11, datetime2: UInt8 = 0x12
        static let time2: UInt8 = 0x13, json: UInt8 = 0xF5, newdecimal: UInt8 = 0xF6
        static let enumeration: UInt8 = 0xF7, set: UInt8 = 0xF8, tinyBlob: UInt8 = 0xF9
        static let mediumBlob: UInt8 = 0xFA, longBlob: UInt8 = 0xFB, blob: UInt8 = 0xFC
        static let varString: UInt8 = 0xFD, string: UInt8 = 0xFE, geometry: UInt8 = 0xFF
    }
}
