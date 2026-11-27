import Foundation
import Testing

@testable import DatabaseKit

struct MySQLValueDecoderTests {
    private typealias Code = MySQLValueDecoder.Code

    private func decode(_ code: UInt8, _ text: String?, unsigned: Bool = false, charset: UInt16 = 255) -> DatabaseValue {
        MySQLValueDecoder.decode(typeCode: code, isUnsigned: unsigned, charset: charset, bytes: text.map { Array($0.utf8) })
    }

    @Test func nullEmptyAndZeroAreDistinct() {
        #expect(decode(Code.varString, nil) == .null)
        #expect(decode(Code.varString, "") == .text(""))
        #expect(decode(Code.long, "0") == .int(0))
    }

    @Test func integersHonourUnsigned() {
        #expect(decode(Code.tiny, "-128") == .int(-128))
        #expect(decode(Code.longlong, "9007199254740993") == .int(9_007_199_254_740_993))
        // BIGINT UNSIGNED above Int64.max must not wrap.
        #expect(decode(Code.longlong, "18446744073709551615", unsigned: true) == .uint(UInt64.max))
        #expect(decode(Code.long, "4294967295", unsigned: true) == .int(4_294_967_295))
        #expect(decode(Code.year, "2024") == .int(2024))
    }

    @Test func decimalsAreExactText() {
        #expect(decode(Code.newdecimal, "12345.6789000") == .decimal("12345.6789000"))
        #expect(decode(Code.newdecimal, "-0.05") == .decimal("-0.05"))
    }

    @Test func textVersusBinaryIsDecidedByTheCharset() {
        // TEXT is a blob type with a text charset; BLOB has charset 63.
        #expect(decode(Code.blob, "hello", charset: 255) == .text("hello"))
        #expect(decode(Code.blob, "hello", charset: 63) == .bytes(count: 5, prefix: Array("hello".utf8)))
        #expect(decode(Code.varString, "ab", charset: 63) == .bytes(count: 2, prefix: Array("ab".utf8)))
        #expect(decode(Code.string, "héllo", charset: 45) == .text("héllo"))
        // A TEXT value that is not UTF-8 text-looking is still text; only the charset decides.
        #expect(decode(Code.longBlob, "{\"a\":1}", charset: 255) == .text("{\"a\":1}"))
    }

    @Test func temporalAndStructuredTypes() {
        #expect(decode(Code.date, "2024-03-05") == .temporal("2024-03-05", .date))
        #expect(decode(Code.datetime, "2024-03-05 10:20:30.500000") == .temporal("2024-03-05 10:20:30.500000", .timestamp))
        #expect(decode(Code.time, "-838:59:59") == .temporal("-838:59:59", .time))
        #expect(decode(Code.json, "{\"a\": [1, 2]}") == .json("{\"a\": [1, 2]}"))
        #expect(decode(Code.enumeration, "shipped") == .text("shipped"))
        #expect(decode(Code.set, "a,b") == .text("a,b"))
        #expect(decode(Code.double, "1.5") == .double(1.5))
    }

    @Test func bitAndGeometryAreBoundedBinary() {
        #expect(decode(Code.bit, "\u{05}", charset: 63).presence == .binary)
        #expect(decode(Code.geometry, "xyz", charset: 63).presence == .binary)
    }

    @Test func largeValuesAreBounded() {
        let limits = ValueLimits(maxTextBytes: 50, binaryPrefix: 4)
        let big = Array(String(repeating: "é", count: 200).utf8)
        guard case .truncated(let preview, let count) = MySQLValueDecoder.decode(
            typeCode: Code.longBlob, isUnsigned: false, charset: 255, bytes: big, limits: limits
        ) else {
            Issue.record("expected truncated")
            return
        }
        #expect(count == big.count)
        #expect(preview.utf8.count <= 50)
        #expect(!preview.contains("\u{FFFD}"))
        #expect(MySQLValueDecoder.decode(
            typeCode: Code.blob, isUnsigned: false, charset: 63, bytes: [UInt8](repeating: 1, count: 1_000_000), limits: limits
        ) == .bytes(count: 1_000_000, prefix: [1, 1, 1, 1]))
    }

    @Test func typeNamesDistinguishTextFromBlobAndSigned() {
        #expect(MySQLValueDecoder.typeName(typeCode: Code.blob, isUnsigned: false, charset: 255) == "text")
        #expect(MySQLValueDecoder.typeName(typeCode: Code.blob, isUnsigned: false, charset: 63) == "blob")
        #expect(MySQLValueDecoder.typeName(typeCode: Code.longlong, isUnsigned: true, charset: 63) == "bigint unsigned")
        #expect(MySQLValueDecoder.typeName(typeCode: Code.varString, isUnsigned: false, charset: 63) == "varbinary")
    }
}
