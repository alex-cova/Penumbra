# Test strategy

## Principles

1. **Real databases first.** A feature that touches a server is tested against a server. Fakes (`SQLExecuting` stubs) remain for pure logic, never as evidence that a driver behaves.
2. **Exact expectations.** Completion tests assert the full candidate list in order; type tests compare every cell; mutation tests assert the generated statement and bound parameters.
3. **No weakened tests.** A failing test is fixed at its cause. Timeouts are not raised to hide a race.
4. **Skips are explained.** Every skip names its reason in the test name or `.enabled(if:)` comment, and the final report lists each one.
5. **Nothing destructive against user data.** Live tests run only against the disposable `umbra-dbtest-*` containers or temp files.
6. **No paid services in CI.** AI tests use `MockLLMClient`. Live-provider tests, if any, are opt-in.

## Layers

| Layer | Package | Runs when | Examples |
|---|---|---|---|
| Pure unit | `Packages/DatabaseKit/Tests` | always | read-only scan, URL parsing, `DatabaseValue` formatting, `ResultStore` bounds and spill, mutation planner SQL, export writers, splitter and completion corpora |
| SQLite | same | always (temp files, `:memory:`) | open/create/validate, introspection, STRICT / WITHOUT ROWID / generated columns, locks and `SQLITE_BUSY`, WAL + backup, corrupt header, read-only file, interrupt |
| Live servers | same, `@Suite(.enabled(if: UMBRA_DB_INTEGRATION == "1"))` | `Scripts/db-test-env.sh up`, then `UMBRA_DB_INTEGRATION=1 swift test --package-path Packages/DatabaseKit` | type matrix per engine, session pinning, cancel, read-only enforcement, TLS modes, transactions and savepoints, introspection of the seeded schema, Mongo BSON round trip and replica-set features |
| App | `Umbra/Tests/UmbraTests` | always; UI drivers with `UMBRA_UI_TESTS=1` | runtime coordination, stale-run rejection, console binding, tab-close guards, shortcut conflicts, grid model, export dialog model, agent tools with `MockLLMClient`, accessibility labels |
| Performance | `Tools/PerfHarness` (`database-*` commands) | manual, release build | first-row latency, RSS, scroll frame times, completion latency, export throughput |

Test workspaces set `IDEWorkspace.isSessionPersistenceEnabled = false` and use `IDEDatabaseMemoryKeyStore` so no real session file or Keychain item is touched.

## Seeded schema (`Scripts/db-test-env.sh` / fixtures)

PostgreSQL: composite primary and foreign keys, a table with two relationships to the same parent, identity and generated columns, enum and composite types, `jsonb`, arrays, `numeric(38,10)`, `timestamptz`, partitioned table, materialized view, sequence, function, trigger, a PostGIS table, a 1M-row table, and a restricted role.
MySQL: InnoDB and MyISAM tables, generated and unsigned columns, `ENUM`/`SET`, `JSON`, binary, non-default collations, routines, triggers, an event, a restricted user.
MongoDB: collections with nested documents and arrays, every BSON type including `Decimal128`, `Timestamp`, `BinData`, regex; documents with a missing field next to documents with an explicit `null`; a 2dsphere index; a capped collection; a validator.
SQLite: generated per test from the same DDL where the dialect allows.

## SQL intelligence corpus

Each case is `(dialect, catalog fixture, text with a caret marker, expected candidates)` with the whole list asserted. Required groups: incomplete statements; aliases; nested and correlated subqueries; CTEs, recursive CTEs; JOIN predicates from single, composite and multiple foreign keys; quoted identifiers; ambiguous references; multiple schemas; schema change between two requests; dialect-specific functions and keywords; invalid SQL; **offline or partial catalog** (no false "unknown table"); rapidly cancelled requests (stale result never delivered).

## Regression requirements

Before each phase is called done: `swift test --package-path Packages/DatabaseKit`, the live suite, `swift test --package-path Umbra`, `swift test` (root), Debug and Release builds, and the Xcode project build. Pre-existing failures are recorded below and kept separate from regressions.

## Baseline failures (before this work)

Baseline runs were taken after the first interim change (hardened read-only keyword check) and before any session or value changes.

| Suite | Result |
|---|---|
| `swift test --package-path Packages/DatabaseKit` | 25 tests passed (23 original + 2 new read-only tests) |
| `swift test --package-path Umbra` | 3,401 XCTest cases, 63 skipped, **1 failure**: `IDEACPAdapterStoreTests.testALaunchDuringActivationsAlwaysFindsACompleteVerifiedVersion` ("a launch raced": `unsafeTree("index.js")`). It is in the ACP adapter store and is unrelated to databases; it is recorded here as a pre-existing failure and is not touched by this work. Swift Testing suites in the same run passed |
| `swift test` (root) | 5,668 XCTest cases, 26 skipped, **0 failures** (exit 0), 690 s |

## After Phases 0–2 (this work so far)

| Suite | Result |
|---|---|
| `swift test --package-path Packages/DatabaseKit` (live servers up: `UMBRA_DB_INTEGRATION=1`) | 136 tests in 25 suites passed (SQLite 30, BSON/Decimal128/Extended JSON, PostgreSQL and MySQL value decoders, PostgreSQL/MySQL/MongoDB live sessions and facades, TLS, URL parsing, identifier quoting) |
| same, `DatabaseCoreTests` | 43 tests in 6 suites passed |
| `swift test --package-path Umbra` (full) | 3,417 XCTest cases (baseline 3,401: +16 database tests at that point), 63 skipped (same as baseline), **1 failure: the same pre-existing `IDEACPAdapterStoreTests.testALaunchDuringActivationsAlwaysFindsACompleteVerifiedVersion`**. No new failure. Tests added after that run (SQLite fallback visibility, cancel end to end) were run as a filtered set: `IDESQLiteSourceTests|IDEDatabase*|IDEMenuShortcuts*|IDEKeymapPreset*|IDEModuleContribution*|IDELanguageModule*`, 0 failures |
| `swift test` (root) | not re-run: the root package does not depend on `DatabaseKit` or Umbra (baseline above stands) |

## Phase 4 verification

| Suite | Result |
|---|---|
| DatabaseKit with dedicated PostgreSQL, MySQL and MongoDB containers | 140 driver and facade tests, 76 SQL intelligence tests and 43 DatabaseCore tests passed. Live coverage includes the PostgreSQL composite key and generated and identity flags, plus native PostgreSQL and MySQL parameter bindings. SQLite tests verify bound text with embedded NUL and explicit NULL through paging. |
| Umbra full run before the final formatter, scope and pagination changes | 3,397 XCTest cases, 63 skipped, and 8 failed assertions in one Java debugger case, `testPauseStopsARunningProgramAndRefusesASecondPause`. That case passed in isolation. The 42 Swift Testing cases passed. The run included the new SQLite console selection and parameter prompt test. |
| Umbra database, SQLite, shortcuts and language services | 75 focused tests passed on the final app code. |
| Shared editor navigation | 88 focused root-package tests passed. |
| Umbra Xcode project | macOS Debug build passed with code signing disabled. |
| Umbra SwiftPM Release | Build passed. |

The execution diagnostics follow-up verified a real PostgreSQL error through pagination and parameter rewriting and a real MySQL query with a warning. The SQLite console test verified the editor range in a selected, bound query containing Unicode and confirmed that a later edit clears it. All 60 focused Umbra tests passed. The SQL splitter suite also covers a position inside a rewritten placeholder, end of input, and invalid offsets.

The history and scope follow-up passed 106 focused Umbra tests, all 267 DatabaseKit tests with the disposable servers, and the macOS Debug Xcode build. The live cases verify PostgreSQL schema quoting and matching execution and metadata scopes, refusal to switch an open transaction, preservation of old stored rows after switching, and cancellation from both the task and the session. MySQL cases verify warnings and affected-row counts for text and parameterized writes, zero-warning row-count behavior, and headers on empty text results. History tests verify redaction on disk, bounded retention, and recording completed and failed statements.

## Phase 5 verification

- All 265 DatabaseKit tests passed with the disposable servers. Coverage includes PostgreSQL's million-row store test, 10,000 MySQL rows through socket read watermarks and spill, MongoDB grid columns discovered across cursor batches, and byte-limited chunks read back after spilling.
- All 62 focused Umbra tests passed. They check first-row publication during execution, a native grid scroll to a distant stored row, SQLite results that stay stable after the table changes, and store closure when the console closes.
- The Umbra Xcode Debug build passed with code signing disabled. Scroll frame timing and the Phase 5 grid comparison remain unmeasured.

## Phase 6 verification

- The 104 focused Umbra tests cover database results, SQLite, shortcuts and module integration. The new cases cover all ten chart types through `ImageRenderer`, bounded sampling, LTTB endpoints, histogram and scatter counts, date grouping and median, WGS84 rejection, WKB and antimeridian bounds. The native grid test verifies selecting and scrolling to a stored row. The SQLite workspace test confirms the generated aggregation opens a separate console, prompts for the bound value, and retains the source result.
- The Umbra macOS Debug Xcode build passed with code signing disabled.
- The disposable PostGIS and MySQL servers returned matching longitude-first coordinates from `ST_AsGeoJSON` and WKB with SRID 4326. Both servers accepted the generated grouping pattern. Desktop gesture, clipboard, save-panel and online basemap smoke checks remain open.

## Phase 9 verification

- All 139 focused Umbra tests passed with `UMBRA_UI_TESTS=1`. The native-window test used arrow keys and Return to connect, expand the schema, and open SQLite table data in both light and dark mode. The test checks behavior. Manual VoiceOver and visual checks remain open.
- The other Phase 9 tests cover explorer search and session restoration, the SQLite busy timeout, production approval before executing any statement in a batch, preservation of rows and dependent definitions during a supported SQLite rebuild, and rejection of stale rebuild previews.
- All 265 DatabaseKit tests passed with the disposable PostgreSQL, MySQL, and MongoDB servers. The Umbra macOS Debug Xcode build passed with code signing disabled. The Xcode project synchronization and whitespace checks passed.

## Skipped tests

None skipped by design yet. The live suites report as "not run" when `UMBRA_DB_INTEGRATION` is not `1`, and the final report states how many ran.
