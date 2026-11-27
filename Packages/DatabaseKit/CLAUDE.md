# DatabaseKit (`Packages/DatabaseKit`)

Loaded when working under `Packages/DatabaseKit`. The database drivers and the model above them. Audit, architecture and the feature matrix with evidence: `docs/audit/database/`.

Three targets, one product (`DatabaseKit` re-exports `DatabaseCore`):

- **`DatabaseCore`** (no dependencies): `DatabaseValue` (null, *missing*, empty, binary and truncated are different values), `ResultStore` (bounded, spills to a 0600 temp file, deleted on close), `DatabaseCapabilities`/`ServerInfo`, `TransactionState`, `DatabaseServerError` (message, SQLSTATE, 1-based position), `SecretRedactor`, `AsyncMutex`, and `BSON/` (`BSONValue`, `BSONCodec`, `Decimal128Value`, `ExtendedJSON`).
- **`DatabaseKit`**: one session actor per engine, each owning **one physical connection**: `PostgresSession`, `MySQLSession`, `SQLiteSession`, `MongoDocumentSession`. `SQLSession` and `MongoSession` are the string-based facades the app still calls; each gives statements and catalog reads separate connections.
- Value decoders are pure and tested without a server: `PostgresValueDecoder`, `MySQLValueDecoder`.

## Rules that every change here keeps

- **One connection per session, never a pool.** Transactions, `SET`, temp tables, cursors and `USE` belong to a connection. A second statement while one runs is refused, not queued or interleaved. Catalog reads use their own session.
- **Read-only is the database's job.** PostgreSQL runs each statement in `BEGIN READ ONLY … ROLLBACK`; MySQL in `START TRANSACTION READ ONLY`; SQLite opens `READONLY` (or `query_only` + an authorizer for `forceReadOnly`, and for a WAL file that cannot open read-only); MongoDB has no such mode, so its session only offers operations it defines and never claims `.serverEnforcedReadOnly`. `SQLShaping.isReadOnlyStatement` is a hint for an early message, never the guarantee.
- **Rows go into a `ResultStore`, never into an array the caller owns.** A store that refuses more rows (`append` returns false) is the producer's signal to stop the server (`pg_cancel_backend`, `KILL QUERY`, `killCursors`, `sqlite3_step` simply stops).
- **Cancel is a separate path.** Postgres/MySQL/Mongo use a second connection; SQLite uses `sqlite3_interrupt`, callable from any thread (it is `nonisolated`, because the statement holds the session's queue).
- **No `Double`, `Date`, `Decimal` or `JSONSerialization` on a value's way through.** Int64, numeric/Decimal128, timestamps and ObjectIds are exact.
- **Never guess a type.** An unknown PostgreSQL OID falls back to text only if the bytes are printable UTF-8, otherwise to bounded binary. MySQL decides text-versus-binary from the column's character set.
- **Writes need a verified target.** `SQLSession.resolveRowSource` / `resolveEditTarget` return a `SQLEditTarget` only for one base table whose full primary or NOT NULL unique key is in the result, with each column's lock reason; `applyUpdates` (PostgreSQL, MySQL), `applyMutations` (SQLite) and `MongoSession.applyFieldUpdates` run a guarded batch (every key and original matched null-safely, expected count 1). Values are always bound; statements are built only from resolved column names. A batch runs in its own transaction, or under a savepoint inside the caller's; MongoDB cannot roll back across documents.
- **Value size is bounded by `ValueLimits.current`**, a task-local that defaults to 64 KB text / 64 binary bytes. Only the fetch-one-value calls raise it, for the one statement; MySQL rows are decoded on the event loop, so `run` captures the limits before it starts.
- **Escape hatches are justified.** The only `@unchecked Sendable` types are `SQLiteHandle` (a lock-protected raw handle), `DatabaseBox` (carries a driver object across one task-group boundary) and `SQLSession`/test helpers, each with a comment saying why.
- **TLS has three honest states.** `useTLS` is "prefer" (TLS if offered, plain text otherwise, the historical meaning); `requireTLS` is TLS or an error with full verification. Never turn `prefer` into `require` silently: a plain `postgresql://` URL means prefer.

## Tests

`swift test --package-path Packages/DatabaseKit` runs everything that needs no server (SQLite uses real temp files and `:memory:`). Live suites run only with `UMBRA_DB_INTEGRATION=1` against the disposable servers from `Scripts/db-test-env.sh up` (PostgreSQL+PostGIS, MySQL 8.4, MongoDB replica set on non-default ports; `eval "$(Scripts/db-test-env.sh env)"` sets the URLs). Never point a test at a database you did not just start.

MySQL sends rows without cursor demand. The session pauses socket reads as its consumer queue fills. mysql-nio returns column definitions only with a row, so an empty MySQL result has no headers. The BSON library's `Decimal128` is a stub, which is why `BSON/` exists.
