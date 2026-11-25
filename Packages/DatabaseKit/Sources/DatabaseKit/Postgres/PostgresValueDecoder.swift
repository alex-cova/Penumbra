import DatabaseCore
import Foundation

/// How much of a large value is kept in a result. The rest is fetched on demand by the inspector.
public struct ValueLimits: Sendable, Equatable {
    /// Text, JSON and similar longer than this many bytes are stored as a `.truncated` preview.
    public var maxTextBytes: Int
    /// Binary values keep only this many leading bytes (plus their full length).
    public var binaryPrefix: Int

    public init(maxTextBytes: Int = 65_536, binaryPrefix: Int = 64) {
        self.maxTextBytes = maxTextBytes
        self.binaryPrefix = binaryPrefix
    }

    public static let standard = ValueLimits()
}

/// Turns one PostgreSQL result cell (type OID, wire format, raw bytes) into a `DatabaseValue`.
///
/// PostgresNIO asks the server for binary results, so a cell is the type's wire encoding, not
/// text. Reading those bytes as UTF-8 (which is what `decode(String.self)` does for types it does
/// not special-case) is what showed integers, floats, dates and arrays as garbage. This decoder
/// reads each type's binary layout directly, so it is a pure function and is tested without a
/// server.
///
/// Types the server defines itself (domains, enums, extension types such as PostGIS `geometry`)
/// have OIDs this table does not know. They fall back to text when the bytes are valid printable
/// UTF-8 (which is how enums arrive) and to a bounded binary value otherwise.
public enum PostgresValueDecoder {
    public static func decode(
        oid: UInt32, isBinary: Bool, bytes: [UInt8]?, limits: ValueLimits = .standard
    ) -> DatabaseValue {
        // NULL has no bytes at all. A zero-length value is a real, empty value (audit F-22).
        guard let bytes else { return .null }
        if !isBinary {
            return decodeText(oid: oid, bytes: bytes, limits: limits)
        }
        if let value = decodeBinary(oid: oid, bytes: bytes, limits: limits) {
            return value
        }
        return fallback(bytes: bytes, limits: limits)
    }

    // MARK: - Binary

    private static func decodeBinary(oid: UInt32, bytes: [UInt8], limits: ValueLimits) -> DatabaseValue? {
        var reader = Reader(bytes: bytes)
        switch oid {
        case Oid.bool:
            guard bytes.count == 1 else { return nil }
            return .bool(bytes[0] != 0)
        case Oid.int2:
            guard bytes.count == 2, let value = reader.int16() else { return nil }
            return .int(Int64(value))
        case Oid.int4:
            guard bytes.count == 4, let value = reader.int32() else { return nil }
            return .int(Int64(value))
        case Oid.int8:
            guard bytes.count == 8, let value = reader.int64() else { return nil }
            return .int(value)
        case Oid.oid, Oid.xid, Oid.cid, Oid.regproc, Oid.regclass, Oid.regtype:
            guard bytes.count == 4, let value = reader.int32() else { return nil }
            return .uint(UInt64(UInt32(bitPattern: value)))
        case Oid.float4:
            guard bytes.count == 4, let bits = reader.int32() else { return nil }
            // A float4 shows its own shortest digits (0.1, not 0.10000000149011612).
            let single = Float(bitPattern: UInt32(bitPattern: bits))
            return .double(Double(single.description) ?? Double(single))
        case Oid.float8:
            guard bytes.count == 8, let bits = reader.int64() else { return nil }
            return .double(Double(bitPattern: UInt64(bitPattern: bits)))
        case Oid.numeric:
            return decodeNumeric(bytes).map { .decimal($0) }
        case Oid.money:
            guard bytes.count == 8, let cents = reader.int64() else { return nil }
            return .decimal(decimalText(unscaled: cents, scale: 2))
        case Oid.text, Oid.varchar, Oid.bpchar, Oid.name, Oid.xml, Oid.char:
            return text(bytes, limits: limits)
        case Oid.json:
            return json(bytes, limits: limits)
        case Oid.jsonb:
            // One version byte (1), then the JSON text.
            guard bytes.first == 1 else { return nil }
            return json(Array(bytes.dropFirst()), limits: limits)
        case Oid.bytea:
            return .bytes(count: bytes.count, prefix: Array(bytes.prefix(limits.binaryPrefix)))
        case Oid.uuid:
            guard bytes.count == 16 else { return nil }
            return .uuid(uuidText(bytes))
        case Oid.date:
            guard bytes.count == 4, let days = reader.int32() else { return nil }
            return .temporal(dateText(daysSince2000: days), .date)
        case Oid.time:
            guard bytes.count == 8, let micros = reader.int64() else { return nil }
            return .temporal(timeText(micros: micros), .time)
        case Oid.timetz:
            guard bytes.count == 12, let micros = reader.int64(), let west = reader.int32() else { return nil }
            return .temporal(timeText(micros: micros) + zoneText(secondsWest: Int(west)), .timeWithZone)
        case Oid.timestamp:
            guard bytes.count == 8, let micros = reader.int64() else { return nil }
            return .temporal(timestampText(micros: micros, withZone: false), .timestamp)
        case Oid.timestamptz:
            guard bytes.count == 8, let micros = reader.int64() else { return nil }
            return .temporal(timestampText(micros: micros, withZone: true), .timestampWithZone)
        case Oid.interval:
            guard bytes.count == 16, let micros = reader.int64(), let days = reader.int32(),
                  let months = reader.int32() else { return nil }
            return .temporal(intervalText(micros: micros, days: Int(days), months: Int(months)), .interval)
        case Oid.inet, Oid.cidr:
            return inetText(bytes).map { .text($0) }
        case Oid.macaddr, Oid.macaddr8:
            guard bytes.count == 6 || bytes.count == 8 else { return nil }
            return .text(bytes.map { hexByte($0) }.joined(separator: ":"))
        case Oid.bit, Oid.varbit:
            return bitString(bytes).map { .text($0) }
        default:
            if Oid.arrayOids.contains(oid) {
                return decodeArray(bytes, limits: limits)
            }
            return nil
        }
    }

    private static func text(_ bytes: [UInt8], limits: ValueLimits) -> DatabaseValue {
        guard bytes.count > limits.maxTextBytes else {
            return .text(String(decoding: bytes, as: UTF8.self))
        }
        return truncatedText(bytes, limits: limits)
    }

    private static func json(_ bytes: [UInt8], limits: ValueLimits) -> DatabaseValue {
        guard bytes.count > limits.maxTextBytes else {
            return .json(String(decoding: bytes, as: UTF8.self))
        }
        return truncatedText(bytes, limits: limits)
    }

    private static func truncatedText(_ bytes: [UInt8], limits: ValueLimits) -> DatabaseValue {
        // Cut on a character boundary: decoding with replacement may split one, so back up to a
        // lead byte first.
        var end = limits.maxTextBytes
        while end > 0, (bytes[end] & 0xC0) == 0x80 { end -= 1 }
        return .truncated(preview: String(decoding: bytes[0..<end], as: UTF8.self), fullCount: bytes.count)
    }

    /// Unknown OID: an enum label or other textual type arrives as UTF-8; anything else is kept as
    /// a bounded binary value instead of being shown as garbage.
    private static func fallback(bytes: [UInt8], limits: ValueLimits) -> DatabaseValue {
        if let string = String(bytes: bytes, encoding: .utf8),
           string.unicodeScalars.allSatisfy({ $0.value >= 0x20 || $0 == "\n" || $0 == "\t" || $0 == "\r" })
        {
            return text(bytes, limits: limits)
        }
        return .bytes(count: bytes.count, prefix: Array(bytes.prefix(limits.binaryPrefix)))
    }

    // MARK: - Text format

    private static func decodeText(oid: UInt32, bytes: [UInt8], limits: ValueLimits) -> DatabaseValue {
        let string = String(decoding: bytes, as: UTF8.self)
        switch oid {
        case Oid.bool:
            return .bool(string == "t" || string == "true")
        case Oid.int2, Oid.int4, Oid.int8:
            return Int64(string).map { .int($0) } ?? .text(string)
        case Oid.float4, Oid.float8:
            return Double(string).map { .double($0) } ?? .text(string)
        case Oid.numeric, Oid.money:
            return .decimal(string)
        case Oid.json, Oid.jsonb:
            return bytes.count > limits.maxTextBytes ? truncatedText(bytes, limits: limits) : .json(string)
        case Oid.uuid:
            return .uuid(string)
        case Oid.date:
            return .temporal(string, .date)
        case Oid.time:
            return .temporal(string, .time)
        case Oid.timetz:
            return .temporal(string, .timeWithZone)
        case Oid.timestamp:
            return .temporal(string, .timestamp)
        case Oid.timestamptz:
            return .temporal(string, .timestampWithZone)
        case Oid.interval:
            return .temporal(string, .interval)
        case Oid.bytea:
            if string.hasPrefix("\\x") {
                let hex = Array(string.utf8.dropFirst(2))
                var parsed: [UInt8] = []
                parsed.reserveCapacity(hex.count / 2)
                var index = 0
                while index + 1 < hex.count, let high = hexValue(hex[index]), let low = hexValue(hex[index + 1]) {
                    parsed.append(UInt8(high << 4 | low))
                    index += 2
                }
                return .bytes(count: parsed.count, prefix: Array(parsed.prefix(limits.binaryPrefix)))
            }
            return .bytes(count: bytes.count, prefix: Array(bytes.prefix(limits.binaryPrefix)))
        default:
            return text(bytes, limits: limits)
        }
    }

    // MARK: - Arrays

    /// `ndim, hasNull, elementOid, (length, lowerBound) × ndim, then (length, bytes) per element`.
    private static func decodeArray(_ bytes: [UInt8], limits: ValueLimits) -> DatabaseValue? {
        var reader = Reader(bytes: bytes)
        guard let ndim = reader.int32(), reader.int32() != nil, let elementOid = reader.int32() else { return nil }
        guard ndim >= 0, ndim <= 6 else { return nil }
        if ndim == 0 { return .array([]) }
        var dimensions: [Int] = []
        for _ in 0..<Int(ndim) {
            guard let length = reader.int32(), reader.int32() != nil, length >= 0 else { return nil }
            dimensions.append(Int(length))
        }
        // The server controls these lengths: multiply without trapping on overflow, and refuse an
        // absurd count before allocating (every element needs at least four bytes).
        var total = 1
        for dimension in dimensions {
            let (product, overflow) = total.multipliedReportingOverflow(by: dimension)
            guard !overflow else { return nil }
            total = product
        }
        guard total <= reader.remaining / 4 else { return nil }
        var flat: [DatabaseValue] = []
        flat.reserveCapacity(total)
        for _ in 0..<total {
            guard let length = reader.int32() else { return nil }
            if length < 0 {
                flat.append(.null)
                continue
            }
            guard let slice = reader.read(Int(length)) else { return nil }
            flat.append(decode(oid: UInt32(bitPattern: elementOid), isBinary: true, bytes: slice, limits: limits))
        }
        var position = 0
        func build(_ level: Int) -> DatabaseValue {
            var items: [DatabaseValue] = []
            for _ in 0..<dimensions[level] {
                if level == dimensions.count - 1 {
                    items.append(flat[position])
                    position += 1
                } else {
                    items.append(build(level + 1))
                }
            }
            return .array(items)
        }
        return build(0)
    }

    // MARK: - Numeric

    /// `numeric` is `ndigits, weight, sign, dscale` followed by base-10000 digits. Rebuilt as an
    /// exact decimal string, never through `Double` or `Decimal`.
    static func decodeNumeric(_ bytes: [UInt8]) -> String? {
        var reader = Reader(bytes: bytes)
        guard let ndigits = reader.int16(), let weight = reader.int16(), let sign = reader.int16(),
              let dscale = reader.int16(), ndigits >= 0, dscale >= 0 else { return nil }
        switch UInt16(bitPattern: sign) {
        case 0xC000: return "NaN"
        case 0xD000: return "Infinity"
        case 0xF000: return "-Infinity"
        case 0x0000, 0x4000: break
        default: return nil
        }
        var digits: [Int] = []
        for _ in 0..<Int(ndigits) {
            guard let digit = reader.int16(), digit >= 0, digit < 10_000 else { return nil }
            digits.append(Int(digit))
        }
        func group(_ digit: Int) -> String {
            let text = String(digit)
            return String(repeating: "0", count: 4 - text.count) + text
        }
        var result = ""
        let integerGroups = Int(weight) >= 0 ? Int(weight) + 1 : 0
        if integerGroups == 0 {
            result = "0"
        } else {
            for index in 0..<integerGroups {
                let digit = index < digits.count ? digits[index] : 0
                result += index == 0 ? String(digit) : group(digit)
            }
        }
        if dscale > 0 {
            var fraction = ""
            for offset in 1...((Int(dscale) + 3) / 4) {
                let index = Int(weight) + offset
                fraction += group(index >= 0 && index < digits.count ? digits[index] : 0)
            }
            result += "." + fraction.prefix(Int(dscale))
        }
        let negative = UInt16(bitPattern: sign) == 0x4000
        return negative && result.contains(where: { $0 != "0" && $0 != "." }) ? "-" + result : result
    }

    private static func decimalText(unscaled: Int64, scale: Int) -> String {
        let negative = unscaled < 0
        var digits = String(unscaled.magnitude)
        if digits.count <= scale { digits = String(repeating: "0", count: scale - digits.count + 1) + digits }
        let split = digits.index(digits.endIndex, offsetBy: -scale)
        return (negative ? "-" : "") + digits[..<split] + "." + digits[split...]
    }

    // MARK: - Dates and times

    private static let microsPerSecond: Int64 = 1_000_000
    private static let microsPerDay: Int64 = 86_400 * 1_000_000

    static func dateText(daysSince2000: Int32) -> String {
        if daysSince2000 == Int32.max { return "infinity" }
        if daysSince2000 == Int32.min { return "-infinity" }
        return civilText(daysSince2000: Int(daysSince2000))
    }

    static func timestampText(micros: Int64, withZone: Bool) -> String {
        if micros == Int64.max { return "infinity" }
        if micros == Int64.min { return "-infinity" }
        let days = micros >= 0 ? micros / microsPerDay : -((-micros + microsPerDay - 1) / microsPerDay)
        let timeOfDay = micros - days * microsPerDay
        let text = civilText(daysSince2000: Int(days)), time = timeText(micros: timeOfDay)
        // The result carries an instant, not a zone: show it in UTC and say so.
        if text.hasSuffix(" BC") {
            return String(text.dropLast(3)) + " " + time + (withZone ? "+00" : "") + " BC"
        }
        return text + " " + time + (withZone ? "+00" : "")
    }

    static func timeText(micros: Int64) -> String {
        let totalSeconds = micros / microsPerSecond
        let fraction = micros % microsPerSecond
        var text = pad(Int(totalSeconds / 3600)) + ":" + pad(Int(totalSeconds / 60 % 60)) + ":" + pad(Int(totalSeconds % 60))
        if fraction != 0 {
            var digits = String(fraction)
            digits = String(repeating: "0", count: 6 - digits.count) + digits
            while digits.hasSuffix("0") { digits.removeLast() }
            text += "." + digits
        }
        return text
    }

    private static func zoneText(secondsWest: Int) -> String {
        let east = -secondsWest
        let sign = east < 0 ? "-" : "+"
        let magnitude = abs(east)
        let hours = magnitude / 3600, minutes = magnitude / 60 % 60
        return sign + pad(hours) + (minutes != 0 ? ":" + pad(minutes) : "")
    }

    static func intervalText(micros: Int64, days: Int, months: Int) -> String {
        var parts: [String] = []
        let years = months / 12, remainingMonths = months % 12
        // PostgreSQL pluralizes unless the count is exactly 1: "-1 days", "1 day".
        if years != 0 { parts.append("\(years) year\(years == 1 ? "" : "s")") }
        if remainingMonths != 0 { parts.append("\(remainingMonths) mon\(remainingMonths == 1 ? "" : "s")") }
        if days != 0 { parts.append("\(days) day\(days == 1 ? "" : "s")") }
        if micros != 0 {
            parts.append((micros < 0 ? "-" : "") + timeText(micros: abs(micros)))
        }
        return parts.isEmpty ? "00:00:00" : parts.joined(separator: " ")
    }

    /// Proleptic Gregorian date from days since 2000-01-01 (Howard Hinnant's civil-from-days).
    private static func civilText(daysSince2000: Int) -> String {
        let z = daysSince2000 + 10_957 + 719_468  // days since 1970-01-01, shifted to 0000-03-01
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        if year <= 0 {
            return pad(1 - year, width: 4) + "-" + pad(month) + "-" + pad(day) + " BC"
        }
        return pad(year, width: 4) + "-" + pad(month) + "-" + pad(day)
    }

    private static func pad(_ value: Int, width: Int = 2) -> String {
        let text = String(value)
        return text.count >= width ? text : String(repeating: "0", count: width - text.count) + text
    }

    // MARK: - Small formats

    private static func uuidText(_ bytes: [UInt8]) -> String {
        let hex = bytes.map { hexByte($0) }
        return hex[0..<4].joined() + "-" + hex[4..<6].joined() + "-" + hex[6..<8].joined()
            + "-" + hex[8..<10].joined() + "-" + hex[10..<16].joined()
    }

    private static func hexByte(_ byte: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }

    private static func hexValue(_ character: UInt8) -> Int? {
        switch character {
        case 48...57: Int(character) - 48
        case 97...102: Int(character) - 87
        case 65...70: Int(character) - 55
        default: nil
        }
    }

    /// `family, bits, isCidr, addressLength, address`. `inet` omits `/32` or `/128`; `cidr` never does.
    private static func inetText(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 4 else { return nil }
        let family = bytes[0], bits = Int(bytes[1]), isCidr = bytes[2] != 0, length = Int(bytes[3])
        guard bytes.count == 4 + length else { return nil }
        let address = Array(bytes[4...])
        let text: String
        let fullLength: Int
        switch (family, length) {
        case (2, 4):
            text = address.map { String($0) }.joined(separator: ".")
            fullLength = 32
        case (3, 16):
            text = ipv6Text(address)
            fullLength = 128
        default:
            return nil
        }
        return isCidr || bits != fullLength ? text + "/\(bits)" : text
    }

    private static func ipv6Text(_ address: [UInt8]) -> String {
        var groups: [UInt16] = []
        for index in stride(from: 0, to: 16, by: 2) {
            groups.append(UInt16(address[index]) << 8 | UInt16(address[index + 1]))
        }
        // Collapse the longest run (length >= 2) of zero groups into "::".
        var bestStart = -1, bestLength = 0, start = -1
        for index in 0...8 {
            // Index 8 is a sentinel non-zero group that closes a trailing run.
            let group: UInt16 = index < 8 ? groups[index] : 1
            if group == 0 {
                if start < 0 { start = index }
            } else if start >= 0 {
                if index - start > bestLength { bestStart = start; bestLength = index - start }
                start = -1
            }
        }
        let hex = groups.map { String($0, radix: 16) }
        guard bestLength >= 2 else { return hex.joined(separator: ":") }
        let head = hex[0..<bestStart].joined(separator: ":")
        let tail = hex[(bestStart + bestLength)...].joined(separator: ":")
        return head + "::" + tail
    }

    /// `bit`/`varbit`: a 32-bit bit count, then the bits packed most-significant first.
    private static func bitString(_ bytes: [UInt8]) -> String? {
        var reader = Reader(bytes: bytes)
        guard let count = reader.int32(), count >= 0, bytes.count - 4 >= (Int(count) + 7) / 8 else { return nil }
        var result = ""
        for index in 0..<Int(count) {
            let byte = bytes[4 + index / 8]
            result.append((byte >> (7 - UInt8(index % 8))) & 1 == 1 ? "1" : "0")
        }
        return result
    }

    // MARK: - Reading

    private struct Reader {
        let bytes: [UInt8]
        var position = 0

        var remaining: Int { bytes.count - position }

        mutating func read(_ count: Int) -> [UInt8]? {
            guard count >= 0, remaining >= count else { return nil }
            defer { position += count }
            return Array(bytes[position..<(position + count)])
        }

        mutating func int16() -> Int16? {
            guard remaining >= 2 else { return nil }
            defer { position += 2 }
            return Int16(bitPattern: UInt16(bytes[position]) << 8 | UInt16(bytes[position + 1]))
        }

        mutating func int32() -> Int32? {
            guard remaining >= 4 else { return nil }
            var value: UInt32 = 0
            for offset in 0..<4 { value = value << 8 | UInt32(bytes[position + offset]) }
            position += 4
            return Int32(bitPattern: value)
        }

        mutating func int64() -> Int64? {
            guard remaining >= 8 else { return nil }
            var value: UInt64 = 0
            for offset in 0..<8 { value = value << 8 | UInt64(bytes[position + offset]) }
            position += 8
            return Int64(bitPattern: value)
        }
    }

    // MARK: - Type OIDs

    /// Built-in type OIDs (`pg_type`), which are stable across versions.
    enum Oid {
        static let bool: UInt32 = 16, bytea: UInt32 = 17, char: UInt32 = 18, name: UInt32 = 19
        static let int8: UInt32 = 20, int2: UInt32 = 21, int4: UInt32 = 23, text: UInt32 = 25
        static let oid: UInt32 = 26, xid: UInt32 = 28, cid: UInt32 = 29
        static let regproc: UInt32 = 24, regclass: UInt32 = 2205, regtype: UInt32 = 2206
        static let json: UInt32 = 114, xml: UInt32 = 142
        static let float4: UInt32 = 700, float8: UInt32 = 701, money: UInt32 = 790
        static let macaddr: UInt32 = 829, inet: UInt32 = 869, cidr: UInt32 = 650, macaddr8: UInt32 = 774
        static let bpchar: UInt32 = 1042, varchar: UInt32 = 1043
        static let date: UInt32 = 1082, time: UInt32 = 1083, timestamp: UInt32 = 1114
        static let timestamptz: UInt32 = 1184, interval: UInt32 = 1186, timetz: UInt32 = 1266
        static let bit: UInt32 = 1560, varbit: UInt32 = 1562, numeric: UInt32 = 1700
        static let uuid: UInt32 = 2950, jsonb: UInt32 = 3802

        /// Array types whose element type is one of the above (or another built-in).
        static let arrayOids: Set<UInt32> = [
            143, 199, 629, 651, 719, 775, 791, 1000, 1001, 1002, 1003, 1005, 1006, 1007, 1008,
            1009, 1010, 1011, 1012, 1013, 1014, 1015, 1016, 1017, 1019, 1020, 1021, 1022, 1027,
            1028, 1034, 1040, 1041, 1115, 1182, 1183, 1185, 1187, 1231, 1263, 1270, 1561, 1563,
            2201, 2207, 2208, 2209, 2210, 2211, 2287, 2951, 3221, 3807,
        ]
    }

    /// A readable name for a built-in type OID, for column headers and the type indicator.
    public static func typeName(oid: UInt32) -> String {
        names[oid] ?? (Oid.arrayOids.contains(oid) ? "array" : "oid \(oid)")
    }

    private static let names: [UInt32: String] = [
        16: "bool", 17: "bytea", 18: "char", 19: "name", 20: "int8", 21: "int2", 23: "int4",
        25: "text", 26: "oid", 114: "json", 142: "xml", 650: "cidr", 700: "float4", 701: "float8",
        774: "macaddr8", 790: "money", 829: "macaddr", 869: "inet", 1042: "bpchar",
        1043: "varchar", 1082: "date", 1083: "time", 1114: "timestamp", 1184: "timestamptz",
        1186: "interval", 1266: "timetz", 1560: "bit", 1562: "varbit", 1700: "numeric",
        2950: "uuid", 3802: "jsonb",
    ]
}
