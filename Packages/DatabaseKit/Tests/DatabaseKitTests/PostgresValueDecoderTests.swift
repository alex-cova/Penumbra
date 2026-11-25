import Foundation
import Testing

@testable import DatabaseKit

/// Hand-built wire bytes, in PostgreSQL's binary formats. The live oracle test below checks the
/// same decoder against what a real server prints.
struct PostgresValueDecoderTests {
    private func be(_ value: Int64, bytes: Int) -> [UInt8] {
        (0..<bytes).map { UInt8(truncatingIfNeeded: value >> (8 * (bytes - 1 - $0))) }
    }

    private func decode(_ oid: UInt32, _ bytes: [UInt8]?) -> DatabaseValue {
        PostgresValueDecoder.decode(oid: oid, isBinary: true, bytes: bytes)
    }

    @Test func nullEmptyAndZeroAreDistinct() {
        #expect(decode(25, nil) == .null)
        #expect(decode(25, []) == .text(""))
        #expect(decode(23, be(0, bytes: 4)) == .int(0))
        #expect(decode(17, []) == .bytes(count: 0, prefix: []))
    }

    @Test func integersAndBooleans() {
        #expect(decode(21, be(-7, bytes: 2)) == .int(-7))
        #expect(decode(23, be(42, bytes: 4)) == .int(42))
        #expect(decode(20, be(9_007_199_254_740_993, bytes: 8)) == .int(9_007_199_254_740_993))
        #expect(decode(16, [1]) == .bool(true))
        #expect(decode(16, [0]) == .bool(false))
        #expect(decode(26, be(4_000_000_000, bytes: 4)) == .uint(4_000_000_000))
        // A wrong-length payload is not guessed at.
        #expect(decode(23, [0, 1]).presence == .binary)
    }

    @Test func floats() {
        #expect(decode(701, be(Int64(bitPattern: UInt64(1.5.bitPattern)), bytes: 8)) == .double(1.5))
        #expect(decode(700, be(Int64(Float(2.25).bitPattern), bytes: 4)) == .double(2.25))
    }

    @Test func numericIsExactText() {
        // 12345.6789 with dscale 4: groups [1, 2345, 6789], weight 1.
        let value = be(3, bytes: 2) + be(1, bytes: 2) + be(0, bytes: 2) + be(4, bytes: 2)
            + be(1, bytes: 2) + be(2345, bytes: 2) + be(6789, bytes: 2)
        #expect(decode(1700, value) == .decimal("12345.6789"))
        // -0.05 with dscale 2: one group 500, weight -1.
        let small = be(1, bytes: 2) + be(-1, bytes: 2) + be(0x4000, bytes: 2) + be(2, bytes: 2) + be(500, bytes: 2)
        #expect(decode(1700, small) == .decimal("-0.05"))
        // 100 with dscale 0: weight 0, group 100.
        #expect(decode(1700, be(1, bytes: 2) + be(0, bytes: 2) + be(0, bytes: 2) + be(0, bytes: 2) + be(100, bytes: 2)) == .decimal("100"))
        // 10000: groups [1] with weight 1 (the second integer group is an implicit zero).
        #expect(decode(1700, be(1, bytes: 2) + be(1, bytes: 2) + be(0, bytes: 2) + be(0, bytes: 2) + be(1, bytes: 2)) == .decimal("10000"))
        // 0 with dscale 3.
        #expect(decode(1700, be(0, bytes: 2) + be(0, bytes: 2) + be(0, bytes: 2) + be(3, bytes: 2)) == .decimal("0.000"))
        // NaN.
        #expect(decode(1700, be(0, bytes: 2) + be(0, bytes: 2) + be(0xC000, bytes: 2) + be(0, bytes: 2)) == .decimal("NaN"))
    }

    @Test func datesAndTimestamps() {
        #expect(decode(1082, be(0, bytes: 4)) == .temporal("2000-01-01", .date))
        #expect(decode(1082, be(8_830, bytes: 4)) == .temporal("2024-03-05", .date))
        #expect(decode(1082, be(-1, bytes: 4)) == .temporal("1999-12-31", .date))
        #expect(decode(1082, be(Int64(Int32.max), bytes: 4)) == .temporal("infinity", .date))
        // 2024-03-05 10:20:30 UTC in microseconds since 2000-01-01.
        let micros = (8_830 * 86_400 + 10 * 3_600 + 20 * 60 + 30) * 1_000_000 as Int64
        #expect(decode(1184, be(micros, bytes: 8)) == .temporal("2024-03-05 10:20:30+00", .timestampWithZone))
        #expect(decode(1114, be(micros + 120_000, bytes: 8)) == .temporal("2024-03-05 10:20:30.12", .timestamp))
        #expect(decode(1114, be(Int64.min, bytes: 8)) == .temporal("-infinity", .timestamp))
        #expect(decode(1083, be(3_661_000_001, bytes: 8)) == .temporal("01:01:01.000001", .time))
    }

    @Test func intervals() {
        // 1 year 2 mons 3 days 04:05:06
        let micros = (4 * 3_600 + 5 * 60 + 6) * 1_000_000 as Int64
        #expect(decode(1186, be(micros, bytes: 8) + be(3, bytes: 4) + be(14, bytes: 4))
            == .temporal("1 year 2 mons 3 days 04:05:06", .interval))
        #expect(decode(1186, be(0, bytes: 8) + be(0, bytes: 4) + be(0, bytes: 4)) == .temporal("00:00:00", .interval))
    }

    @Test func uuidJsonAndText() {
        let id: [UInt8] = [0xA0, 0xEE, 0xBC, 0x99, 0x9C, 0x0B, 0x4E, 0xF8, 0xBB, 0x6D, 0x6B, 0xB9, 0xBD, 0x38, 0x0A, 0x11]
        #expect(decode(2950, id) == .uuid("a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"))
        #expect(decode(3802, [1] + Array("{\"a\": 1}".utf8)) == .json("{\"a\": 1}"))
        // jsonb without its version byte is not treated as JSON; the generic fallback shows
        // printable UTF-8 as text.
        #expect(decode(3802, Array("{}".utf8)) == .text("{}"))
        #expect(decode(3802, [2, 0xFF]).presence == .binary)
        #expect(decode(25, Array("héllo".utf8)) == .text("héllo"))
    }

    @Test func arraysKeepNullsAndNesting() {
        // int4[] {1,NULL,3}
        var bytes = be(1, bytes: 4) + be(1, bytes: 4) + be(23, bytes: 4) + be(3, bytes: 4) + be(1, bytes: 4)
        bytes += be(4, bytes: 4) + be(1, bytes: 4) + be(-1, bytes: 4) + be(4, bytes: 4) + be(3, bytes: 4)
        #expect(decode(1007, bytes) == .array([.int(1), .null, .int(3)]))
        // empty array
        #expect(decode(1007, be(0, bytes: 4) + be(0, bytes: 4) + be(23, bytes: 4)) == .array([]))
        // 2x2 int4[][]
        var matrix = be(2, bytes: 4) + be(0, bytes: 4) + be(23, bytes: 4)
        matrix += be(2, bytes: 4) + be(1, bytes: 4) + be(2, bytes: 4) + be(1, bytes: 4)
        for value in 1...4 { matrix += be(4, bytes: 4) + be(Int64(value), bytes: 4) }
        #expect(decode(1007, matrix) == .array([.array([.int(1), .int(2)]), .array([.int(3), .int(4)])]))
    }

    @Test func hostileArrayHeadersAreRejectedNotTrapped() {
        // Dimensions that overflow when multiplied, and a count far beyond the payload.
        var bytes = be(3, bytes: 4) + be(0, bytes: 4) + be(23, bytes: 4)
        for _ in 0..<3 { bytes += be(Int64(Int32.max), bytes: 4) + be(1, bytes: 4) }
        #expect(decode(1007, bytes).presence == .binary)
        let huge = be(1, bytes: 4) + be(0, bytes: 4) + be(23, bytes: 4) + be(1_000_000, bytes: 4) + be(1, bytes: 4)
        #expect(decode(1007, huge).presence == .binary)
        // Truncated payload.
        #expect(decode(1007, [0, 0]).presence == .binary)
    }

    @Test func networkTypes() {
        #expect(decode(869, [2, 32, 0, 4, 192, 168, 0, 1]) == .text("192.168.0.1"))
        #expect(decode(869, [2, 24, 0, 4, 10, 0, 0, 0]) == .text("10.0.0.0/24"))
        #expect(decode(650, [2, 8, 1, 4, 10, 0, 0, 0]) == .text("10.0.0.0/8"))
        let v6: [UInt8] = [3, 128, 0, 16, 0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 11) + [1]
        #expect(decode(869, v6) == .text("2001:db8::1"))
        #expect(decode(829, [0x08, 0x00, 0x2b, 0x01, 0x02, 0x03]) == .text("08:00:2b:01:02:03"))
    }

    @Test func largeValuesAreBoundedNotCopiedWhole() {
        let limits = ValueLimits(maxTextBytes: 100, binaryPrefix: 8)
        let longText = Array(String(repeating: "é", count: 500).utf8)
        let value = PostgresValueDecoder.decode(oid: 25, isBinary: true, bytes: longText, limits: limits)
        guard case .truncated(let preview, let full) = value else {
            Issue.record("expected a truncated value, got \(value)")
            return
        }
        #expect(full == longText.count)
        #expect(preview.utf8.count <= 100)
        #expect(!preview.contains("\u{FFFD}"), "cut on a character boundary")
        let blob = PostgresValueDecoder.decode(oid: 17, isBinary: true, bytes: [UInt8](repeating: 7, count: 5_000_000), limits: limits)
        #expect(blob == .bytes(count: 5_000_000, prefix: [UInt8](repeating: 7, count: 8)))
    }

    @Test func unknownTypesFallBackSafely() {
        // An enum label arrives as UTF-8 text under a user-defined OID.
        #expect(decode(16_500, Array("shipped".utf8)) == .text("shipped"))
        // Extension binary (for example PostGIS EWKB) is kept as bounded bytes, not garbage text.
        let ewkb: [UInt8] = [0x01, 0x01, 0x00, 0x00, 0x20, 0xE6, 0x10, 0x00, 0x00, 0xFF]
        #expect(decode(16_501, ewkb).presence == .binary)
    }

    @Test func textFormatIsHandledToo() {
        #expect(PostgresValueDecoder.decode(oid: 23, isBinary: false, bytes: Array("42".utf8)) == .int(42))
        #expect(PostgresValueDecoder.decode(oid: 16, isBinary: false, bytes: Array("t".utf8)) == .bool(true))
        #expect(PostgresValueDecoder.decode(oid: 1700, isBinary: false, bytes: Array("1.50".utf8)) == .decimal("1.50"))
        #expect(PostgresValueDecoder.decode(oid: 25, isBinary: false, bytes: []) == .text(""))
    }
}
