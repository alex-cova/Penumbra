import Foundation
import Testing

@testable import DatabaseKit

/// Live probes against the disposable servers from `Scripts/db-test-env.sh`. Skipped (with the
/// reason in the test name) unless `UMBRA_DB_INTEGRATION=1`, so CI without Docker stays green.
private let liveEnabled = ProcessInfo.processInfo.environment["UMBRA_DB_INTEGRATION"] == "1"

private func login(_ variable: String) throws -> SQLLogin {
    guard let url = ProcessInfo.processInfo.environment[variable] else {
        throw DatabaseError.executionFailed("\(variable) is not set; run Scripts/db-test-env.sh env")
    }
    return try SQLURLs.parse(url)
}

@Suite(.enabled(if: liveEnabled, "needs UMBRA_DB_INTEGRATION=1 and Scripts/db-test-env.sh up"))
struct LiveBaselineTests {
    /// Audit findings F-02 and F-22. This probe recorded the broken behaviour (typed values as
    /// binary garbage, `''` collapsing to NULL); it now pins the fixed one. The full type matrix is
    /// `LivePostgresTypeTests`.
    @Test func postgresTypedValuesAreReadable() async throws {
        let session = try await SQLSession.connect(login: login("UMBRA_TEST_PG_URL"), readOnly: true)
        defer { Task { await session.disconnect() } }
        let result = try await session.query(
            """
            SELECT 42::int4 AS i4, 9007199254740993::int8 AS i8, 1.5::float8 AS f8,
                   12345.6789::numeric(10,4) AS num, true AS flag,
                   '2024-03-05 10:20:30+00'::timestamptz AS ts, '2024-03-05'::date AS d,
                   'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11'::uuid AS u,
                   '{"a":1}'::jsonb AS j, ARRAY[1,2,3] AS arr, '\\xdeadbeef'::bytea AS b,
                   NULL::text AS n, ''::text AS empty
            """
        )
        let row = Dictionary(uniqueKeysWithValues: zip(result.columns, result.rows[0]))
        #expect(row["i4"]! == "42")
        #expect(row["i8"]! == "9007199254740993")
        #expect(row["f8"]! == "1.5")
        #expect(row["num"]! == "12345.6789")
        #expect(row["flag"]! == "true")
        #expect(row["ts"]! == "2024-03-05 10:20:30+00")
        #expect(row["d"]! == "2024-03-05")
        #expect(row["u"]! == "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11")
        #expect(row["arr"]! == "{1,2,3}")
        #expect(row["b"]! == "\\xdeadbeef")
        // NULL and the empty string are different values.
        #expect(row["n"]! == nil)
        #expect(row["empty"]! == "")
    }

    /// Before: this query returned all 1,000,000 rows (8.5 s, +193 MB resident, debug build; see
    /// PERFORMANCE_BASELINE.md M-1). The facade now stops at `userRowLimit`, so the same query
    /// returns the first 100,000 rows and tells the server to stop.
    @Test func postgresMillionRowQueryIsNowBoundedByTheFacade() async throws {
        let session = try await SQLSession.connect(login: login("UMBRA_TEST_PG_URL"), readOnly: true)
        defer { Task { await session.disconnect() } }
        _ = try await session.query("SELECT 1")  // warm the connection
        func residentMegabytes() -> Double {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            _ = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            return Double(info.resident_size) / 1_048_576
        }
        let before = residentMegabytes()
        let start = ContinuousClock.now
        let result = try await session.query(
            "SELECT g::text AS id, md5(g::text) AS hash, 'row ' || g AS label FROM generate_series(1, 1000000) g"
        )
        let elapsed = ContinuousClock.now - start
        let after = residentMegabytes()
        print("PGMILLION rows=\(result.rows.count) seconds=\(elapsed) rssBeforeMB=\(Int(before)) rssAfterMB=\(Int(after))")
        #expect(result.rows.count == SQLSession.userRowLimit)
        #expect(after - before < 100, "resident memory grew by \(Int(after - before)) MB")
    }
}
