import Foundation
import Testing

@testable import DatabaseKit

private let liveEnabled = ProcessInfo.processInfo.environment["UMBRA_DB_INTEGRATION"] == "1"
    && ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != "true"  // never on the CI pipeline

/// The server is the oracle: for each expression, what our decoder shows for the value must equal
/// what PostgreSQL itself prints for `(expression)::text`. Runs end to end through
/// `SQLSession` (wire cell → `PostgresValueDecoder` → text).
@Suite(.enabled(if: liveEnabled, "needs UMBRA_DB_INTEGRATION=1 and Scripts/db-test-env.sh up"))
struct LivePostgresTypeTests {
    private func session() async throws -> SQLSession {
        guard let url = ProcessInfo.processInfo.environment["UMBRA_TEST_PG_URL"] else {
            throw DatabaseError.executionFailed("UMBRA_TEST_PG_URL is not set; run Scripts/db-test-env.sh env")
        }
        return try await SQLSession.connect(login: SQLURLs.parse(url), readOnly: true)
    }

    /// Expressions whose text form the decoder must reproduce exactly.
    private static let matching: [String] = [
        // integers, booleans
        "42::int2", "(-7)::int4", "9007199254740993::int8", "(-9223372036854775808)::int8",
        "true", "false",
        // floats
        "1.5::float8", "0.1::float8", "0.1::float4", "100000::float8", "1e15::float8",
        "1e14::float8", "1.5e20::float8", "0.00001::float8", "0.0001::float8", "(-2.25)::float4",
        "'NaN'::float8", "'Infinity'::float8", "'-Infinity'::float4", "123456789.123::float8",
        // numerics (exact)
        "12345.6789::numeric(10,4)", "(-0.05)::numeric", "100::numeric", "10000::numeric",
        "0::numeric(10,3)", "123456789012345678901234567890.123456789::numeric",
        "'NaN'::numeric", "0.00001234::numeric", "1e-20::numeric", "(-99999.99999)::numeric",
        "1::numeric(5,2)", "100000000::numeric",
        // text
        "''::text", "'héllo'::text", "'x y'::varchar(10)", "'tab\there'::text",
        // dates and times
        "'2024-03-05'::date", "'0044-03-15 BC'::date", "'infinity'::date", "'-infinity'::date",
        "'2024-03-05 10:20:30.123456'::timestamp", "'2024-03-05 10:20:30'::timestamp",
        "'2024-03-05 10:20:30+00'::timestamptz", "'1999-12-31 23:59:59.5'::timestamp",
        "'0001-01-01 00:00:00'::timestamp", "'infinity'::timestamp",
        "'10:20:30.5'::time", "'24:00:00'::time", "'10:20:30+05:30'::timetz", "'10:20:30-08'::timetz",
        // intervals
        "'1 year 2 mons 3 days 04:05:06'::interval", "'-1 day'::interval", "'1 mon'::interval",
        "'00:00:01.5'::interval", "'-00:00:01'::interval", "'1 day -02:00:00'::interval",
        "'0'::interval", "'14 months'::interval",
        // identifiers, documents, binary
        "'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid", "'{\"a\": [1, 2]}'::jsonb",
        "'{\"a\":  [1,2]}'::json", "'\\xdeadbeef'::bytea", "''::bytea",
        // arrays (elements that need no quoting)
        "ARRAY[1,2,3]", "ARRAY[1,NULL,3]", "ARRAY['a','b']", "ARRAY[[1,2],[3,4]]",
        "ARRAY[]::int4[]", "ARRAY[1.5,2]::numeric[]", "ARRAY[1,2]::int8[]", "ARRAY[0.5]::float8[]",
        // network and bits (`inet` has its own oracle below: `inet::text` always appends /32)
        "'10.0.0.0/24'::cidr", "'08:00:2b:01:02:03'::macaddr",
        "B'1011'::bit(4)", "B'10'::varbit",
    ]

    /// `inet` displays without a full-length mask, which is `abbrev()`'s output (psql shows the same).
    private static let inetExpressions: [String] = [
        "'192.168.0.1'::inet", "'10.0.0.0/24'::inet", "'::1'::inet", "'2001:db8::1'::inet",
        "'2001:db8:0:0:1:0:0:1'::inet", "'2001:db8::/32'::inet", "'ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff'::inet",
    ]

    @Test func decoderMatchesTheServersOwnText() async throws {
        let session = try await session()
        defer { Task { await session.disconnect() } }
        var mismatches: [String] = []
        for expression in Self.matching {
            let result = try await session.query("SELECT (\(expression)) AS v, (\(expression))::text AS t")
            guard let row = result.rows.first, row.count == 2 else {
                mismatches.append("\(expression): no row")
                continue
            }
            if row[0] != row[1] {
                mismatches.append("\(expression): decoded \(String(describing: row[0])) but server prints \(String(describing: row[1]))")
            }
        }
        for expression in Self.inetExpressions {
            let result = try await session.query("SELECT (\(expression)) AS v, abbrev(\(expression)) AS t")
            if let row = result.rows.first, row[0] != row[1] {
                mismatches.append("\(expression): decoded \(String(describing: row[0])) but server displays \(String(describing: row[1]))")
            }
        }
        #expect(mismatches.isEmpty, Comment(rawValue: "\n" + mismatches.joined(separator: "\n")))
    }

    @Test func fixedWidthCharKeepsItsPadding() async throws {
        let session = try await session()
        defer { Task { await session.disconnect() } }
        // `char(3)` is stored padded; only a cast to text strips it, so the value is "a  ".
        let result = try await session.query("SELECT 'a'::char(3) AS c")
        #expect(result.rows[0][0] == "a  ")
    }

    @Test func nullEmptyAndZeroSurviveTheWholePath() async throws {
        let session = try await session()
        defer { Task { await session.disconnect() } }
        let result = try await session.query("SELECT NULL::text AS n, ''::text AS e, 0::int4 AS z, ''::bytea AS eb")
        #expect(result.rows[0][0] == nil)
        #expect(result.rows[0][1] == "")
        #expect(result.rows[0][2] == "0")
        #expect(result.rows[0][3] == "\\x")
    }

    @Test func largeValuesDoNotBecomeHugeStrings() async throws {
        let session = try await session()
        defer { Task { await session.disconnect() } }
        let result = try await session.query("SELECT repeat('x', 5000000) AS big")
        let text = try #require(result.rows[0][0])
        // Bounded to the stored preview (64 KiB), not the full 5 MB.
        #expect(text.utf8.count <= ValueLimits.standard.maxTextBytes)
    }
}
