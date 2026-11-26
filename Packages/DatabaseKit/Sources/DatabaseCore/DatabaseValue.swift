import Foundation

/// One cell. Unlike a bare `String?`, it keeps apart the things a database editor must never
/// confuse: SQL NULL, a Mongo field that is absent, an empty string, zero, a value that was cut
/// for display, and a value that has not been fetched.
public enum DatabaseValue: Equatable, Sendable, Codable {
    /// SQL `NULL`, or an explicit BSON `null`.
    case null
    /// The field does not exist (a MongoDB document without that key). Never conflated with `null`.
    case missing
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)
    case double(Double)
    /// Exact decimal text (`numeric`, `DECIMAL`, `Decimal128`). Never routed through `Double`.
    case decimal(String)
    case text(String)
    /// Binary data: the full length and a bounded prefix. The rest is fetched on demand.
    case bytes(count: Int, prefix: [UInt8])
    /// A date, time or timestamp in the server's own ISO-like spelling, with its kind.
    case temporal(String, TemporalKind)
    case json(String)
    case uuid(String)
    case array([DatabaseValue])
    /// A geometry or geography, as the server's text form (WKT, EWKT, GeoJSON or hex WKB).
    case geometry(String)
    /// A BSON value with no plainer form (ObjectId, Decimal128, Timestamp, regex, …) as Extended
    /// JSON, with its BSON type name.
    case bson(typeName: String, extendedJSON: String)
    /// Text or bytes cut for display. `fullCount` is the original length in characters or bytes.
    case truncated(preview: String, fullCount: Int)
    /// Not fetched yet (a large value the result keeps by reference).
    case unloaded

    public enum TemporalKind: String, Equatable, Sendable, Codable {
        case date, time, timeWithZone, timestamp, timestampWithZone, interval, year
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var isMissing: Bool {
        if case .missing = self { return true }
        return false
    }

    /// How a cell is classified for rendering and for the legend. Rendering is the grid's job;
    /// this only says which of the distinguishable states the value is in.
    public enum Presence: Equatable, Sendable {
        case null, missing, empty, binary, truncated, unloaded, value
    }

    public var presence: Presence {
        switch self {
        case .null: .null
        case .missing: .missing
        case .text(let text) where text.isEmpty: .empty
        case .bytes: .binary
        case .truncated: .truncated
        case .unloaded: .unloaded
        default: .value
        }
    }

    /// Longest text a cell shows; the inspector fetches more.
    public static let displayLimit = 256

    /// Text for a grid cell: bounded, single-line, exact for numbers. `null`, `missing` and
    /// `unloaded` return nil so the view draws its own marker instead of a string that could be
    /// mistaken for data.
    public func displayText(limit: Int = DatabaseValue.displayLimit) -> String? {
        switch self {
        case .null, .missing, .unloaded:
            return nil
        case .bool(let value):
            return value ? "true" : "false"
        case .int(let value):
            return String(value)
        case .uint(let value):
            return String(value)
        case .double(let value):
            return Self.format(double: value)
        case .decimal(let text), .uuid(let text):
            return text
        case .text(let text):
            return Self.singleLine(text, limit: limit)
        case .bytes(let count, let prefix):
            return Self.bytesSummary(count: count, prefix: prefix)
        case .temporal(let text, _):
            return text
        case .json(let text), .geometry(let text):
            return Self.singleLine(text, limit: limit)
        case .array(let items):
            let shown = items.prefix(8).map { $0.displayText(limit: 32) ?? "NULL" }
            let more = items.count > 8 ? ", … +\(items.count - 8)" : ""
            return "{" + shown.joined(separator: ", ") + more + "}"
        case .bson(_, let json):
            return Self.singleLine(json, limit: limit)
        case .truncated(let preview, let fullCount):
            return Self.singleLine(preview, limit: limit) + "… (\(fullCount))"
        }
    }

    /// The value as plain text for copying and for text export, without display bounds.
    /// `nil` for `null`, `missing` and `unloaded`: the caller chooses the NULL spelling.
    public var rawText: String? {
        switch self {
        case .null, .missing, .unloaded:
            return nil
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .uint(let value): return String(value)
        case .double(let value): return Self.format(double: value)
        case .decimal(let text), .uuid(let text), .text(let text), .json(let text),
             .geometry(let text):
            return text
        case .temporal(let text, _): return text
        case .bytes(let count, let prefix):
            return prefix.count == count ? "\\x" + Self.hex(prefix) : Self.bytesSummary(count: count, prefix: prefix)
        case .array(let items):
            return "{" + items.map { $0.rawText ?? "NULL" }.joined(separator: ",") + "}"
        case .bson(_, let json): return json
        case .truncated(let preview, _): return preview
        }
    }

    /// A rough in-memory cost, used by `ResultStore` to enforce its ceiling.
    public var estimatedBytes: Int {
        switch self {
        case .null, .missing, .unloaded, .bool, .int, .uint, .double: 16
        case .decimal(let text), .text(let text), .uuid(let text), .json(let text),
             .geometry(let text): 32 + text.utf8.count
        case .temporal(let text, _): 40 + text.utf8.count
        case .bytes(_, let prefix): 40 + prefix.count
        case .array(let items): 32 + items.reduce(0) { $0 + $1.estimatedBytes }
        case .bson(let name, let json): 48 + name.utf8.count + json.utf8.count
        case .truncated(let preview, _): 48 + preview.utf8.count
        }
    }

    /// Shortest round-trip digits, laid out the way PostgreSQL prints a float: plain decimal for
    /// decimal exponents -4 through 14 (`100000`, `0.0001`), otherwise `1.5e+20` / `1e-05`.
    /// No trailing `.0` for whole numbers, which Swift's own `description` adds.
    public static func format(double: Double) -> String {
        if double.isNaN { return "NaN" }
        if double.isInfinite { return double < 0 ? "-Infinity" : "Infinity" }
        if double == 0 { return double.sign == .minus ? "-0" : "0" }
        let sign = double < 0 ? "-" : ""
        let description = abs(double).description  // "123.456", "1e-05", "1.5e+20", "100000.0"
        let parts = description.split(separator: "e", maxSplits: 1)
        let mantissa = String(parts[0])
        let exponent = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let halves = mantissa.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let integerPart = String(halves[0])
        let fractionPart = halves.count > 1 ? String(halves[1]) : ""
        var digits = Array(integerPart + fractionPart)
        var pointIndex = integerPart.count + exponent  // digits before the decimal point
        while digits.first == "0", digits.count > 1 {
            digits.removeFirst()
            pointIndex -= 1
        }
        while digits.last == "0", digits.count > 1 { digits.removeLast() }
        let scientificExponent = pointIndex - 1
        let text = String(digits)
        if scientificExponent >= -4, scientificExponent < 15 {
            if pointIndex <= 0 {
                return sign + "0." + String(repeating: "0", count: -pointIndex) + text
            }
            if pointIndex >= digits.count {
                return sign + text + String(repeating: "0", count: pointIndex - digits.count)
            }
            let split = text.index(text.startIndex, offsetBy: pointIndex)
            return sign + text[..<split] + "." + text[split...]
        }
        let lead = String(digits[0])
        let rest = digits.count > 1 ? "." + String(digits[1...]) : ""
        let magnitude = abs(scientificExponent)
        let exponentText = (magnitude < 10 ? "0" : "") + String(magnitude)
        return sign + lead + rest + "e" + (scientificExponent < 0 ? "-" : "+") + exponentText
    }

    private static func singleLine(_ text: String, limit: Int) -> String {
        var result = ""
        result.reserveCapacity(min(text.utf8.count, limit))
        var count = 0
        for character in text {
            if count >= limit {
                result.append("…")
                break
            }
            switch character {
            case "\n", "\r\n", "\r": result.append("↵")
            case "\t": result.append("⇥")
            default: result.append(character)
            }
            count += 1
        }
        return result
    }

    private static func bytesSummary(count: Int, prefix: [UInt8]) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
        return "‹\(size)›"
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        let digits = Array("0123456789abcdef")
        var result = ""
        result.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            result.append(digits[Int(byte >> 4)])
            result.append(digits[Int(byte & 0x0F)])
        }
        return result
    }
}

/// A result column: what the server said about it, and where it came from when it said so.
public struct ResultColumn: Equatable, Sendable, Codable {
    public var name: String
    /// The engine's own type name (`int4`, `varchar(20)`, `TEXT`, `objectId`…), empty if unknown.
    public var typeName: String
    /// The table and column a value was read from, when the driver reports it. Editing is only
    /// possible for columns that have an origin.
    public var origin: Origin?
    public var isNullable: Bool?
    /// PostgreSQL's RowDescription identity for the column: the table's OID and the column's
    /// attribute number, nil for a computed column. Resolved to names when a result is made editable.
    public var postgresSource: PostgresSource?

    public struct PostgresSource: Equatable, Sendable, Codable {
        public var tableOID: UInt32
        public var attribute: Int16

        public init(tableOID: UInt32, attribute: Int16) {
            self.tableOID = tableOID
            self.attribute = attribute
        }
    }

    public struct Origin: Equatable, Sendable, Codable {
        public var schema: String?
        public var table: String
        public var column: String

        public init(schema: String? = nil, table: String, column: String) {
            self.schema = schema
            self.table = table
            self.column = column
        }
    }

    public init(
        name: String, typeName: String = "", origin: Origin? = nil, isNullable: Bool? = nil,
        postgresSource: PostgresSource? = nil
    ) {
        self.name = name
        self.typeName = typeName
        self.origin = origin
        self.isNullable = isNullable
        self.postgresSource = postgresSource
    }
}
