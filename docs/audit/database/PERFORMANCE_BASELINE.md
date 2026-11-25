# Performance baseline

Rule for this document: a number appears only if it was measured, with the dataset, build, hardware and method next to it. Everything else says **not measured**. Targets are goals, not results.

## Reference hardware and toolchain

| | |
|---|---|
| Machine | Apple M5 Max, 64 GB RAM |
| OS | macOS 27.2.1 (Darwin 27.2.0) |
| Swift | 6.4.2 (swiftlang-6.4.2.1.9) |
| Servers | PostgreSQL 16 + PostGIS 3.4, MySQL 8.4, MongoDB 7 (single-node replica set), Docker containers on the same machine, loopback network |
| Build | **Debug** (`swift test`) unless stated. The performance rules say conclusions need a release build; every number below marked Debug is a baseline of the *old code path* only and will be re-measured in release before any before/after claim |

Loopback and a local container mean the server and network contribute almost nothing here. These figures isolate application cost, not what a remote production database feels like.

## Measured

### M-1 Library materializes a full result (PostgreSQL)

- **Where:** `LiveBaselineTests.postgresMillionRowMaterializationBaseline`
- **Query:** `SELECT g::text AS id, md5(g::text) AS hash, 'row ' || g AS label FROM generate_series(1, 1000000) g` through `SQLSession.query`
- **Method:** resident size from `task_info(MACH_TASK_BASIC_INFO)` before and after; wall clock around the call; one run.
- **Result (Debug):** 1,000,000 rows in **8.5 s**; resident memory **45 MB → 238 MB** (+193 MB, about 190 bytes per row for three short strings in `[[String?]]`).
- **Reading:** the whole result is held before anything is returned (audit F-05), so first-row latency equals total time and memory grows linearly. One run on a debug build: treat the order of magnitude as the finding, not the digits.

### M-2 Typed values (correctness, not speed)

See audit F-02: `int4`, `int8`, `float8`, `numeric`, `bool`, `date`, `timestamptz`, `int4[]`, `bytea` came back as binary garbage. This is recorded here because any throughput number for PostgreSQL is meaningless until values decode correctly.

### M-3 After Phase 1 (PostgreSQL), same machine, **Debug** build, loopback

| Scenario | Before | After |
|---|---|---|
| 1,000,000-row `SELECT` through the app-facing facade | 8.5 s, resident 45 → 238 MB, all rows returned | **2.1 s, resident 53 → 84 MB**, first 100,000 rows returned, server told to stop |
| 1,000,000 rows streamed into a `ResultStore` (16 MB ceiling) | not possible | 12.6 s total, **resident 16.8 MB**, 96 MB spilled to a 0600 temp file, all rows readable (the time is dominated by JSON-encoding spilled chunks in a debug build; to be re-measured in release) |
| 10,000,000-row lazy query with a 2,000-row limit | not possible (would read everything) | **0.41 s**, exactly 2,000 rows |
| Cancel a running `pg_sleep(30)` | no cancellation | **44 ms** from request until the statement stopped (side connection, `pg_cancel_backend`) |
| Value decoding correctness | integers/dates/arrays shown as binary | 82 expressions equal the server's own text |

MySQL 8.4, same conditions: cancel a running `SELECT SLEEP(30)` **9 ms** after the request; a 2,000-row limit on a `CROSS JOIN` of `information_schema.columns` returned in **0.33 s** with the session still usable. There is no before figure: MySQL had no cancellation and no limit.

SQLite (system 3.54.0, temp files, debug build): interrupting a statement that was running an unbounded recursive query returned control in **about 0.05 ms** (`SQLITECANCEL`); a 1,000-row limit on a 100,000,000-row recursive query finished in under 2 s; a plain file copy of a WAL database held **1,983 of 2,000 rows** (`SQLITEWAL`), which is why the backup API is used.

MongoDB 7 replica set, same conditions: `killOp` stopped a 30-second server-side `$where` sleep **12 ms** after the request.

One run each; debug build; local container. They show what changed, not final performance. Release-build numbers come in Phase 10. Note that `FROM generate_series(...)` is materialized by PostgreSQL before its first row, so a benchmark that wants streaming must use the function in the select list.

## Not yet measured (baseline work that remains in Phase 0/1)

| Item | Why it matters | Plan |
|---|---|---|
| Existing `NSTableView` grid: scroll frame times with 200 rows × 40 columns | The custom grid is justified only against this | Instruments Animation Hitches / frame-time probe in `PerfHarness database-grid` |
| Existing grid: `reloadData` main-thread time per update | Suspected full reload per update | Same |
| MySQL 1M-row materialization | Equivalent of M-1 | Add after seeding MySQL in `db-test-env.sh` |
| MongoDB 100k-document `find().drain()` | Same | Same |
| Completion latency (current keyword scan) with 10,000 tables | Reference for the new engine | Unit benchmark on `SQLCompletion.site` |
| Editor keystroke cost in a console | Must not regress | `swift run -c release PerfHarness enter-session synthetic --lines 20000` before and after |

## Budgets (targets, from the specification)

| Operation | Target | Measured |
|---|---|---|
| Cached SQL completion | P95 < 50 ms | not measured |
| Initial local completion candidates | < 20 ms where practical | not measured |
| Main-thread synchronous work during interaction | generally < 8 ms | not measured |
| Result grid scrolling | stable 60 FPS | not measured |
| Query cancellation feedback | < 100 ms | not measured (no cancellation exists) |
| Explorer interaction | no synchronous network I/O | not measured |
| Initial result rendering | incremental, without waiting for all rows | not met at baseline (M-1) |
| Export memory | bounded independent of output size | not met at baseline (whole string in memory) |
| Large result handling | no unbounded retention | not met at baseline (M-1) |
| Closing database tabs | releases resources | not measured |

## Scenario list for Phase 10

100 connections · 10,000 schema objects · 100+ column tables · 1M rows · 10M rows streamed · large BLOB/JSON values · exports over 1 GB · simultaneous queries · rapid cancel · many result tabs · repeated connect/disconnect · continuous metadata refresh · rapid typing in a console · concurrent AI requests.

Each will record: peak resident memory, memory growth after close, CPU, main-thread stalls, first-row latency, throughput, completion latency, frame times, export throughput, and cleanup.
