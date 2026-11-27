import Foundation
import Testing

@testable import DatabaseCore

struct DatabaseValueTests {
    @Test func nullMissingEmptyAndZeroAreFourDifferentThings() {
        let values: [DatabaseValue] = [.null, .missing, .text(""), .int(0)]
        #expect(values[0].presence == .null)
        #expect(values[1].presence == .missing)
        #expect(values[2].presence == .empty)
        #expect(values[3].presence == .value)
        // null and missing have no text; empty and zero do.
        #expect(values[0].displayText() == nil)
        #expect(values[1].displayText() == nil)
        #expect(values[2].displayText() == "")
        #expect(values[3].displayText() == "0")
        #expect(values[0] != values[1])
    }

    @Test func numbersKeepTheirExactText() {
        #expect(DatabaseValue.int(9_007_199_254_740_993).displayText() == "9007199254740993")
        #expect(DatabaseValue.uint(UInt64.max).displayText() == "18446744073709551615")
        #expect(DatabaseValue.decimal("12345.6789000000").displayText() == "12345.6789000000")
        #expect(DatabaseValue.double(1.5).displayText() == "1.5")
        #expect(DatabaseValue.double(.nan).displayText() == "NaN")
        #expect(DatabaseValue.double(-.infinity).displayText() == "-Infinity")
    }

    @Test func floatsUseShortestDigitsWithoutATrailingZero() {
        let cases: [(Double, String)] = [
            (100_000, "100000"), (0.1, "0.1"), (1.5, "1.5"), (-2.25, "-2.25"), (0.0001, "0.0001"),
            (0.00001, "1e-05"), (123456789.123, "123456789.123"), (1e14, "100000000000000"),
            (1e15, "1e+15"), (1.5e20, "1.5e+20"), (1.234e-7, "1.234e-07"), (0, "0"),
            (-0.0, "-0"), (5e-324, "5e-324"), (1.7976931348623157e308, "1.7976931348623157e+308"),
        ]
        for (value, expected) in cases {
            #expect(DatabaseValue.format(double: value) == expected, "\(value)")
        }
    }

    @Test func longTextIsBoundedAndSingleLine() {
        let long = String(repeating: "x", count: 10_000)
        let shown = DatabaseValue.text(long).displayText() ?? ""
        #expect(shown.count <= DatabaseValue.displayLimit + 1)
        #expect(shown.hasSuffix("…"))
        #expect(DatabaseValue.text("a\nb\tc").displayText() == "a↵b⇥c")
        // The raw text for copy is not bounded.
        #expect(DatabaseValue.text(long).rawText == long)
    }

    @Test func binaryShowsASizeNotBytes() {
        let value = DatabaseValue.bytes(count: 2_097_152, prefix: [0xDE, 0xAD])
        #expect(value.presence == .binary)
        #expect(value.displayText()?.hasPrefix("‹") == true)
        #expect(value.displayText()?.contains("MB") == true)
        // A fully-loaded small blob copies as hex.
        #expect(DatabaseValue.bytes(count: 4, prefix: [0xDE, 0xAD, 0xBE, 0xEF]).rawText == "\\xdeadbeef")
    }

    @Test func arraysAreBoundedAndKeepNulls() {
        let array = DatabaseValue.array([.int(1), .null, .text("a")])
        #expect(array.displayText() == "{1, NULL, a}")
        let big = DatabaseValue.array((0..<100).map { .int(Int64($0)) })
        #expect(big.displayText()?.contains("+92") == true)
    }

    @Test func truncatedValuesSayHowMuchWasCut() {
        let value = DatabaseValue.truncated(preview: "abc", fullCount: 5_000_000)
        #expect(value.presence == .truncated)
        #expect(value.displayText() == "abc… (5000000)")
    }

    @Test func codableRoundTripPreservesEveryCase() throws {
        let values: [DatabaseValue] = [
            .null, .missing, .bool(true), .int(-7), .uint(UInt64.max), .double(2.25),
            .double(.infinity), .decimal("0.10"), .text(""), .text("héllo"),
            .bytes(count: 9, prefix: [1, 2, 3]), .temporal("2024-03-05", .date),
            .json("{\"a\":1}"), .uuid("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"),
            .array([.int(1), .null]), .geometry("POINT(1 2)"),
            .bson(typeName: "objectId", extendedJSON: "{\"$oid\":\"507f1f77bcf86cd799439011\"}"),
            .truncated(preview: "x", fullCount: 99), .unloaded,
        ]
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        let decoded = try decoder.decode([DatabaseValue].self, from: encoder.encode(values))
        #expect(decoded == values)
    }
}

struct SecretRedactorTests {
    @Test func urlPasswordsAreRemoved() {
        #expect(
            SecretRedactor.redact("connect postgresql://app:s3cr3t!@db.example.com:5432/prod now")
                == "connect postgresql://app:***@db.example.com:5432/prod now"
        )
        #expect(
            SecretRedactor.redact("mongodb+srv://u:p%40ss@cluster0.mongodb.net/x")
                == "mongodb+srv://u:***@cluster0.mongodb.net/x"
        )
    }

    @Test func keyValueSecretsAreRemoved() {
        #expect(SecretRedactor.redact("password=hunter2 host=x") == "password=*** host=x")
        #expect(SecretRedactor.redact("PGPASSWORD=hunter2 pg_dump") == "PGPASSWORD=*** pg_dump")
        #expect(SecretRedactor.redact("{\"password\": \"hunter2\"}") == "{\"password\": ***}")
        #expect(SecretRedactor.redact("--password=hunter2 --user=x") == "--password=*** --user=x")
        #expect(SecretRedactor.redact("Authorization: Bearer abc.def.ghi") == "Authorization: Bearer ***")
    }

    @Test func tokensAndKeysAreRemoved() {
        #expect(SecretRedactor.redact("key AKIAABCDEFGHIJKLMNOP end") == "key *** end")
        #expect(SecretRedactor.redact("t ghp_abcdefghijklmnopqrstuv e") == "t *** e")
        let pem = "-----BEGIN PRIVATE KEY-----\nMIIE\n-----END PRIVATE KEY-----"
        #expect(SecretRedactor.redact("a \(pem) b") == "a *** b")
    }

    @Test func ordinaryTextIsUntouched() {
        let sql = "SELECT id, name FROM users WHERE password_changed_at > now() - interval '1 day'"
        #expect(SecretRedactor.redact(sql) == sql)
    }
}
