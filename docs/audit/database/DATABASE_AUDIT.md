# Database subsystem audit

Scope: `Packages/DatabaseKit` and `Umbra/Sources/Umbra/Database` as of the start of this work (about 4.9k lines, 37 tests: 23 in `DatabaseKit`, 14 in `UmbraTests`; none against a real server).

Every finding has a **status**:

- **Verified**: reproduced against a live server or by a test in this repository.
- **Code-read**: established from reading the code; not yet reproduced.

Severity: **Critical** (wrong data shown or written, or a safety promise broken), **High** (a feature cannot work at the scale or in the situations users will meet), **Medium** (incorrect or fragile, with a workaround).

Live evidence comes from `Scripts/db-test-env.sh` (PostgreSQL 16 + PostGIS, MySQL 8.4, MongoDB 7 replica set, on ports 55432 / 53306 / 57017) and `Packages/DatabaseKit/Tests/DatabaseKitTests/LiveBaselineTests.swift`.

---

## Status after Phase 1 (PostgreSQL and MySQL)

PostgreSQL and MySQL/MariaDB-protocol servers now run on the new single-connection session layer. **MongoDB and SQLite are unchanged** (SQLite does not exist yet). Evidence for MySQL was gathered against MySQL **8.4 only**; MariaDB and MySQL 5.7 are not tested.

| Finding | PostgreSQL | MySQL | Evidence |
|---|---|---|---|
| F-01 session pinning | **Fixed** | **Fixed** | `statementsOfOneSessionRunOnOneBackendAndATransactionIsReal` (PG), `statementsRunOnOneConnectionAndATransactionIsReal`, `sessionSettingsStayWithTheSession` (MySQL) |
| F-02 typed values | **Fixed**: 82 expressions equal the server's own text | **Fixed**: types and unsigned/charset decided by column metadata; exact decimals | `LivePostgresTypeTests`; `typedValuesArriveAsTheirTypes`, `MySQLValueDecoderTests`, `metadataStatementsDeliverTextNotBinary` |
| F-03 read-only | **Enforced by the server** (`BEGIN READ ONLY` per statement + session default) | **Enforced by the server** (`START TRANSACTION READ ONLY` per statement + session default; DDL, `TRUNCATE`, `CALL`, MyISAM writes all refused) | `readOnlySessionsAreRefusedByTheServer…` (both engines) |
| F-04 TLS downgrade | **Fixed for users who pick *Require*.** The sheet has a PostgreSQL TLS picker (Off / Prefer / Require); *Require* is TLS-or-fail with full verification. Existing connections and plain URLs stay on *Prefer*, shown in red as able to fall back to plain text; `sslmode=require` in an imported URL selects Require | Library enforces `requireTLS` (checks the server really negotiated a cipher; certificate failure is an error). **The sheet still shows the plain "Use TLS" checkbox for MySQL**, so users cannot choose it yet | `requiringTLSAgainstAServerWithoutTLSFailsInsteadOfDowngrading`, `requireTLSIsStrict`, `TLSModeTests`, `IDEDatabaseTLSChoiceTests`. Verified by tests, **not by looking at the sheet on screen** |
| F-05 unbounded results | **Bounded**: rows stream into `ResultStore` (ceiling + spill to disk); facade caps unpaged results at 100,000 rows; the server is told to stop | **Bounded**, but **no backpressure** (text protocol): the server keeps sending until it is killed; memory is bounded by the store | `aMillionRowsStreamIntoABoundedStore`, `aRowLimitStopsATenMillionRowQueryEarly`; `aRowLimitStopsAHugeJoinEarly` |
| F-07 cancellation | **Done**: 44 ms | **Done**: 9 ms (`KILL QUERY`) | `cancelling…ReturnsPromptly` (both). **No cancel control in the UI yet** (Phase 4) |
| F-08 shared result | Open (app layer, Phase 4) | Open | |
| F-09 `@unchecked Sendable` | `PostgresSession` and `MySQLSession` are actors with no escape hatch. The `SQLSession` facade still uses one until it is replaced | same | |
| F-22 empty vs NULL | **Fixed** | **Fixed** | `nullEmptyAndZeroSurviveTheWholePath`; `typedValuesArriveAsTheirTypes` |
| F-24 `run()` race | **Fixed** | n/a | |

### MongoDB (findings F-12 to F-16)

| Finding | Status | Evidence |
|---|---|---|
| F-12 values flattened to truncated strings | **Fixed in the library.** Documents are read as `BSONValue` (exact) and stored as canonical Extended JSON; large documents are bounded (`.truncated`). The console's string table still shows a flat projection (`MongoTable`) until the new grid (Phase 5) | `everyBSONTypeSurvivesTheServerExactly`: the server's own `$type` agrees for int, long, double, decimal, date, timestamp, binary, regex and ObjectId |
| F-13 missing vs explicit null | **Fixed in the model** (a missing field is the absence of a field; `.null` is a value). In the old string table a missing field is still `nil` and an explicit null is the text `null`; the new grid will draw them differently | `missingFieldsAndNullAreDifferent`, `BSONCodecTests.missingAndNullAreDifferent` |
| F-14 precision lost through `JSONSerialization` | **Fixed.** A purpose-built Extended JSON v2 reader/writer; Int64 above 2^53, Decimal128 (with trailing zeros), Timestamp and dates outside 1970–9999 round-trip. The BSON library's own `Decimal128` is a stub with no readable fields, so values never go through it | `Decimal128Tests` (corpus vectors, 34-digit limits), `ExtendedJSONTests`, `filtersAreExactExtendedJSONAndSortIsTheServers` (an `_id` of 9007199254740993 is found, not rounded) |
| F-15 whole-document replace | **Fixed for edits** via `setFields` (`$set`/`$unset` with the originally-seen values in the filter, so a concurrent change matches nothing and nothing is written). `replace` still exists, now refuses when the document is gone | `setFieldsChangesOnlyThoseFieldsAndRefusesStaleEdits`, `fieldLevelEditsDetectConcurrentChanges` |
| F-16 client-side page sort | **Fixed**: sort is the server's and is applied before paging, and the console reloads from page 1 | `filtersAreExactExtendedJSONAndSortIsTheServers` |

Also done for MongoDB: batch-by-batch cursors that are always killed (`serverStatus` shows no cursor left open after an early stop), cancellation by `killOp` (12 ms to stop a 30-second server-side `$where`), topology detection (transactions are offered only on a replica set or sharded cluster; none are implemented yet), `explain`, indexes (list/create/drop), collection stats, a separate catalog connection, and a 600 s socket timeout instead of the old 10 s that was meant only for connecting.

**What MongoDB read-only means.** `MongoDocumentSession` can only send the operations it defines; its writes refuse on a read-only session and `aggregate` refuses `$out` and `$merge`. MongoDB has no server-side read-only mode, so this is **not** server-enforced and `.serverEnforcedReadOnly` is never claimed. For a hard guarantee, connect with a user that has only the `read` role.

Not done for MongoDB: transactions, the aggregation pipeline editor, validation-rule editing, document duplication, the document tree/JSON/inspector views, charts and export.

### SQLite (new engine)

SQLite did not exist in the app before this work. It runs on the system `libsqlite3` (3.54.0 here, with column metadata) through `SQLiteSession`, and every claim below has a test against real files or `:memory:` databases (no server needed).

| Requirement | Status | Evidence |
|---|---|---|
| Open existing, create new, in-memory, read-only, several at once | ✔. Creating is explicit (a missing path is an error, not a new empty file); one path is one source | `SQLiteOpeningTests`, `IDESQLiteSourceTests` |
| Validate before opening | ✔. The 16-byte header is checked, so a text file named `.db` is reported as "not a SQLite database"; a damaged file gets a corruption hint | `aTextFileNamedDotDBIsReportedAsWhatItIs`, `aDamagedFileIsReportedWithAHint…` |
| In-memory identity | ✔. One connection is the database; the app's `connect` leaves an open in-memory source alone, so a "reconnect" cannot swap in an empty database | `aMemoryDatabaseLivesInExactlyOneConnection`, `testAnInMemoryDatabaseSurvivesAReconnect…` |
| Dynamic typing | ✔. A value is what its storage class says, not what the column declares; affinity is reported separately by SQLite's five rules | `valuesKeepTheirStorageClassWhateverTheColumnDeclares`, `affinityFollowsSQLitesFiveRules` |
| Introspection | ✔ tables, views, virtual and shadow tables, composite PK/FK (with the implicit parent key resolved), indexes (unique, partial, expression), triggers, STRICT, WITHOUT ROWID, generated columns (virtual vs stored), attached schemas | `introspectsEverythingSQLiteCanHold`, `attachedDatabasesAreListedAndBrowsable` |
| Read-only | ✔ **engine-enforced**: `SQLITE_OPEN_READONLY`; `PRAGMA query_only` plus an authorizer for a read-only call on a writable file (no writes, no schema change, no `ATTACH`, no assigning a pragma; read pragmas like `table_info(t)` still work) | `forceReadOnlyUsesTheEnginesOwnBlocks…`, `testAReadOnlySourceRefusesWrites…` |
| Read-only WAL databases | ✔ **real finding**: a WAL-mode file with no `-wal`/`-shm` cannot be opened `READONLY` (SQLite's own shell fails the same way), which is the normal state of a cleanly closed database. The session falls back to a `query_only` connection (every write refused by the engine, **but SQLite may create `-wal`/`-shm` next to the database**), then to `immutable` (reads the main file only, **can miss other programs' newer changes**). Both are visible in the app: a banner when the source connects and a tag on its row in the tree (`read-only (query only)`, `immutable, may be out of date`) for as long as it is connected. A normal open says nothing | `aWALDatabaseWithoutItsSideFilesStillOpensReadOnly`, `aWALDatabaseInAReadOnlyFolderOpensImmutableAndSaysSo`, `testTheQueryOnlyFallbackIsShownBecauseItCanCreateSideFiles`, `testAnImmutableOpenIsShownAsPossiblyOutOfDate`, `testAnOrdinaryReadOnlyOpenSaysNothing`. The banner and tag are asserted as state, **not looked at on screen** |
| Locks and `SQLITE_BUSY` | ✔ reported with the wait time and a hint instead of hanging | `aLockHeldByAnotherConnectionIsReportedNotHung` |
| External changes | ✔ `PRAGMA data_version` changes when another connection commits | `externalChangesAreNoticedThroughTheDataVersion` |
| Cancellation | ✔ `sqlite3_interrupt` from any thread; **found and fixed**: the actor-isolated cancel would have queued behind the statement it was meant to stop, so cancel is `nonisolated` and tested through the facade the UI calls | `interruptStopsALongStatement…` (about 0.05 ms from interrupt to the statement ending), `cancelReachesTheSQLiteConsole`, `closingWhileAnInterruptIsInFlight…` |
| Maintenance, never automatic | ✔ integrity/quick check, foreign-key check, analyze/optimize/vacuum (refused on read-only), WAL checkpoint, size, journal mode. **Opening changes nothing**: journal mode and `foreign_keys` stay as the file has them | `integrityForeignKeysSizeAndMaintenance…` |
| Consistent backup | ✔ SQLite's online backup API; refuses to overwrite; a failed or cancelled backup leaves no partial file. A plain copy of a WAL database's main file was **short**: 1,983 rows against the backup's 2,000 in the test | `aBackupOfAWALDatabaseIsConsistent…` (prints `SQLITEWAL`), `aFailedBackupLeavesNoPartialFile` |
| One statement at a time | ✔ a script is refused whole (including `CREATE TABLE a; DROP TABLE a`, whose second statement does not prepare yet); the console's splitter (Phase 4) will feed statements one by one | `oneStatementAtATimeAndCommentsAreHarmless` |
| App integration | ✔ connection sheet (file chooser, New…, in-memory, read-only; no network fields), Database ▸ Open SQLite File… / New SQLite Database…, drag a file onto the sidebar, File ▸ Open routes files by header | `IDESQLiteSourceTests` (the panels and the drop itself are **not** UI-tested) |

Not done for SQLite: security-scoped bookmarks (the app is not sandboxed, so paths work today), the maintenance sheet in the UI (the library calls exist), schema editing and table rebuilds, spatial extensions, `.recover`, and detecting a file changed from outside in the UI (the library exposes `dataVersion`).

Also fixed on the way: **identifier quoting rejected any table name with a space** (`Order Details`), because the guard accepted only ASCII letters, digits and `_`. Quoting with the quote character doubled is safe for any name without control characters, so `SELECT * FROM "Order Details"` now works for all engines, and a hostile name still comes out as one identifier (`quoteIdentifierNeverLetsANameEscapeItsQuotes`).

Driver limits found on the way (true of mysql-nio, not of the design):
- **An empty MySQL result has no column headers**: the driver reports column definitions only together with a row. A table browse can read headers from `information_schema`; an arbitrary empty `SELECT` cannot.
- **MySQL text protocol has no backpressure** (above).
- **DDL inside a transaction commits it.** The session reports `implicitlyCommitted` and sets the transaction to none instead of pretending it survived (`ddlInsideATransactionIsReportedAsAnImplicitCommit`).

Also changed on the way: affected-row counts are now reported for PostgreSQL (`INSERT 3` → `rowsAffected == 3`; it was always `nil`), and an empty result keeps its column headers.

**Behaviour changes to know about**
- The app-facing `SQLSession.query` returns at most 100,000 rows (`SQLSession.userRowLimit`) and tells the server to stop. The paged console never asks for more than one page, so it is unaffected.
- `pg_sleep` and `sleep` are no longer refused by the interim keyword check (they do not change state); the server enforces read-only.
- A connection with `tlsRequired = true` fails against a server without TLS instead of connecting in plain text. Nothing is made strict automatically: *Prefer* remains the default for existing and URL-imported PostgreSQL connections because a plain `postgresql://` URL means prefer (as in libpq), and strict by default would break local servers. **For a production server, choose Require and also enforce TLS on the server.**

---

## Critical

### F-01 Transactions are not bound to a session
- **Status:** Code-read.
- **Files:** `Packages/DatabaseKit/Sources/DatabaseKit/SQLSession.swift` (`mysqlPool`, `postgresClient`, `mysqlQuery`, `postgresQuery`).
- **Root cause:** Both engines run each statement on a connection leased from a pool. Nothing pins consecutive statements to one connection.
- **User impact:** `BEGIN; UPDATE …; COMMIT` typed in a console can run on different connections: the `UPDATE` auto-commits, or the `COMMIT` has nothing to commit. Session settings (`SET search_path`, `USE db`) are lost between statements. Staged editing with commit/rollback is impossible to build on this.
- **Correction:** One physical connection per session actor (console, metadata, and a side channel for cancel). See ARCHITECTURE.md.
- **Verification:** Live test: `BEGIN`, an insert, then `SELECT txid_current_if_assigned()` and `pg_backend_pid()` on every statement must report the same backend; a rollback must remove the row.

### F-02 PostgreSQL values are shown as raw binary
- **Status:** **Verified** (live PG 16, `LiveBaselineTests.postgresTypedValuesBaseline`).
- **Files:** `SQLSession.swift` `formatPostgresCell`.
- **Root cause:** `cell.decode(String.self)` is tried first. PostgresNIO's `String` decoder falls back to reading the raw bytes for any type it does not know, so binary-format results decode "successfully" into garbage.
- **Observed:** `int4`, `int8`, `float8`, `numeric(10,4)`, `bool`, `date`, `timestamptz`, `int4[]` and `bytea` all display as control characters or mojibake. Only text-like types (`text`, `jsonb`, `uuid`) read correctly. A `uuid` is upper-cased.
- **User impact:** Any PostgreSQL query that returns a number, date, boolean or array shows wrong text. Export, charts and editing would propagate it.
- **Correction:** Decode by `PostgresDataType` into a typed `DatabaseValue` (Phase 1), with exact `numeric`, ISO dates, arrays and a bounded `bytea` preview.
- **Verification:** A type-matrix test comparing every cell against `psql` output for the same query.

### F-03 "Read-only" is a first-word check
- **Status:** **Verified** (unit tests added with the interim fix).
- **Files:** `QueryResult.swift` `SQLShaping.isReadOnlyStatement`, called from `SQLSession.query` and `DatabaseQuery.run`.
- **Root cause:** A statement counted as read-only if its first keyword was `SELECT`, `WITH`, `SHOW`, `EXPLAIN`, `DESCRIBE`, `DESC` or `PRAGMA`. No server-side enforcement exists.
- **Observed before the interim fix:** `WITH gone AS (DELETE FROM users RETURNING *) SELECT * FROM gone`, `EXPLAIN ANALYZE DELETE …`, `SELECT … INTO`, `SELECT nextval(…)`, `SELECT pg_terminate_backend(…)`, and `SELECT 1; DROP TABLE x` all passed.
- **User impact:** A connection marked read-only can change or destroy data. This affects the shipped app.
- **Interim fix (done):** The check now scans every word outside strings, comments and quoted names, refuses write words, a list of side-effecting functions and a second statement, and no longer treats `PRAGMA` as read-only. This is a stopgap: a denylist cannot see what a function does.
- **Correction (Phase 1):** Enforce it in the database: `default_transaction_read_only` / `BEGIN READ ONLY` (PostgreSQL), `SET SESSION TRANSACTION READ ONLY` (MySQL), `SQLITE_OPEN_READONLY` + `query_only` (SQLite), an allow-list of read commands without `$out`/`$merge` (MongoDB). The keyword check stays as an early hint only.
- **Verification:** Live tests run every bypass above on a read-only session and expect a server error, with the row count unchanged afterwards.

### F-04 PostgreSQL "Use TLS" can silently connect without TLS
- **Status:** Code-read.
- **Files:** `SQLSession.swift` `postgresConfiguration` (`.prefer(...)`).
- **Root cause:** `prefer` negotiates TLS if offered and otherwise continues in plaintext.
- **User impact:** A user who ticked "Use TLS" can send a password and data in clear text when the server (or a man in the middle) declines TLS.
- **Correction:** Explicit modes: disable, require, verify-CA, verify-full, with an optional CA file. "Use TLS" maps to require-with-verification.
- **Verification:** Live test against a server with `ssl=off` must fail for require; against a self-signed server must fail verify-full and succeed with its CA.

### F-22 Empty strings and NULL are the same value
- **Status:** **Verified** (`postgresTypedValuesBaseline`: `''::text` arrives as `nil`).
- **Files:** `SQLSession.swift` `formatPostgresCell` (`bytes.readableBytes > 0`); `MongoSession` previews.
- **Root cause:** A zero-length cell is treated as NULL.
- **User impact:** Editing and export turn empty strings into NULL and back; a `NOT NULL` column looks nullable.
- **Correction:** `DatabaseValue` distinguishes null, missing and empty text.
- **Verification:** Type-matrix test.

## High

### F-05 Results are fully materialized
- **Status:** **Verified** for PostgreSQL: a 1,000,000-row, 3-text-column query returns in 8.5 s and grows resident memory from 45 MB to 238 MB (debug build; see PERFORMANCE_BASELINE.md).
- **Files:** `SQLSession.swift` `postgresQuery` (drains the sequence), `mysqlQuery` (`simpleQuery` returns `[MySQLRow]`); `QueryResult.rows: [[String?]]`.
- **User impact:** Memory grows with result size; there is no first-row latency win; ten million rows are not possible.
- **Correction:** Pull rows on demand (PostgreSQL), stream into a bounded, spillable `ResultStore` (MySQL), step a cursor (SQLite), `getMore` batches (MongoDB).

### F-06 Paging re-executes the query
- **Status:** Code-read.
- **Files:** `QueryResult.swift` `SQLShaping.composedQuery`, `DatabaseQuery.run`.
- **Root cause:** Each page runs `SELECT * FROM (<query>) LIMIT n OFFSET m`.
- **User impact:** Deep pages cost O(offset); a non-deterministic query returns inconsistent pages; a statement with side effects runs again per page. The wrapper also fails for statements that cannot be a subquery.
- **Correction:** One execution feeds a cursor/`ResultStore`; the grid reads from it. Server-side sort and filter are explicit, previewed re-queries.

### F-07 No query cancellation
- **Status:** Code-read.
- **Files:** `SQLSession.swift`; `IDEDatabaseSupport.execute`.
- **User impact:** A slow query cannot be stopped; the Run button stays busy; closing the tab does not free the server.
- **Correction:** Side-channel cancel: `pg_cancel_backend`, `KILL QUERY`, `sqlite3_interrupt`, `killCursors`; wire `Task` cancellation to it.

### F-08 Concurrent runs overwrite one shared result
- **Status:** Code-read.
- **Files:** `IDEDatabaseSupport.swift` (`result`, `isRunning`, `execute`).
- **User impact:** Two consoles, or a slow run followed by a fast one, can show the wrong result under the wrong statement; `isRunning` is cleared by whichever run ends first.
- **Correction:** Per-run result objects with a generation check; stale completions are dropped.

### F-09 `@unchecked Sendable` sessions with unsynchronized state
- **Status:** Code-read.
- **Files:** `SQLSession` (`mysqlPool`, `postgresClient`, `postgresRunTask`), `MongoSession`, `MongoDatabaseBox`.
- **Correction:** Actor-isolated sessions. Any remaining escape hatch carries a written justification and a test.

### F-10 Introspection is limited to `public` and `DATABASE()`
- **Status:** Code-read.
- **Files:** `SQLSession.swift` `tables`, `columns`, `allColumns`, `foreignKeys`, `indexes`.
- **User impact:** Tables in other PostgreSQL schemas never appear; other MySQL databases cannot be browsed; foreign keys are single-column only (composite keys become several unrelated one-column keys); no views/routines/triggers/types; identifiers with the same name in two schemas collide in `[String: [SQLColumn]]`.
- **Correction:** Schema-qualified `CatalogSnapshot` with composite keys and all object kinds.

### F-11 Statement splitting is naive
- **Status:** Fixed for SQL consoles. The dialect splitter drives the gutter, statement at caret, selection, Execute All and diagnostics.
- **Files:** `SQLCompletionProvider.swift` `SQLCompletion.statements`; `IDEWorkspace+Database.swift` `executeDatabaseConsole` (sends the whole buffer as one statement).
- **User impact:** PostgreSQL `$$` bodies, `CREATE TRIGGER … BEGIN … END`, and MySQL `DELIMITER` scripts split in the wrong places for the gutter buttons; "Execute" runs the whole buffer as one statement, which a driver typically rejects when it holds more than one.
- **Correction:** A dialect-aware `StatementSplitter` shared by the gutter, Execute and diagnostics.

### F-23 Schema completion is a keyword scan, not semantic
- **Status:** Semantic engine and editor bridge implemented. Catalog scope is PostgreSQL `public`, the configured MySQL database and SQLite `main`.
- **Files:** `SQLCompletionProvider.swift`.
- **Gaps:** No CTE or subquery columns, no schema qualification, a fixed six functions, no JOIN suggestions, no diagnostics, hover or navigation. `INSERT INTO t (` offers generated and identity columns.

## MongoDB

### F-12 Values are flattened to truncated strings
- **Status:** Code-read. `MongoURLs.resultTable` / `primitivePreview` cut strings at 120 characters and print `String(describing:)` for BSON types.
- **Impact:** Dates, Decimal128, Binary, Regex and Timestamp have no faithful form; documents cannot be edited without loss.

### F-13 Explicit `null` and a missing field look different from the data
- **Status:** Code-read. A missing field becomes the Swift `nil` (shown as `NULL`); an explicit `null` becomes the text `"null"`.

### F-14 `JSONSerialization` loses precision
- **Status:** Code-read. `MongoURLs.document(fromJSON:)` converts through `Double`/`Int`, so Int64 beyond 2^53 and Decimal128 change, and only `$oid` and `$date` are understood from Extended JSON.

### F-15 Edits replace the whole document
- **Status:** Code-read. `MongoSession.replace` uses `updateOne(where: _id, to: document)`.
- **Impact:** A concurrent change to another field is silently overwritten.

### F-16 Sorting is client-side on one page
- **Status:** Code-read. `IDEDatabaseSupport.sort` re-sorts the fifty loaded documents.

## Medium

### F-17 Export corrupts negative numbers
- **Status:** Code-read. `QueryExport.field` prefixes `'` when the first character is `-`, `+`, `=` or `@`, including for `-5`.
- **Correction:** Apply formula protection to text cells only, and make it a setting.

### F-18 Export errors are swallowed
- **Status:** Code-read. `IDEDatabaseResultView.export` uses `try?` on the write.

### F-19 Export covers the current page only, in memory
- **Status:** Code-read. The whole export string is built before writing.

### F-20 The last statement is stored in plain text in the connection file
- **Status:** New executions no longer update `database-connections.json`. Window restoration stores each console buffer and binding. Previously saved `lastStatement` values can still seed new consoles.
- **Correction:** Move console contents to per-console storage; redact history.

### F-21 No real-database tests
- **Status:** **Verified.** All 23 original `DatabaseKit` tests and the 14 `UmbraTests` database/diagram tests are pure or use a fake `SQLExecuting`. Live tests now exist (`LiveBaselineTests`).

### F-24 First query can race the PostgreSQL client's `run()`
- **Status:** **Verified** (log line `PostgresClient.run() hasn't been called yet` during the live test).
- **Files:** `SQLSession.connectPostgres` starts `run()` in a `Task` and queries immediately.
- **Correction:** Single `PostgresConnection` (no `run()` loop); connect completes before the session is returned.

---

## Not yet audited (work items, not findings)

- Keychain item attributes and access control (`IDEDatabaseKeychain` uses `kSecAttrAccessibleWhenUnlocked`, which is reasonable; sharing and export of connection files is untested).
- Main-thread cost of `IDEDatabaseResultGrid.updateNSView` (`reloadData` on every update) with wide results.
- Memory and task lifetime when a console tab closes with a query running.
- `IDEDatabaseTree` cost with 10,000 objects.

These are covered by Phase 10 stress runs and are recorded in PERFORMANCE_BASELINE.md as "not measured" until then.
