# Database architecture

Status: design for Phases 1-8. Nothing in this document is implemented until the matching row in FEATURE_MATRIX.md says so.

## Constraints

- `Packages/DatabaseKit` stays a leaf package (macOS 14, Swift 6 language mode). It must not import AppKit or Penumbra; Umbra imports only the `DatabaseKit` product.
- The libraries must not spawn processes (App Store rule in `CLAUDE.md`). Anything that runs `pg_dump` or similar lives in `Umbra/Sources/Umbra/Database`, through `SubprocessKit`, after user consent.
- Completion never queries the database on a keystroke (`docs/PERFORMANCE_RULES.md`). Metadata is pushed into snapshots.

## Targets

```
DatabaseCore        no dependencies
SQLIntelligence     -> DatabaseCore
DatabaseKit         -> DatabaseCore, SQLIntelligence, drivers (postgres-nio, mysql-nio, MongoKitten, libsqlite3)
```

`DatabaseKit` re-exports the two others with `@_exported import`, so `Umbra/Package.swift` and the Xcode project keep one dependency.

### DatabaseCore

| Type | Role |
|---|---|
| `DatabaseEngine` | `postgres`, `mysql`, `sqlite`, `mongo` |
| `DataSourceConfig` | Codable settings, **never a secret**. Engine-specific parts (SQLite file + bookmark; network + TLS mode + CA path; Mongo URI parts) |
| `DatabaseCapabilities` | Option set filled at connect from the server's answers: transactions, savepoints, isolation levels, cancel, explain (text/json/analyze), cursors, editable results, foreign keys, multiple result sets, PostGIS, Mongo transactions |
| `DatabaseValue` | Typed cell: `null`, `missing`, `bool`, `int`, `uint`, `double`, `decimal(String)`, `text`, `bytes(count, prefix)`, `temporal(raw, kind)`, `json`, `uuid`, `array`, `geometry`, `bson`, plus `truncated(preview, fullCount)` and `unloaded` |
| `ResultColumn` | Name, declared type, origin table/column when the driver reports it, nullability |
| `ResultStore` | Chunked row storage with a memory ceiling that spills to a 0600 temp file, deleted on close. The grid reads ranges; nothing else holds rows |
| `CatalogSnapshot` | Versioned, immutable: databases, schemas, relations, columns, keys (composite), indexes, triggers, routines, types, sequences. Marked complete or partial per schema |
| `DatabaseSession` | The protocol every session actor implements (below) |
| `TransactionState` | none / active(since, statements, readOnly, isolation) / aborted / lost |
| `PendingChangeSet`, `MutationPlanner` | Staged edits and their translation into parameterized statements or Mongo operations |
| `ExportWriter` | Streaming writers; each takes rows incrementally and an output sink |
| `SecretRedactor` | One redaction function used by logs, history, AI context and diagnostics |

### DatabaseSession

```swift
public protocol DatabaseSession: Actor {
    var engine: DatabaseEngine { get }
    var capabilities: DatabaseCapabilities { get }
    func execute(_ request: ExecuteRequest) async throws -> ResultCursor   // streams into a ResultStore
    func cancelRunning() async                                             // side channel, never queued behind the query
    func loadCatalog(_ scope: CatalogScope) async throws -> CatalogSnapshot
    func transaction() -> TransactionState
    func begin(_ options: TransactionOptions) async throws
    func commit() async throws
    func rollback() async throws
    func close() async
}
```

One session owns exactly one physical connection. A data source at runtime has:

- a **console session** (user statements; the only one that may hold a transaction),
- a **metadata session** (catalog reads, so a long query never blocks the explorer),
- a **cancel path** (a throwaway connection for `pg_cancel_backend` / `KILL QUERY`; `sqlite3_interrupt` and `killCursors` need none).

Why not a pool: transactions, `SET`, temporary tables, `USE` and cursors are properties of a connection. A pool makes them unpredictable (audit F-01).

### Engine notes

- **SQLite** (`libsqlite3`, system): its own serial executor; prepared statements stepped on demand; `sqlite3_interrupt`; backup API; `PRAGMA data_version` to notice external writes. In-memory databases have one connection for their life; the runtime never reopens them.
- **PostgreSQL**: a single `PostgresConnection`. Results are pulled from the row sequence as the grid scrolls, which gives real backpressure. Cells decode by `PostgresDataType`. Row descriptions carry table OIDs, which is how editable results find their source table.
- **MySQL**: a single `MySQLConnection`. NIO pauses socket reads at a high watermark and resumes at a low watermark as rows drain into `ResultStore`. Column definitions carry `orgTable`/`orgName` for editability.
- **MongoDB**: BSON stays BSON. Cursors use `batchSize`/`getMore` and are killed on close. Edits are `$set`/`$unset` with a filter on the original values.

## SQLIntelligence

Pure Swift, no I/O.

- `SQLDialect` (PostgreSQL, MySQL, SQLite): quoting, string and comment forms, keywords, types, functions with signatures, statements that implicitly commit.
- `SQLLexer`: tolerant; never fails on incomplete input.
- `StatementSplitter`: dollar quotes, `BEGIN … END`, `CREATE TRIGGER`, `DELIMITER`, nested comments.
- `ScopeAnalyzer`: builds, for a caret offset, the visible relations (tables, CTEs including recursive, derived tables, aliases, correlated outer scopes) and the clause (select list, from, join on, where, group, order, insert columns, update set).
- Completion, diagnostics, hover, signature help, formatting, code actions on top of the scopes and a `CatalogSnapshot`.

**Why not tree-sitter for this.** The bundled grammar (`TreeSitterSQL`, ABI 13, PostgreSQL-leaning) keeps doing highlighting. For completion we need dialect lexing, recovery from half-typed statements and the splitting rules above; the grammar gives a tree of `ERROR` nodes exactly when completion is wanted. It also lives in the root package, which `DatabaseKit` must not depend on. The Umbra integration owns the bridge.

### Diagnostics honesty rule

An unknown table or column is reported only when the schema's snapshot is **complete and fresh**. Otherwise nothing is reported (the object may simply not be indexed yet). The UI shows "schema loading" or "schema partial" instead.

## Umbra layer

```
IDEDatabaseSupport (per window, coordinator)
 └─ IDEDataSourceRuntime (per connected source)
     ├─ console session, metadata session
     ├─ CatalogCache  (per database/schema; bounded; invalidated by DDL; generation tokens)
     ├─ TransactionController
     └─ [IDEQueryRun]  per console; each owns its ResultStore and generation
```

- Consoles keep their text in Application Support, bound to a data source; the connection file no longer stores statements.
- The Query Results bottom tab shows one sub-tab per run of the active console. A superseded or closed run releases its `ResultStore`.
- SQL intelligence registers through the existing `BasicLanguageService(name: "umbra.sql")` in `Intelligence/IDEIntelligenceServices.swift`, reading snapshots pushed by the runtime (the pattern `SQLCompletionProvider` already uses).
- The grid uses `NSTableView` with a viewport-sized display window over typed result stores. The custom-drawn `NSView` decision awaits scroll measurements.
- AI tools are `AgentTool`s modelled on `Agent/IDEAgentGitTools.swift`, reached through a new `IDEAgentHost` method with a default implementation.

## Secrets

Passwords, SSH or TLS key passphrases and tokens live in the Keychain under the existing `com.umbra.editor.database` service, one item per source id. They are read when a session opens and never stored in `DataSourceConfig`, console files, history, logs, exported connection files or AI context. `SecretRedactor` is applied to every outbound string that can contain a connection string.

## What is deliberately not abstracted

- A single "query builder" or ORM layer: statements are generated by the mutation planner and the export writers per dialect, not by a general DSL.
- Mongo behind SQL-shaped protocols: Mongo has its own cursor, document and pipeline types; it shares `DatabaseCapabilities`, `ResultStore` and export, not the SQL surface.
