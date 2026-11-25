import Foundation

public enum ExtendedJSONError: Error, Equatable, LocalizedError {
    case syntax(String, offset: Int)
    case invalidWrapper(String)
    case tooDeep

    public var errorDescription: String? {
        switch self {
        case .syntax(let message, let offset): "Invalid JSON at character \(offset): \(message)"
        case .invalidWrapper(let message): message
        case .tooDeep: "The JSON is nested too deeply."
        }
    }

    /// Where in the text the problem is, for underlining it in the editor.
    public var offset: Int? {
        if case .syntax(_, let offset) = self { return offset }
        return nil
    }
}

/// MongoDB Extended JSON v2.
///
/// *Canonical* keeps every type exactly (`{"$numberInt": "1"}`, `{"$numberLong": "1"}`,
/// `{"$numberDouble": "1.0"}`), so it round-trips. *Relaxed* is what people read and write
/// (`1`, `1.0`, ISO dates) and can lose the difference between `int` and `long`.
///
/// Only the type wrappers (`$oid`, `$date`, `$numberLong`, …) are converted. Query operators
/// (`$gt`, `$in`, `$regex` with `$options`, `$exists`) stay ordinary fields, so a filter written
/// as Extended JSON keeps meaning what it says.
public enum ExtendedJSON {
    public enum Mode: Sendable { case canonical, relaxed }

    // MARK: Writing

    public static func string(_ value: BSONValue, mode: Mode = .relaxed, pretty: Bool = false) -> String {
        var output = ""
        write(value, mode: mode, pretty: pretty, indent: 0, to: &output)
        return output
    }

    public static func string(_ document: BSONDocument, mode: Mode = .relaxed, pretty: Bool = false) -> String {
        string(.document(document), mode: mode, pretty: pretty)
    }

    private static func write(_ value: BSONValue, mode: Mode, pretty: Bool, indent: Int, to output: inout String) {
        func compactWrapper(_ key: String, _ inner: String) {
            output += pretty ? "{ \"\(key)\": \(inner) }" : "{\"\(key)\":\(inner)}"
        }
        switch value {
        case .double(let number):
            if number.isNaN || number.isInfinite {
                compactWrapper("$numberDouble", quote(number.isNaN ? "NaN" : (number < 0 ? "-Infinity" : "Infinity")))
            } else if mode == .canonical {
                compactWrapper("$numberDouble", quote(number.description))
            } else {
                output += number.description
            }
        case .string(let text):
            output += quote(text)
        case .document(let document):
            writeObject(document.fields.map { ($0.key, $0.value) }, mode: mode, pretty: pretty, indent: indent, to: &output)
        case .array(let items):
            writeArray(items, mode: mode, pretty: pretty, indent: indent, to: &output)
        case .binary(let subtype, let bytes):
            let subtypeText = String(format: "%02x", subtype)
            let inner = "{\"base64\":\(quote(Data(bytes).base64EncodedString())),\"subType\":\(quote(subtypeText))}"
            compactWrapper("$binary", inner)
        case .undefined:
            compactWrapper("$undefined", "true")
        case .objectId(let bytes):
            compactWrapper("$oid", quote(bytes.map { String(format: "%02x", $0) }.joined()))
        case .bool(let flag):
            output += flag ? "true" : "false"
        case .date(let milliseconds):
            if mode == .relaxed, let iso = isoString(milliseconds: milliseconds) {
                compactWrapper("$date", quote(iso))
            } else {
                compactWrapper("$date", "{\"$numberLong\":\(quote(String(milliseconds)))}")
            }
        case .null:
            output += "null"
        case .regex(let pattern, let options):
            compactWrapper("$regularExpression", "{\"pattern\":\(quote(pattern)),\"options\":\(quote(options))}")
        case .dbPointer(let namespace, let id):
            let hex = id.map { String(format: "%02x", $0) }.joined()
            compactWrapper("$dbPointer", "{\"$ref\":\(quote(namespace)),\"$id\":{\"$oid\":\(quote(hex))}}")
        case .javascript(let code):
            compactWrapper("$code", quote(code))
        case .symbol(let text):
            compactWrapper("$symbol", quote(text))
        case .javascriptWithScope(let code, let scope):
            let scopeText = string(scope, mode: mode, pretty: false)
            output += pretty ? "{ \"$code\": \(quote(code)), \"$scope\": \(scopeText) }" : "{\"$code\":\(quote(code)),\"$scope\":\(scopeText)}"
        case .int32(let number):
            if mode == .canonical { compactWrapper("$numberInt", quote(String(number))) } else { output += String(number) }
        case .timestamp(let increment, let seconds):
            compactWrapper("$timestamp", "{\"t\":\(seconds),\"i\":\(increment)}")
        case .int64(let number):
            if mode == .canonical { compactWrapper("$numberLong", quote(String(number))) } else { output += String(number) }
        case .decimal128(let decimal):
            compactWrapper("$numberDecimal", quote(decimal.description))
        case .minKey:
            compactWrapper("$minKey", "1")
        case .maxKey:
            compactWrapper("$maxKey", "1")
        }
    }

    private static func writeObject(
        _ pairs: [(String, BSONValue)], mode: Mode, pretty: Bool, indent: Int, to output: inout String
    ) {
        guard !pairs.isEmpty else { output += "{}"; return }
        output += "{"
        for (index, pair) in pairs.enumerated() {
            if index > 0 { output += "," }
            if pretty { output += "\n" + String(repeating: "  ", count: indent + 1) }
            output += quote(pair.0) + (pretty ? ": " : ":")
            write(pair.1, mode: mode, pretty: pretty, indent: indent + 1, to: &output)
        }
        if pretty { output += "\n" + String(repeating: "  ", count: indent) }
        output += "}"
    }

    private static func writeArray(
        _ items: [BSONValue], mode: Mode, pretty: Bool, indent: Int, to output: inout String
    ) {
        guard !items.isEmpty else { output += "[]"; return }
        output += "["
        for (index, item) in items.enumerated() {
            if index > 0 { output += "," }
            if pretty { output += "\n" + String(repeating: "  ", count: indent + 1) }
            write(item, mode: mode, pretty: pretty, indent: indent + 1, to: &output)
        }
        if pretty { output += "\n" + String(repeating: "  ", count: indent) }
        output += "]"
    }

    static func quote(_ text: String) -> String {
        var result = "\""
        result.reserveCapacity(text.utf8.count + 2)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result + "\""
    }

    // MARK: Dates

    /// `YYYY-MM-DDTHH:MM:SS.mmmZ` for years 1970 through 9999, otherwise nil (the caller then uses
    /// the canonical `$numberLong` form, which has no year limit).
    public static func isoString(milliseconds: Int64) -> String? {
        let day: Int64 = 86_400_000
        let days = milliseconds >= 0 ? milliseconds / day : -((-milliseconds + day - 1) / day)
        guard let (year, month, dayOfMonth) = civil(fromDaysSince1970: days), (1970...9999).contains(year) else {
            return nil
        }
        let inDay = milliseconds - days * day
        let hours = inDay / 3_600_000, minutes = inDay / 60_000 % 60, seconds = inDay / 1000 % 60, millis = inDay % 1000
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", year, month, dayOfMonth, hours, minutes, seconds, millis)
    }

    static func civil(fromDaysSince1970 days: Int64) -> (Int, Int, Int)? {
        guard abs(days) < 100_000_000 else { return nil }
        let z = Int(days) + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    static func daysSince1970(year: Int, month: Int, day: Int) -> Int64 {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let monthIndex = month > 2 ? month - 3 : month + 9
        let dayOfYear = (153 * monthIndex + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return Int64(era * 146_097 + dayOfEra - 719_468)
    }

    /// `2024-03-05T10:20:30(.123)?(Z|±HH:MM|±HHMM)`
    static func parseISO(_ text: String) -> Int64? {
        let s = Array(text.utf8)
        func digits(_ start: Int, _ count: Int) -> Int? {
            guard start + count <= s.count else { return nil }
            var value = 0
            for index in start..<(start + count) {
                guard s[index] >= 48, s[index] <= 57 else { return nil }
                value = value * 10 + Int(s[index] - 48)
            }
            return value
        }
        guard s.count >= 20, let year = digits(0, 4), s[4] == 45, let month = digits(5, 2), s[7] == 45,
              let day = digits(8, 2), s[10] == 84 || s[10] == 116, let hour = digits(11, 2), s[13] == 58,
              let minute = digits(14, 2), s[16] == 58, let second = digits(17, 2),
              (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
        else { return nil }
        var index = 19
        var millis = 0
        if index < s.count, s[index] == 46 {
            index += 1
            var count = 0
            var fraction = 0
            while index < s.count, s[index] >= 48, s[index] <= 57 {
                if count < 3 { fraction = fraction * 10 + Int(s[index] - 48); count += 1 }
                index += 1
            }
            guard count > 0 else { return nil }
            millis = fraction * [1, 100, 10, 1][count]
        }
        var offsetMinutes = 0
        guard index < s.count else { return nil }
        if s[index] == 90 || s[index] == 122 {
            index += 1
        } else if s[index] == 43 || s[index] == 45 {
            let sign = s[index] == 45 ? -1 : 1
            guard let offsetHour = digits(index + 1, 2) else { return nil }
            var next = index + 3
            if next < s.count, s[next] == 58 { next += 1 }
            let offsetMinute = digits(next, 2) ?? 0
            next += digits(next, 2) == nil ? 0 : 2
            offsetMinutes = sign * (offsetHour * 60 + offsetMinute)
            index = next
        } else {
            return nil
        }
        guard index == s.count else { return nil }
        let days = daysSince1970(year: year, month: month, day: day)
        let seconds = days * 86_400 + Int64(hour * 3600 + minute * 60 + second) - Int64(offsetMinutes * 60)
        return seconds * 1000 + Int64(millis)
    }

    // MARK: Parsing

    public static func parse(_ text: String) throws -> BSONValue {
        var parser = Parser(bytes: Array(text.utf8))
        parser.skipWhitespace()
        let node = try parser.parseValue(depth: 0)
        parser.skipWhitespace()
        guard parser.position == parser.bytes.count else {
            throw ExtendedJSONError.syntax("unexpected text after the value", offset: parser.characterOffset)
        }
        return try convert(node)
    }

    public static func parseDocument(_ text: String) throws -> BSONDocument {
        // An empty box means "no filter", which is the empty document.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return BSONDocument() }
        guard case .document(let document) = try parse(text) else {
            throw ExtendedJSONError.invalidWrapper("Expected a JSON object.")
        }
        return document
    }

    private indirect enum Node {
        case object([(String, Node)])
        case array([Node])
        case string(String)
        case number(String)
        case bool(Bool)
        case null
    }

    private struct Parser {
        let bytes: [UInt8]
        var position = 0

        var characterOffset: Int { String(decoding: bytes[0..<min(position, bytes.count)], as: UTF8.self).count }

        mutating func skipWhitespace() {
            while position < bytes.count, [32, 9, 10, 13].contains(bytes[position]) { position += 1 }
        }

        func fail(_ message: String) -> ExtendedJSONError {
            .syntax(message, offset: characterOffset)
        }

        mutating func parseValue(depth: Int) throws -> Node {
            guard depth <= 100 else { throw ExtendedJSONError.tooDeep }
            guard position < bytes.count else { throw fail("unexpected end") }
            switch bytes[position] {
            case 123: return try parseObject(depth: depth)
            case 91: return try parseArray(depth: depth)
            case 34: return .string(try parseString())
            case 116: try expect("true"); return .bool(true)
            case 102: try expect("false"); return .bool(false)
            case 110: try expect("null"); return .null
            case 45, 48...57: return .number(try parseNumber())
            default: throw fail("unexpected character")
            }
        }

        mutating func expect(_ word: String) throws {
            let utf8 = Array(word.utf8)
            guard position + utf8.count <= bytes.count, Array(bytes[position..<(position + utf8.count)]) == utf8 else {
                throw fail("expected \(word)")
            }
            position += utf8.count
        }

        mutating func parseNumber() throws -> String {
            let start = position
            if bytes[position] == 45 { position += 1 }
            guard position < bytes.count, bytes[position] >= 48, bytes[position] <= 57 else { throw fail("invalid number") }
            // JSON has no leading zeros: `0` may only be followed by `.`, `e`, `E` or the end.
            let leadingZero = bytes[position] == 48
            while position < bytes.count, bytes[position] >= 48, bytes[position] <= 57 { position += 1 }
            if leadingZero, position - start - (bytes[start] == 45 ? 1 : 0) > 1 { throw fail("numbers cannot have leading zeros") }
            if position < bytes.count, bytes[position] == 46 {
                position += 1
                guard position < bytes.count, bytes[position] >= 48, bytes[position] <= 57 else { throw fail("invalid number") }
                while position < bytes.count, bytes[position] >= 48, bytes[position] <= 57 { position += 1 }
            }
            if position < bytes.count, bytes[position] == 101 || bytes[position] == 69 {
                position += 1
                if position < bytes.count, bytes[position] == 43 || bytes[position] == 45 { position += 1 }
                guard position < bytes.count, bytes[position] >= 48, bytes[position] <= 57 else { throw fail("invalid number") }
                while position < bytes.count, bytes[position] >= 48, bytes[position] <= 57 { position += 1 }
            }
            return String(decoding: bytes[start..<position], as: UTF8.self)
        }

        mutating func parseString() throws -> String {
            position += 1  // opening quote
            var scalars = String.UnicodeScalarView()
            var chunkStart = position
            func flush(_ end: Int, into scalars: inout String.UnicodeScalarView) {
                if end > chunkStart { scalars.append(contentsOf: String(decoding: bytes[chunkStart..<end], as: UTF8.self).unicodeScalars) }
            }
            while position < bytes.count {
                let byte = bytes[position]
                if byte == 34 {
                    flush(position, into: &scalars)
                    position += 1
                    return String(scalars)
                }
                if byte == 92 {
                    flush(position, into: &scalars)
                    position += 1
                    guard position < bytes.count else { throw fail("unterminated string") }
                    switch bytes[position] {
                    case 34: scalars.append("\"")
                    case 92: scalars.append("\\")
                    case 47: scalars.append("/")
                    case 98: scalars.append("\u{08}")
                    case 102: scalars.append("\u{0C}")
                    case 110: scalars.append("\n")
                    case 114: scalars.append("\r")
                    case 116: scalars.append("\t")
                    case 117:
                        var code = try hex4(at: position + 1)
                        position += 4
                        if (0xD800...0xDBFF).contains(code) {
                            guard position + 6 < bytes.count, bytes[position + 1] == 92, bytes[position + 2] == 117 else {
                                throw fail("a high surrogate must be followed by a low one")
                            }
                            let low = try hex4(at: position + 3)
                            guard (0xDC00...0xDFFF).contains(low) else { throw fail("invalid surrogate pair") }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                            position += 6
                        }
                        guard let scalar = Unicode.Scalar(code) else { throw fail("invalid unicode escape") }
                        scalars.append(scalar)
                    default:
                        throw fail("invalid escape")
                    }
                    position += 1
                    chunkStart = position
                    continue
                }
                position += 1
            }
            throw fail("unterminated string")
        }

        func hex4(at start: Int) throws -> UInt32 {
            guard start + 4 <= bytes.count else { throw fail("invalid unicode escape") }
            var value: UInt32 = 0
            for index in start..<(start + 4) {
                guard let nibble = hexNibble(bytes[index]) else { throw fail("invalid unicode escape") }
                value = value << 4 | UInt32(nibble)
            }
            return value
        }

        mutating func parseArray(depth: Int) throws -> Node {
            position += 1
            var items: [Node] = []
            skipWhitespace()
            if position < bytes.count, bytes[position] == 93 { position += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard position < bytes.count else { throw fail("unterminated array") }
                if bytes[position] == 44 { position += 1; continue }
                if bytes[position] == 93 { position += 1; return .array(items) }
                throw fail("expected , or ]")
            }
        }

        mutating func parseObject(depth: Int) throws -> Node {
            position += 1
            var pairs: [(String, Node)] = []
            skipWhitespace()
            if position < bytes.count, bytes[position] == 125 { position += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                guard position < bytes.count, bytes[position] == 34 else { throw fail("expected a quoted key") }
                let key = try parseString()
                skipWhitespace()
                guard position < bytes.count, bytes[position] == 58 else { throw fail("expected :") }
                position += 1
                skipWhitespace()
                pairs.append((key, try parseValue(depth: depth + 1)))
                skipWhitespace()
                guard position < bytes.count else { throw fail("unterminated object") }
                if bytes[position] == 44 { position += 1; continue }
                if bytes[position] == 125 { position += 1; return .object(pairs) }
                throw fail("expected , or }")
            }
        }
    }

    // MARK: Converting wrappers

    private static func convert(_ node: Node) throws -> BSONValue {
        switch node {
        case .null: return .null
        case .bool(let flag): return .bool(flag)
        case .string(let text): return .string(text)
        case .number(let raw): return try number(raw)
        case .array(let items): return .array(try items.map(convert))
        case .object(let pairs): return try object(pairs)
        }
    }

    private static func number(_ raw: String) throws -> BSONValue {
        if !raw.contains("."), !raw.contains("e"), !raw.contains("E") {
            if let small = Int32(raw) { return .int32(small) }
            if let large = Int64(raw) { return .int64(large) }
        }
        guard let value = Double(raw), value.isFinite else {
            throw ExtendedJSONError.invalidWrapper("The number \(raw) is out of range.")
        }
        return .double(value)
    }

    private static func object(_ pairs: [(String, Node)]) throws -> BSONValue {
        let keys = pairs.map(\.0)
        func value(_ key: String) -> Node? { pairs.first { $0.0 == key }?.1 }
        func requireString(_ node: Node?, _ what: String) throws -> String {
            guard case .string(let text)? = node else { throw ExtendedJSONError.invalidWrapper("\(what) must be a string.") }
            return text
        }
        func wrapper(_ key: String) -> Bool { keys.first == key && (keys.count == 1) }

        if wrapper("$oid") {
            let hex = try requireString(value("$oid"), "$oid")
            guard let id = BSONValue.objectId(hex: hex) else {
                throw ExtendedJSONError.invalidWrapper("\"\(hex)\" is not a valid ObjectId (24 hexadecimal digits).")
            }
            return id
        }
        if wrapper("$numberInt") {
            guard let number = Int32(try requireString(value("$numberInt"), "$numberInt")) else {
                throw ExtendedJSONError.invalidWrapper("$numberInt is not a 32-bit integer.")
            }
            return .int32(number)
        }
        if wrapper("$numberLong") {
            guard let number = Int64(try requireString(value("$numberLong"), "$numberLong")) else {
                throw ExtendedJSONError.invalidWrapper("$numberLong is not a 64-bit integer.")
            }
            return .int64(number)
        }
        if wrapper("$numberDouble") {
            let text = try requireString(value("$numberDouble"), "$numberDouble")
            switch text {
            case "NaN": return .double(.nan)
            case "Infinity": return .double(.infinity)
            case "-Infinity": return .double(-.infinity)
            default:
                guard let number = Double(text) else { throw ExtendedJSONError.invalidWrapper("$numberDouble is not a number.") }
                return .double(number)
            }
        }
        if wrapper("$numberDecimal") {
            do {
                return .decimal128(try Decimal128Value(try requireString(value("$numberDecimal"), "$numberDecimal")))
            } catch {
                throw ExtendedJSONError.invalidWrapper(error.localizedDescription)
            }
        }
        if wrapper("$date") {
            switch value("$date") {
            case .string(let text)?:
                guard let milliseconds = parseISO(text) else {
                    throw ExtendedJSONError.invalidWrapper("\"\(text)\" is not an ISO-8601 date (like 2024-03-05T10:20:30.000Z).")
                }
                return .date(milliseconds: milliseconds)
            case .object(let inner)?:
                guard inner.count == 1, inner[0].0 == "$numberLong", case .string(let text) = inner[0].1,
                      let milliseconds = Int64(text)
                else { throw ExtendedJSONError.invalidWrapper("$date must hold a string or {\"$numberLong\": \"…\"}.") }
                return .date(milliseconds: milliseconds)
            case .number(let raw)?:
                guard let milliseconds = Int64(raw) else { throw ExtendedJSONError.invalidWrapper("$date is not a millisecond count.") }
                return .date(milliseconds: milliseconds)
            default:
                throw ExtendedJSONError.invalidWrapper("$date must hold a string or {\"$numberLong\": \"…\"}.")
            }
        }
        if wrapper("$binary"), case .object(let inner)? = value("$binary") {
            guard case .string(let base64)? = inner.first(where: { $0.0 == "base64" })?.1,
                  let data = Data(base64Encoded: base64)
            else { throw ExtendedJSONError.invalidWrapper("$binary needs valid base64 data.") }
            let subtypeNode = inner.first { $0.0 == "subType" }?.1
            var subtype: UInt8 = 0
            if case .string(let text)? = subtypeNode, let parsed = UInt8(text, radix: 16) { subtype = parsed }
            else if case .number(let raw)? = subtypeNode, let parsed = UInt8(raw) { subtype = parsed }
            return .binary(subtype: subtype, bytes: Array(data))
        }
        if wrapper("$uuid") {
            let text = try requireString(value("$uuid"), "$uuid")
            guard let uuid = UUID(uuidString: text) else { throw ExtendedJSONError.invalidWrapper("\"\(text)\" is not a UUID.") }
            return .binary(subtype: 4, bytes: withUnsafeBytes(of: uuid.uuid) { Array($0) })
        }
        if wrapper("$regularExpression"), case .object(let inner)? = value("$regularExpression") {
            let pattern = try requireString(inner.first { $0.0 == "pattern" }?.1, "pattern")
            let options = try requireString(inner.first { $0.0 == "options" }?.1, "options")
            return .regex(pattern: pattern, options: options)
        }
        if wrapper("$timestamp"), case .object(let inner)? = value("$timestamp") {
            guard case .number(let t)? = inner.first(where: { $0.0 == "t" })?.1,
                  case .number(let i)? = inner.first(where: { $0.0 == "i" })?.1,
                  let seconds = UInt32(t), let increment = UInt32(i)
            else { throw ExtendedJSONError.invalidWrapper("$timestamp needs unsigned 32-bit \"t\" and \"i\".") }
            return .timestamp(increment: increment, seconds: seconds)
        }
        if wrapper("$minKey") { return .minKey }
        if wrapper("$maxKey") { return .maxKey }
        if wrapper("$undefined") { return .undefined }
        if wrapper("$symbol") { return .symbol(try requireString(value("$symbol"), "$symbol")) }
        if wrapper("$code") { return .javascript(try requireString(value("$code"), "$code")) }
        if Set(keys) == ["$code", "$scope"], keys.count == 2 {
            let code = try requireString(value("$code"), "$code")
            guard case .document(let scope) = try convert(value("$scope")!) else {
                throw ExtendedJSONError.invalidWrapper("$scope must be an object.")
            }
            return .javascriptWithScope(code: code, scope: scope)
        }
        if wrapper("$dbPointer"), case .object(let inner)? = value("$dbPointer") {
            let namespace = try requireString(inner.first { $0.0 == "$ref" }?.1, "$ref")
            guard case .objectId(let id) = try convert(inner.first { $0.0 == "$id" }?.1 ?? .null) else {
                throw ExtendedJSONError.invalidWrapper("$dbPointer needs an $id ObjectId.")
            }
            return .dbPointer(namespace: namespace, id: id)
        }
        return .document(BSONDocument(try pairs.map { BSONField($0.0, try convert($0.1)) }))
    }
}
