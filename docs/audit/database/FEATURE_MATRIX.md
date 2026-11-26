# Feature matrix

This table records what is **implemented and verified**, not what is intended. A cell changes only when a test or a measurement backs it, and the evidence is named in the last column.

Legend: **✔** implemented and verified · **◐** exists but incomplete or known wrong · **✘** not implemented · **n/a** does not apply to the engine · **blocked** see note.

Baseline = state at the start of this work. Updated after every phase.

| Capability | PostgreSQL | MySQL | SQLite | MongoDB | Evidence / note |
|---|---|---|---|---|---|
| Connect with saved settings, password in Keychain | ◐ (TLS Off/Prefer/Require in the sheet; no timeouts yet) | ◐ (checkbox only) | ✔ (file path; no security-scoped bookmark) | ◐ | `TLSModeTests`, `IDEDatabaseTLSChoiceTests` |
| Connection test with actionable diagnostics | ◐ | ◐ | ✔ | ◐ | The sheet shows the driver message with suggested next steps. Network error categories use driver text. SQLite exposes and applies a busy timeout. |
| Open / create / in-memory / read-only file | n/a | n/a | ✔ (header validated; WAL read-only fallbacks; drag-and-drop and the panels are not UI-tested) | n/a | `SQLiteOpeningTests`, `IDESQLiteSourceTests` |
| Session isolation (transaction pinned to a connection) | ✔ | ✔ | ✔ | n/a (transactions not implemented) | `LivePostgresSessionTests` (pinning, BEGIN/ROLLBACK/COMMIT, console-typed `BEGIN` tracked) |
| Capability discovery at runtime | ◐ (library: version, PostGIS, feature flags; UI does not read it yet) | ◐ (library: version, MariaDB, explain support) | ◐ (library: version, read-only/immutable) | ✘ | `serverFactsAndCapabilitiesAreDetectedNotAssumed` |
| Database-enforced read-only | ✔ | ✔ | ✔ | ✘ | `readOnlySessionsAreRefusedByTheServerNotByAKeywordScan`, `forceReadOnlyProtectsAWritableConnection` |
| Query execution, typed values | ✔ | ✔ (8.4 only; empty results have no headers) | ✔ (storage class per value) | ✔ in the library (exact BSON); ◐ in the console (flat string table) | `LivePostgresTypeTests` (82 expressions vs the server's text) |
| Streaming results with bounded memory | ✔ (pulled rows) | ✔ (socket read watermarks) | ✔ (stepped in batches) | ✔ (cursor batches) | Per-console result stores, viewport reads, byte-limited spill chunks and close cleanup. |
| Cancellation | ✔ 44 ms (toolbar, results bar, menu, ⌃⌘.) | ✔ 9 ms (same controls) | ✔ ≈0.05 ms (same controls) | ◐ (library ✔ 12 ms via killOp when the user may kill own operations; no UI control yet) | `cancellingARunningStatementReturnsPromptly` |
| Script results / notices | ◐ | ◐ | ◐ | n/a | One result per executed statement with duration and row counts. MySQL row results expose server messages. PostgreSQL notice delivery and multiple result sets from one statement remain open. |
| Execution errors mapped to source | ✔ | ◐ | ✔ | n/a | PostgreSQL and SQLite provide positions. MySQL errors appear in Query Results. |
| Explorer: schemas, tables, views | ◐ (`public` only) | ◐ (current db) | ◐ (tables and views of `main`; attached schemas are in the library, not the tree) | ◐ (db, collections) | F-10 |
| Explorer: routines, triggers, types, sequences, events | ✘ | ✘ | ✘ | n/a | |
| Explorer navigation and organization | ✔ | ✔ | ✔ | ✔ | Search and type filters over loaded metadata, favorites, groups, recents, branch refresh, and window restoration. |
| Schema change previews | ◐ | ◐ | ✔ | n/a | Create table, add column, create index, add unique and foreign-key constraints. SQLite previews supported table rebuilds and identifies dependencies that block a rebuild. |
| Production SQL confirmation | ◐ | ◐ | ✔ | n/a | Visible production marker and explicit confirmation for potentially mutating console batches. Read classification uses the existing SQL scanner. |
| Query console, persistent, bound to a source | ✔ | ✔ | ✔ | ✔ | Window restoration keeps editor buffers and source bindings. SQL files can bind from the console header. |
| Dialect-aware statement splitting | ✔ | ✔ | ✔ | n/a | Statement at caret, selection, Execute All, and gutter. `SQLLexerAndSplitterTests`. |
| Semantic SQL completion | ◐ (`public` catalog) | ◐ (configured database) | ◐ (`main` catalog) | out of scope | Scoped completion corpus, declared composite join keys, and generated/identity column filtering. |
| SQL diagnostics, hover, go to declaration, signature help | ◐ | ◐ | ◐ | n/a | Console language service with local navigation, object DDL, diagnostic fixes and star expansion. Name diagnostics depend on catalog coverage. |
| Result grid: virtualized, columns, selection, copy | ◐ | ◐ | ◐ | ◐ | Native table, viewport reads, row numbers, multiselect, column resize and reorder. Cell selection and grid copy remain open. |
| Presentation modes (table, transposed, record, tree, text) | ✘ | ✘ | ✘ | ✘ | |
| Value inspector | ◐ | ◐ | ◐ | ◐ | Stored text, JSON/BSON formatting and binary previews, with one cell loaded on demand. |
| Staged editing, preview, conflict detection | ✘ | ✘ | ✘ | ✘ | |
| Transactions (manual commit, savepoints, isolation) | ✘ | ✘ | ✘ | ✘ | |
| Foreign-key navigation | ✘ | ✘ | ✘ | n/a | Schema diagram only |
| Execution plans | ✘ | ✘ | ✘ | ✘ | |
| Charts | ✔ | ✔ | ✔ | ✔ | Ten local chart types, bounded sampling, series filter, grid navigation, PNG/PDF, saved settings. Eligible SQL can preview an explicit server aggregation. |
| Geographic visualization | ✔ | ✔ | ✔ | ✔ | Offline WGS84 coordinates and GeoJSON. WKT/WKB use an embedded or separate SRID. Apple Maps basemap is opt-in. |
| Export (CSV/TSV/JSON of first result batch) | ◐ | ◐ | ◐ | ◐ | Reads the stored result. Streaming scope and formats remain in Phase 7. |
| Streaming export, more formats | ✘ | ✘ | ✘ | ✘ | |
| Native backup | ✘ | ✘ | ◐ (library: online backup API, verified; no UI) | ✘ | |
| BSON fidelity, Extended JSON | n/a | n/a | n/a | ✔ (library; every type, 24 codec tests, server `$type` check) | F-12..14 |
| Aggregation pipeline editor | n/a | n/a | n/a | ✘ | |
| Database AI tools / context / actions | ✘ | ✘ | ✘ | ✘ | |
| Live integration tests | ✔ | ✔ | ✔ (no server needed) | ✔ | `LivePostgres*`, `LiveMySQL*`, `LiveSQLSessionFacadeTests` |

## Phase log

| Phase | State | Verified by |
|---|---|---|
| 0 Audit and baseline | In progress: audit, architecture, matrix, test env, first live baselines written | `DATABASE_AUDIT.md`, `LiveBaselineTests`, `Scripts/db-test-env.sh` |
| 1 Foundation | **In progress, PostgreSQL, MySQL and MongoDB done at library and facade level**: values, result store, capabilities, redaction, session actors, server read-only, cancel, TLS option and PostgreSQL picker, affected-row counts. Remaining: per-console results and cancel/transaction UI (Phase 4), console text storage (F-20), MySQL TLS picker | `DatabaseCoreTests` (43), `DatabaseKitTests` (136 incl. live), `UmbraTests` database (18) |
| 2 SQLite | **Library and app integration done; maintenance/backup UI, bookmarks and schema editing not done** | `SQLite*` tests (30 library, `IDESQLiteSourceTests` 14) |
| 3 PostgreSQL / MySQL / MongoDB | In progress. Native MongoDB BSON and Extended JSON, cursor-based filters, composite SQL foreign keys and generated/identity column metadata. Broader introspection, explain UI and Mongo editing/pipelines remain open. | `LiveMongoDocumentSessionTests`, `LiveSQLSessionFacadeTests` |
| 4 Consoles and SQL intelligence | In progress. Source-bound consoles, editor header, SQL execution modes, native parameters, per-console results, catalog refresh, semantic completion, formatting, editor actions and positioned execution errors. Redacted history, broader server notices and database/schema switching remain open. | `SQLIntelligenceTests`, `IDESQLiteSourceTests`, `IDEMenuShortcutsTests`, `LiveSQLSessionFacadeTests`, `LiveMySQLFacadeTests` |
| 5 Grid, editing, transactions, relations | In progress. Stored-result streaming, virtual row reads, explicit sorted reruns and initial inspector. | `IDEDatabaseTests`, `IDESQLiteSourceTests`, `ResultStoreTests`, live MySQL and MongoDB streaming tests |
| 6 Charts and geo | Implemented. Desktop interaction and basemap smoke checks remain open. | `IDEDatabaseVisualizationTests`, `IDESQLiteSourceTests`, Umbra Xcode build, PostGIS and MySQL spatial query checks |
| 7 Export and backup | Not started | |
| 8 AI | Not started | |
| 9 UX | Explorer organization, connection editor, previewed schema changes, and initial accessibility pass implemented. Catalog breadth follows the earlier engine work. | `IDEDatabaseUXTests`, `IDESQLiteSourceTests`, native macOS build |
| 10 Performance and final verification | Not started | |

## Interim changes already made

- `SQLShaping.isReadOnlyStatement` now rejects data-modifying CTEs, `EXPLAIN ANALYZE <write>`, `SELECT … INTO`, known side-effect functions, a second statement and `PRAGMA`. Tests: `SQLStatementTests.readOnlyRefusesWritesHiddenBehindAReadKeyword`, `readOnlyIgnoresWriteWordsInsideStringsCommentsAndQuotedNames`. This is a stopgap; Phase 1 adds server-side enforcement.
