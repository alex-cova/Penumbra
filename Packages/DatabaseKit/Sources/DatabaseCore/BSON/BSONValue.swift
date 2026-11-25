import Foundation

/// A BSON value, kept exactly: nothing is converted through `Double`, `Date` or a string on the
/// way in, so an `Int64` above 2^53, a `Decimal128`, a `Timestamp` and an `ObjectId` come back
/// byte for byte. A missing field is the *absence* of a `BSONField`, never a value, so it can
/// never be confused with `.null`.
///
/// Why this exists rather than the BSON library's `Primitive`: its `Decimal128` is a stub with no
/// readable fields, and the app needs to show, edit and export every type faithfully.
public indirect enum BSONValue: Equatable, Sendable {
    case double(Double)
    case string(String)
    case document(BSONDocument)
    case array([BSONValue])
    case binary(subtype: UInt8, bytes: [UInt8])
    /// Deprecated in the spec; kept so old data round-trips.
    case undefined
    /// Twelve bytes.
    case objectId([UInt8])
    case bool(Bool)
    /// Milliseconds since the Unix epoch, UTC. Any `Int64`, including dates `Date` cannot hold.
    case date(milliseconds: Int64)
    case null
    case regex(pattern: String, options: String)
    case dbPointer(namespace: String, id: [UInt8])
    case javascript(String)
    case symbol(String)
    case javascriptWithScope(code: String, scope: BSONDocument)
    case int32(Int32)
    case timestamp(increment: UInt32, seconds: UInt32)
    case int64(Int64)
    case decimal128(Decimal128Value)
    case minKey
    case maxKey

    /// The name MongoDB's `$type` operator uses for this value.
    public var typeName: String {
        switch self {
        case .double: "double"
        case .string: "string"
        case .document: "object"
        case .array: "array"
        case .binary: "binData"
        case .undefined: "undefined"
        case .objectId: "objectId"
        case .bool: "bool"
        case .date: "date"
        case .null: "null"
        case .regex: "regex"
        case .dbPointer: "dbPointer"
        case .javascript: "javascript"
        case .symbol: "symbol"
        case .javascriptWithScope: "javascriptWithScope"
        case .int32: "int"
        case .timestamp: "timestamp"
        case .int64: "long"
        case .decimal128: "decimal"
        case .minKey: "minKey"
        case .maxKey: "maxKey"
        }
    }

    /// `ObjectId` as 24 lowercase hex digits.
    public static func objectId(hex: String) -> BSONValue? {
        guard hex.utf8.count == 24 else { return nil }
        var bytes: [UInt8] = []
        var iterator = hex.utf8.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            guard let h = hexNibble(high), let l = hexNibble(low) else { return nil }
            bytes.append(UInt8(h << 4 | l))
        }
        return .objectId(bytes)
    }

    public var objectIdHex: String? {
        guard case .objectId(let bytes) = self else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

func hexNibble(_ byte: UInt8) -> Int? {
    switch byte {
    case 48...57: Int(byte) - 48
    case 97...102: Int(byte) - 87
    case 65...70: Int(byte) - 55
    default: nil
    }
}

public struct BSONField: Equatable, Sendable {
    public var key: String
    public var value: BSONValue

    public init(_ key: String, _ value: BSONValue) {
        self.key = key
        self.value = value
    }
}

/// An ordered document. Field order is part of a document's identity in MongoDB (it matters to
/// equality, indexes and `$sort`), so it is kept.
public struct BSONDocument: Equatable, Sendable {
    public var fields: [BSONField]

    public init(_ fields: [BSONField] = []) {
        self.fields = fields
    }

    public init(_ pairs: KeyValuePairs<String, BSONValue>) {
        self.fields = pairs.map { BSONField($0.key, $0.value) }
    }

    /// The first field with this key, or nil if the document has none: *absent*, not null.
    public subscript(key: String) -> BSONValue? {
        get { fields.first { $0.key == key }?.value }
        set {
            if let index = fields.firstIndex(where: { $0.key == key }) {
                if let newValue { fields[index].value = newValue } else { fields.remove(at: index) }
            } else if let newValue {
                fields.append(BSONField(key, newValue))
            }
        }
    }

    public var isEmpty: Bool { fields.isEmpty }
    public var keys: [String] { fields.map(\.key) }
}
