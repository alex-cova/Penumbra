import Foundation
import Testing

@testable import DatabaseCore

struct BSONCodecTests {
    private func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined(separator: " ") }

    @Test func matchesTheSpecificationsOwnExamples() throws {
        // {"hello": "world"} from bsonspec.org
        let hello = BSONDocument(["hello": .string("world")])
        #expect(hex(try BSONCodec.encode(hello)) == "16 00 00 00 02 68 65 6c 6c 6f 00 06 00 00 00 77 6f 72 6c 64 00 00")
        // {"BSON": ["awesome", 5.05, 1986]} from bsonspec.org
        let bson = BSONDocument(["BSON": .array([.string("awesome"), .double(5.05), .int32(1986)])])
        #expect(hex(try BSONCodec.encode(bson))
            == "31 00 00 00 04 42 53 4f 4e 00 26 00 00 00 02 30 00 08 00 00 00 61 77 65 73 6f 6d 65 00 01 31 00 33 33 33 33 33 33 14 40 10 32 00 c2 07 00 00 00 00")
        #expect(try BSONCodec.decode(try BSONCodec.encode(bson)) == bson)
    }

    private var everyType: BSONDocument {
        BSONDocument([
            "double": .double(-0.5), "nan": .double(.infinity), "string": .string("héllo\u{0}there"),
            "doc": .document(BSONDocument(["a": .int32(1), "b": .document(BSONDocument())])),
            "array": .array([.int32(1), .null, .string("x"), .array([])]),
            "bin": .binary(subtype: 0x80, bytes: [1, 2, 3]), "uuid": .binary(subtype: 4, bytes: Array(0..<16)),
            "oldbin": .binary(subtype: 2, bytes: [9, 8]),
            "undef": .undefined, "oid": .objectId(Array(0..<12)), "t": .bool(true), "f": .bool(false),
            "date": .date(milliseconds: -62_135_596_800_000), "null": .null,
            "re": .regex(pattern: "^a.*", options: "im"), "ptr": .dbPointer(namespace: "db.c", id: Array(0..<12)),
            "js": .javascript("x"), "sym": .symbol("s"),
            "scoped": .javascriptWithScope(code: "y", scope: BSONDocument(["z": .int32(1)])),
            "i32": .int32(.min), "ts": .timestamp(increment: 4_000_000_000, seconds: 3_000_000_000),
            "i64": .int64(9_007_199_254_740_993), "dec": .decimal128(try! Decimal128Value("1.50")),
            "min": .minKey, "max": .maxKey,
        ])
    }

    @Test func everyTypeRoundTripsExactly() throws {
        let document = everyType
        let back = try BSONCodec.decode(try BSONCodec.encode(document))
        #expect(back == document)
        // Exactness that Double/Date/String conversions would lose:
        #expect(back["i64"] == .int64(9_007_199_254_740_993))
        #expect(back["ts"] == .timestamp(increment: 4_000_000_000, seconds: 3_000_000_000))
        #expect(back["date"] == .date(milliseconds: -62_135_596_800_000))
        #expect(back["dec"] == .decimal128(try Decimal128Value("1.50")))
    }

    @Test func missingAndNullAreDifferent() throws {
        let withNull = BSONDocument(["a": .null])
        let without = BSONDocument()
        #expect(withNull["a"] == .null)
        #expect(without["a"] == nil)
        let back = try BSONCodec.decode(try BSONCodec.encode(withNull))
        #expect(back["a"] == .null)
        #expect(back.keys == ["a"])
    }

    @Test func fieldOrderIsPreserved() throws {
        let document = BSONDocument(["z": .int32(1), "a": .int32(2), "m": .int32(3)])
        #expect(try BSONCodec.decode(try BSONCodec.encode(document)).keys == ["z", "a", "m"])
    }

    @Test func malformedInputThrowsAndNeverTraps() throws {
        let valid = try BSONCodec.encode(everyType)
        // Every truncation of a valid document is an error, not a crash.
        for length in 0..<valid.count {
            #expect(throws: BSONError.self) { _ = try BSONCodec.decode(Array(valid[0..<length])) }
        }
        // Corrupt one byte at a time: the result is either a document or an error, never a trap.
        var survived = 0
        for index in 0..<valid.count {
            var corrupted = valid
            corrupted[index] ^= 0xFF
            if (try? BSONCodec.decode(corrupted)) != nil { survived += 1 }
        }
        #expect(survived < valid.count)
        // Declared lengths larger than the data, negative lengths, unknown types.
        #expect(throws: BSONError.self) { _ = try BSONCodec.decode([0xFF, 0xFF, 0xFF, 0x7F, 0]) }
        #expect(throws: BSONError.self) { _ = try BSONCodec.decode([5, 0, 0, 0, 1]) }
        #expect(throws: BSONError.self) { _ = try BSONCodec.decode([8, 0, 0, 0, 0x99, 0x61, 0, 0]) }
    }

    @Test func deepNestingIsRefused() throws {
        var value = BSONValue.int32(1)
        for _ in 0..<150 { value = .document(BSONDocument(["a": value])) }
        guard case .document(let deep) = value else { return }
        #expect(throws: BSONError.tooDeep) { _ = try BSONCodec.encode(deep) }
    }

    @Test func keysWithNULAreRefused() {
        #expect(throws: BSONError.self) { _ = try BSONCodec.encode(BSONDocument([BSONField("a\u{0}b", .null)])) }
    }
}

struct Decimal128Tests {
    private func bits(_ text: String) throws -> (UInt64, UInt64) {
        let value = try Decimal128Value(text)
        return (value.high, value.low)
    }

    @Test func encodesTheCorpusValues() throws {
        #expect(try bits("0") == (0x3040_0000_0000_0000, 0))
        #expect(try bits("-0") == (0xB040_0000_0000_0000, 0))
        #expect(try bits("1") == (0x3040_0000_0000_0000, 1))
        #expect(try bits("-1") == (0xB040_0000_0000_0000, 1))
        #expect(try bits("1.5") == (0x303E_0000_0000_0000, 15))
        #expect(try bits("1E+3") == (0x3046_0000_0000_0000, 1))
        #expect(try bits("0.001") == (0x303A_0000_0000_0000, 1))
        #expect(try bits("9.999999999999999999999999999999999E+6144") == (0x5FFF_ED09_BEAD_87C0, 0x378D_8E63_FFFF_FFFF))
        #expect(try bits("NaN") == (0x7C00_0000_0000_0000, 0))
        #expect(try bits("Infinity") == (0x7800_0000_0000_0000, 0))
        #expect(try bits("-Infinity") == (0xF800_0000_0000_0000, 0))
    }

    @Test func formatsTheSpecificationsWay() {
        func text(_ high: UInt64, _ low: UInt64) -> String { Decimal128Value(low: low, high: high).description }
        #expect(text(0x3040_0000_0000_0000, 0) == "0")
        #expect(text(0xB040_0000_0000_0000, 0) == "-0")
        #expect(text(0x3040_0000_0000_0000, 1) == "1")
        #expect(text(0x303E_0000_0000_0000, 15) == "1.5")
        #expect(text(0x3046_0000_0000_0000, 1) == "1E+3")
        #expect(text(0x303A_0000_0000_0000, 1) == "0.001")
        #expect(text(0x5FFF_ED09_BEAD_87C0, 0x378D_8E63_FFFF_FFFF) == "9.999999999999999999999999999999999E+6144")
        #expect(text(0x7C00_0000_0000_0000, 0) == "NaN")
        #expect(text(0xF800_0000_0000_0000, 0) == "-Infinity")
        // 1E-7: adjusted exponent -7 is below -6, so scientific.
        #expect((try? Decimal128Value("0.0000001"))?.description == "1E-7")
        #expect((try? Decimal128Value("0.000001"))?.description == "0.000001")
    }

    @Test func roundTripsTextExactlyIncludingTrailingZeros() throws {
        for text in ["12345.6789", "-0.05", "100", "1.50", "0.00", "123456789012345678901234567890.1234",
                     "1E+10", "5E-6176", "9.999999999999999999999999999999999E+6144", "-0.000001"] {
            let value = try Decimal128Value(text)
            #expect(value.description == text, Comment(rawValue: "\(text) -> \(value.description)"))
            #expect(try Decimal128Value(value.description) == value)
        }
        #expect(try Decimal128Value("1.5e2").description == "1.5E+2")
        #expect(try Decimal128Value("007").description == "7")
    }

    @Test func refusesWhatItCannotHold() {
        #expect(throws: Decimal128Value.ParseError.self) { _ = try Decimal128Value("12345678901234567890123456789012345") }
        #expect(throws: Decimal128Value.ParseError.self) { _ = try Decimal128Value("1E+6200") }
        #expect(throws: Decimal128Value.ParseError.self) { _ = try Decimal128Value("abc") }
        #expect(throws: Decimal128Value.ParseError.self) { _ = try Decimal128Value("1.2.3") }
        #expect(throws: Decimal128Value.ParseError.self) { _ = try Decimal128Value("") }
        // 34 significant digits followed by zeros that can move into the exponent is fine.
        #expect((try? Decimal128Value("1000000000000000000000000000000000000"))?.description == "1.000000000000000000000000000000000E+36")
    }

    @Test func sixteenBytesRoundTrip() throws {
        let value = try Decimal128Value("-123.456")
        #expect(Decimal128Value(bytes: value.bytes) == value)
        #expect(Decimal128Value(bytes: [1, 2, 3]) == nil)
    }
}

struct ExtendedJSONTests {
    private func parse(_ text: String) throws -> BSONValue { try ExtendedJSON.parse(text) }

    @Test func canonicalKeepsEveryTypeAndRoundTrips() throws {
        let document = BSONDocument([
            "i": .int32(1), "l": .int64(9_007_199_254_740_993), "d": .double(1), "dec": .decimal128(try Decimal128Value("1.50")),
            "oid": .objectId(Array(0..<12)), "date": .date(milliseconds: 1_709_634_030_123),
            "bin": .binary(subtype: 0, bytes: [1, 2, 3]), "re": .regex(pattern: "a", options: "i"),
            "ts": .timestamp(increment: 1, seconds: 2), "min": .minKey, "max": .maxKey, "undef": .undefined,
            "js": .javascript("1+1"), "scoped": .javascriptWithScope(code: "x", scope: BSONDocument(["a": .int32(1)])),
            "sym": .symbol("s"), "ptr": .dbPointer(namespace: "d.c", id: Array(0..<12)),
            "null": .null, "arr": .array([.int32(1), .string("a")]), "nested": .document(BSONDocument(["k": .bool(true)])),
        ])
        let text = ExtendedJSON.string(document, mode: .canonical)
        #expect(try parse(text) == .document(document), Comment(rawValue: text))
        #expect(text.contains("{\"$numberLong\":\"9007199254740993\"}"))
        #expect(text.contains("{\"$numberInt\":\"1\"}"))
        #expect(text.contains("{\"$numberDecimal\":\"1.50\"}"))
    }

    @Test func relaxedIsReadableAndKeepsWhatItCan() throws {
        let document = BSONDocument([
            "n": .int32(1), "big": .int64(5_000_000_000), "f": .double(1.5), "whole": .double(2),
            "date": .date(milliseconds: 1_709_634_030_123), "oid": .objectId(Array(0..<12)),
            "dec": .decimal128(try Decimal128Value("0.1")), "inf": .double(.infinity),
        ])
        let text = ExtendedJSON.string(document, mode: .relaxed)
        #expect(text == "{\"n\":1,\"big\":5000000000,\"f\":1.5,\"whole\":2.0,\"date\":{\"$date\":\"2024-03-05T10:20:30.123Z\"},\"oid\":{\"$oid\":\"000102030405060708090a0b\"},\"dec\":{\"$numberDecimal\":\"0.1\"},\"inf\":{\"$numberDouble\":\"Infinity\"}}")
        #expect(try parse(text) == .document(BSONDocument([
            "n": .int32(1), "big": .int64(5_000_000_000), "f": .double(1.5), "whole": .double(2),
            "date": .date(milliseconds: 1_709_634_030_123), "oid": .objectId(Array(0..<12)),
            "dec": .decimal128(try Decimal128Value("0.1")), "inf": .double(.infinity),
        ])))
    }

    @Test func datesOutsideTheRelaxedRangeUseTheLongForm() throws {
        let early = BSONValue.date(milliseconds: -1)  // 1969
        #expect(ExtendedJSON.string(early) == "{\"$date\":{\"$numberLong\":\"-1\"}}")
        #expect(try parse(ExtendedJSON.string(early)) == early)
        let far = BSONValue.date(milliseconds: 253_402_300_800_000)  // year 10000
        #expect(ExtendedJSON.string(far).contains("$numberLong"))
        #expect(try parse(ExtendedJSON.string(far)) == far)
        #expect(try parse("{\"$date\":\"2024-03-05T12:20:30+02:00\"}") == .date(milliseconds: 1_709_634_030_000))
        #expect(try parse("{\"$date\":\"1970-01-01T00:00:00Z\"}") == .date(milliseconds: 0))
        #expect(try parse("{\"$date\":\"2000-02-29T23:59:59.5Z\"}") == .date(milliseconds: 951_868_799_500))
    }

    @Test func plainNumbersPickTheNarrowestExactType() throws {
        #expect(try parse("5") == .int32(5))
        #expect(try parse("-2147483648") == .int32(.min))
        #expect(try parse("2147483648") == .int64(2_147_483_648))
        #expect(try parse("9223372036854775807") == .int64(.max))
        #expect(try parse("1.0") == .double(1))
        #expect(try parse("1e3") == .double(1000))
        #expect(try parse("9223372036854775808") == .double(9_223_372_036_854_775_808))
    }

    @Test func queryOperatorsStayOrdinaryFields() throws {
        let filter = try ExtendedJSON.parseDocument(
            "{\"age\": {\"$gt\": 18, \"$lt\": 65}, \"name\": {\"$regex\": \"^a\", \"$options\": \"i\"}, \"_id\": {\"$in\": [{\"$oid\": \"000102030405060708090a0b\"}]}, \"$or\": [{\"a\": 1}]}"
        )
        #expect(filter["age"] == .document(BSONDocument(["$gt": .int32(18), "$lt": .int32(65)])))
        #expect(filter["name"] == .document(BSONDocument(["$regex": .string("^a"), "$options": .string("i")])))
        #expect(filter["_id"] == .document(BSONDocument(["$in": .array([.objectId(Array(0..<12))])])))
        #expect(filter["$or"] != nil)
    }

    @Test func anEmptyBoxMeansNoFilter() throws {
        #expect(try ExtendedJSON.parseDocument("   \n").isEmpty)
        #expect(try ExtendedJSON.parseDocument("{}").isEmpty)
        #expect(throws: ExtendedJSONError.self) { _ = try ExtendedJSON.parseDocument("[1]") }
    }

    @Test func stringsEscapesAndSurrogatePairs() throws {
        #expect(try parse("\"a\\n\\t\\\"\\\\\\/\\u00e9\"") == .string("a\n\t\"\\/é"))
        #expect(try parse("\"\\ud83d\\ude00\"") == .string("😀"))
        #expect(ExtendedJSON.string(.string("a\n\"\u{01}é😀")) == "\"a\\n\\\"\\u0001é😀\"")
        #expect(throws: ExtendedJSONError.self) { _ = try parse("\"\\ud83d\"") }
    }

    @Test func syntaxErrorsReportWhereTheyAre() {
        do {
            _ = try ExtendedJSON.parse("{\"a\": 1,\n \"b\": }")
            Issue.record("expected an error")
        } catch let error as ExtendedJSONError {
            #expect(error.offset == 15, Comment(rawValue: "offset was \(String(describing: error.offset))"))
        } catch {
            Issue.record("wrong error \(error)")
        }
        #expect(throws: ExtendedJSONError.self) { _ = try ExtendedJSON.parse("{\"a\": 1} trailing") }
        #expect(throws: ExtendedJSONError.self) { _ = try ExtendedJSON.parse("{a: 1}") }
        #expect(throws: ExtendedJSONError.self) { _ = try ExtendedJSON.parse("[1, 2,]") }
        #expect(throws: ExtendedJSONError.self) { _ = try ExtendedJSON.parse("01") }
        #expect(throws: ExtendedJSONError.self) { _ = try ExtendedJSON.parse("-007") }
        #expect((try? ExtendedJSON.parse("0.5")) == .double(0.5))
        #expect((try? ExtendedJSON.parse("-0")) == .int32(0))
        #expect(throws: ExtendedJSONError.self) { _ = try ExtendedJSON.parse("1e999") }
    }

    @Test func badWrappersAreErrorsNotSilentStrings() {
        #expect(throws: ExtendedJSONError.self) { _ = try parse("{\"$oid\": \"xyz\"}") }
        #expect(throws: ExtendedJSONError.self) { _ = try parse("{\"$numberInt\": \"3000000000\"}") }
        #expect(throws: ExtendedJSONError.self) { _ = try parse("{\"$numberDecimal\": \"1.2.3\"}") }
        #expect(throws: ExtendedJSONError.self) { _ = try parse("{\"$date\": \"yesterday\"}") }
    }

    @Test func tooDeepJSONIsRefused() {
        let text = String(repeating: "[", count: 500) + String(repeating: "]", count: 500)
        #expect(throws: ExtendedJSONError.tooDeep) { _ = try ExtendedJSON.parse(text) }
    }

    @Test func prettyOutputIsIndentedAndReparses() throws {
        let document = BSONDocument(["a": .int32(1), "b": .array([.int32(2), .document(BSONDocument(["c": .null]))]), "e": .document(BSONDocument())])
        let text = ExtendedJSON.string(document, pretty: true)
        #expect(text == "{\n  \"a\": 1,\n  \"b\": [\n    2,\n    {\n      \"c\": null\n    }\n  ],\n  \"e\": {}\n}")
        #expect(try parse(text) == .document(document))
    }

    @Test func uuidWrapperBecomesBinarySubtype4() throws {
        let value = try parse("{\"$uuid\": \"a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11\"}")
        guard case .binary(let subtype, let bytes) = value else { Issue.record("expected binary"); return }
        #expect(subtype == 4)
        #expect(bytes.count == 16)
        #expect(bytes.first == 0xA0)
    }
}
