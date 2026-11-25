import DatabaseCore
import Dispatch
import Foundation
import SQLite3

/// Where a SQLite database lives.
public enum SQLiteLocation: Equatable, Sendable {
    case file(String)
    /// A private in-memory database. It exists for exactly as long as the one connection that
    /// holds it, so the session must never be reopened behind the caller's back (a "reconnect"
    /// would silently be a new, empty database).
    case memory

    public var displayName: String {
        switch self {
        case .file(let path): URL(fileURLWithPath: path).lastPathComponent
        case .memory: ":memory:"
        }
    }
}

public struct SQLiteOpenOptions: Equatable, Sendable {
    public var location: SQLiteLocation
    public var readOnly: Bool
    /// Create the file when it does not exist. Off by default: opening a path that is not there
    /// is almost always a typo, and SQLite would otherwise make an empty database in its place.
    public var createIfMissing: Bool
    /// How long a statement waits for another connection's lock before reporting `SQLITE_BUSY`.
    public var busyTimeoutMilliseconds: Int

    public init(
        location: SQLiteLocation, readOnly: Bool = false, createIfMissing: Bool = false,
        busyTimeoutMilliseconds: Int = 5_000
    ) {
        self.location = location
        self.readOnly = readOnly
        self.createIfMissing = createIfMissing
        self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
    }
}

/// The raw connection, shared between the session's executor and `interrupt()`.
///
/// `@unchecked Sendable`, with this justification: SQLite is built in its serialized threading
/// mode on Apple platforms, `sqlite3_interrupt` is documented as safe to call from any thread
/// while a statement runs, and the only other uses (prepare, step, close) happen on the owning
/// session's serial executor. The lock makes "is it still open" and the call to `interrupt`
/// atomic, so an interrupt can never reach a closed handle. `SQLiteSessionTests` runs an interrupt
/// against a long query and a close racing an interrupt.
final class SQLiteHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var pointer: OpaquePointer?

    init(_ pointer: OpaquePointer) { self.pointer = pointer }

    /// The open handle. Only call on the owning session's executor.
    var raw: OpaquePointer? { lock.withLock { pointer } }

    func interrupt() {
        lock.withLock {
            if let pointer { sqlite3_interrupt(pointer) }
        }
    }

    func close() {
        lock.withLock {
            if let pointer {
                sqlite3_close_v2(pointer)
                self.pointer = nil
            }
        }
    }

    deinit { close() }
}

/// One SQLite connection, owned by one actor that runs on its own serial queue (so a blocking
/// `sqlite3_step` never occupies a cooperative-pool thread).
///
/// - Read-only is enforced by SQLite, not by looking at the SQL: the file is opened
///   `SQLITE_OPEN_READONLY` when the session is read-only, and any call with `forceReadOnly` runs
///   with `PRAGMA query_only` and an authorizer that refuses writes, `ATTACH`, and setting
///   pragmas. A statement that is not read-only is also refused up front (`sqlite3_stmt_readonly`).
/// - Cancel is `sqlite3_interrupt`, callable from any thread while a statement runs.
/// - Transaction state is `sqlite3_get_autocommit`, so a `BEGIN` typed in a console and one issued
///   by `begin()` are seen the same way.
/// - Nothing about the database is changed on open: no journal mode, no `foreign_keys`, no
///   pragma. Maintenance (`VACUUM`, `ANALYZE`, checkpoints) is a separate, explicit call.
public actor SQLiteSession {
    private let queue = DispatchSerialQueue(label: "com.umbra.editor.sqlite", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public nonisolated let options: SQLiteOpenOptions
    public nonisolated let readOnly: Bool
    public private(set) var serverInfo: ServerInfo
    public private(set) var capabilities: DatabaseCapabilities
    public private(set) var transaction: TransactionState = .none

    private let handle: SQLiteHandle
    /// The open connection, for the schema and maintenance extension. Executor-confined.
    var rawHandle: OpaquePointer? { handle.raw }
    private var isRunning = false
    private var isClosed = false
    private var lastDataVersion: Int64?

    private init(handle: SQLiteHandle, options: SQLiteOpenOptions, version: String, openMode: OpenMode = .normal) {
        self.handle = handle
        self.options = options
        self.readOnly = options.readOnly
        let major = Int(version.split(separator: ".").first.map(String.init) ?? "") ?? 3
        self.serverInfo = ServerInfo(
            engine: .sqlite, version: version, majorVersion: major, features: openMode.features
        )
        var capabilities: DatabaseCapabilities = [
            .transactions, .savepoints, .readOnlyTransactions, .cancellation, .explainText,
            .foreignKeys, .schemas, .streamingCursor, .backup,
        ]
        if options.readOnly { capabilities.insert(.serverEnforcedReadOnly) }
        self.capabilities = capabilities
    }

    // MARK: - Opening

    public static let fileMagic = Array("SQLite format 3\0".utf8)

    public enum OpenError: Error, Equatable, LocalizedError {
        case missing(String)
        case notADatabase(String)
        case notReadable(String)
        case alreadyExists(String)
        case sqlite(String, code: Int32)

        public var errorDescription: String? {
            switch self {
            case .missing(let path): "There is no file at \(path). Choose \"Create\" to make a new database there."
            case .notADatabase(let path): "\(URL(fileURLWithPath: path).lastPathComponent) is not a SQLite database (its header is not \"SQLite format 3\")."
            case .notReadable(let path): "Umbra cannot read \(path). Check the file's permissions, or that the folder was granted to Umbra."
            case .alreadyExists(let path): "\(path) already exists."
            case .sqlite(let message, _): message
            }
        }
    }

    /// Checks the file before SQLite is asked to open it, so a text file renamed `.db` is
    /// reported as what it is rather than as "file is not a database" from deep inside a query.
    public static func validate(path: String) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw OpenError.missing(path)
        }
        guard manager.isReadableFile(atPath: path), let handle = FileHandle(forReadingAtPath: path) else {
            throw OpenError.notReadable(path)
        }
        defer { try? handle.close() }
        let header = (try? handle.read(upToCount: 16)) ?? Data()
        // An empty file is a valid, empty database; anything else must carry the header.
        guard header.isEmpty || Array(header) == fileMagic else { throw OpenError.notADatabase(path) }
    }

    /// How the file was actually opened. The two fallbacks exist for a read-only request on a WAL
    /// database that has no `-wal`/`-shm` files, and each has a consequence the user should see.
    public enum OpenMode: Equatable, Sendable {
        case normal
        /// Opened read-write with `PRAGMA query_only`: no data can be written, but SQLite may have
        /// created `-wal` and `-shm` files next to the database.
        case queryOnlyFallback
        /// Opened `immutable=1`: the main file alone, no locking and no WAL, so changes made by
        /// another program are not seen and a write by one can show torn data.
        case immutable

        var features: Set<String> {
            switch self {
            case .normal: []
            case .queryOnlyFallback: ["queryOnlyFallback"]
            case .immutable: ["immutable"]
            }
        }
    }

    /// The mode the file was opened in (see `OpenMode`).
    public var openMode: OpenMode {
        if serverInfo.features.contains("immutable") { return .immutable }
        if serverInfo.features.contains("queryOnlyFallback") { return .queryOnlyFallback }
        return .normal
    }

    private struct Attempt {
        var target: String
        var flags: Int32
        /// Open read-write but let SQLite itself refuse every write (`PRAGMA query_only`).
        var queryOnly = false
        /// Open `immutable=1`: no locking and no WAL, so changes by other programs are not seen.
        var immutable = false
    }

    public static func open(_ options: SQLiteOpenOptions) async throws -> SQLiteSession {
        var flags = SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_URI
        let path: String
        switch options.location {
        case .memory:
            path = ":memory:"
            flags |= SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        case .file(let filePath):
            path = filePath
            let exists = FileManager.default.fileExists(atPath: filePath)
            if exists {
                try validate(path: filePath)
            } else if !options.createIfMissing || options.readOnly {
                throw OpenError.missing(filePath)
            }
            flags |= options.readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE
            if !exists { flags |= SQLITE_OPEN_CREATE }
        }
        var attempts = [Attempt(target: path, flags: flags)]
        if options.readOnly, case .file = options.location {
            // A WAL-mode database cannot be opened `READONLY` unless its -wal and -shm files
            // already exist, and a cleanly closed one has neither. SQLite's own shell fails the
            // same way. Fall back to a connection that is read-write only in name: every write
            // is refused by the engine. Last resort: `immutable`, which reads the main file
            // alone (and says so, because it cannot see another program's newer changes).
            attempts.append(Attempt(
                target: path, flags: (flags & ~SQLITE_OPEN_READONLY) | SQLITE_OPEN_READWRITE, queryOnly: true
            ))
            let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
            attempts.append(Attempt(target: "file:\(encoded)?immutable=1", flags: flags, immutable: true))
        }
        var firstError: OpenError?
        for attempt in attempts {
            do {
                return try openOnce(attempt, options: options)
            } catch let error as OpenError {
                firstError = firstError ?? error
                // "Cannot open" or "read-only" is what a WAL database says when its side files are
                // missing and cannot be made; anything else (not a database, corrupt) is final.
                guard case .sqlite(_, let code) = error, code == SQLITE_CANTOPEN || code == SQLITE_READONLY else { throw error }
            }
        }
        throw firstError ?? OpenError.sqlite("SQLite could not open the file.", code: SQLITE_CANTOPEN)
    }

    private static func openOnce(_ attempt: Attempt, options: SQLiteOpenOptions) throws -> SQLiteSession {
        var db: OpaquePointer?
        let result = sqlite3_open_v2(attempt.target, &db, attempt.flags, nil)
        guard result == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite could not open the file."
            if let db { sqlite3_close_v2(db) }
            throw OpenError.sqlite(message, code: result)
        }
        sqlite3_busy_timeout(db, Int32(max(0, options.busyTimeoutMilliseconds)))
        if attempt.queryOnly { sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil) }
        // A file that passed the header check can still be unreadable (corrupt pages, an
        // encrypted file, a WAL it cannot reach): reading the schema finds that now, with a clear
        // message, instead of at the first query.
        let probe = sqlite3_exec(db, "SELECT count(*) FROM sqlite_schema", nil, nil, nil)
        guard probe == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close_v2(db)
            let primary = probe & 0xFF
            switch primary {
            case SQLITE_NOTADB, SQLITE_CORRUPT:
                throw OpenError.sqlite(message + " The file may be corrupt, encrypted, or not a SQLite database.", code: primary)
            case SQLITE_CANTOPEN:
                throw OpenError.sqlite(
                    message + " If the database is in WAL mode, a read-only open needs its -wal and -shm files, or a folder Umbra can write to.",
                    code: primary
                )
            default:
                throw OpenError.sqlite(message, code: primary)
            }
        }
        return SQLiteSession(
            handle: SQLiteHandle(db), options: options, version: String(cString: sqlite3_libversion()),
            openMode: attempt.immutable ? .immutable : (attempt.queryOnly ? .queryOnlyFallback : .normal)
        )
    }

    // MARK: - Executing

    /// Interrupts the running statement. Safe from any thread, at any time.
    public nonisolated func interrupt() {
        handle.interrupt()
    }

    /// Stops the running statement. `nonisolated` on purpose: the statement holds this session's
    /// serial queue while it steps, so an actor-isolated cancel would wait for the very statement
    /// it is meant to stop. With nothing running, SQLite ignores the interrupt.
    public nonisolated func cancelRunning() {
        handle.interrupt()
    }

    public func execute(
        _ sql: String, parameters: [DatabaseValue] = [], into store: ResultStore,
        options executeOptions: ExecuteOptions = ExecuteOptions()
    ) async throws -> ExecutionSummary {
        guard !isClosed else { throw DatabaseError.notConnected }
        guard !isRunning else {
            throw DatabaseError.executionFailed("A statement is already running on this connection.")
        }
        guard !sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DatabaseError.executionFailed("Query is empty")
        }
        isRunning = true
        defer { isRunning = false }
        let wrapped = readOnly || executeOptions.forceReadOnly
        let start = ContinuousClock.now
        // On a writable connection, a read-only call turns on the engine's own write block for
        // its duration. (A read-only file already refuses writes.)
        if wrapped, !readOnly { try setQueryOnly(true) }
        defer { if wrapped, !readOnly { try? setQueryOnly(false) } }
        if wrapped { installReadOnlyAuthorizer() }
        defer { if wrapped { removeAuthorizer() } }

        do {
            var summary = try await step(sql, parameters: parameters, into: store, requireReadOnly: wrapped)
            summary.duration = ContinuousClock.now - start
            updateTransactionState()
            return summary
        } catch let error as DatabaseServerError where error.code == "SQLITE_INTERRUPT" {
            updateTransactionState()
            var summary = ExecutionSummary()
            summary.columns = await store.columns
            summary.rowCount = await store.rowCount
            summary.duration = ContinuousClock.now - start
            summary.wasCancelled = true
            return summary
        } catch {
            updateTransactionState()
            throw error
        }
    }

    /// Runs a statement for its rows and returns them, for small internal reads (schema,
    /// pragmas). Bounded by `limit`.
    func run(_ sql: String, parameters: [DatabaseValue], limit: Int = 100_000) async throws -> [[DatabaseValue]] {
        let store = ResultStore(columns: [], rowLimit: limit)
        defer { Task { await store.close() } }
        _ = try await stepInternal(sql, parameters: parameters, into: store, requireReadOnly: false)
        return try await store.rows(in: 0..<store.rowCount)
    }

    private func step(
        _ sql: String, parameters: [DatabaseValue], into store: ResultStore, requireReadOnly: Bool
    ) async throws -> ExecutionSummary {
        try await stepInternal(sql, parameters: parameters, into: store, requireReadOnly: requireReadOnly)
    }

    private func stepInternal(
        _ sql: String, parameters: [DatabaseValue], into store: ResultStore, requireReadOnly: Bool
    ) async throws -> ExecutionSummary {
        guard let db = handle.raw else { throw DatabaseError.notConnected }
        var statement: OpaquePointer?
        var tail: UnsafePointer<CChar>?
        let prepared = sql.withCString { text -> Int32 in
            let code = sqlite3_prepare_v3(db, text, -1, 0, &statement, &tail)
            if code == SQLITE_OK, let tail, Self.hasAnotherStatement(after: tail) {
                // More than one statement is a script, which the console splits first. The tail
                // is read as text, not prepared: a later statement may only be valid once the
                // earlier ones have run (`CREATE TABLE a …; DROP TABLE a`).
                sqlite3_finalize(statement)
                statement = nil
                return -1
            }
            return code
        }
        guard prepared != -1 else {
            throw DatabaseError.executionFailed("Run one statement at a time. Split a script into its statements first.")
        }
        guard prepared == SQLITE_OK, let statement else {
            // An empty statement (only a comment) prepares to nil with SQLITE_OK.
            if prepared == SQLITE_OK { return ExecutionSummary() }
            throw serverError(db, sql: sql)
        }
        defer { sqlite3_finalize(statement) }
        if requireReadOnly, sqlite3_stmt_readonly(statement) == 0 {
            throw DatabaseError.readOnlyViolation
        }
        try bind(parameters, to: statement, db: db)

        var summary = ExecutionSummary()
        let columnCount = sqlite3_column_count(statement)
        if columnCount > 0 {
            let columns = (0..<columnCount).map { column(statement, $0) }
            await store.setColumns(columns)
            summary.columns = columns
        }
        var batch: [[DatabaseValue]] = []
        batch.reserveCapacity(256)
        var stopped = false
        loop: while true {
            let code = sqlite3_step(statement)
            switch code {
            case SQLITE_ROW:
                batch.append((0..<columnCount).map { value(statement, $0) })
                if batch.count >= 256 {
                    if try await store.append(batch) == false { summary.limitReached = true; stopped = true }
                    batch.removeAll(keepingCapacity: true)
                    if stopped { break loop }
                }
            case SQLITE_DONE:
                break loop
            default:
                throw serverError(db, sql: sql)
            }
        }
        if !batch.isEmpty, !stopped {
            if try await store.append(batch) == false { summary.limitReached = true }
        }
        summary.rowCount = await store.rowCount
        if columnCount == 0 {
            summary.affectedRows = Int(sqlite3_changes64(db))
            summary.commandTag = SQLShaping.firstKeyword(in: sql)
        } else {
            summary.commandTag = "SELECT \(summary.rowCount)"
        }
        await store.finish()
        return summary
    }

    /// True when anything but whitespace, `;` and comments follows.
    static func hasAnotherStatement(after tail: UnsafePointer<CChar>) -> Bool {
        var index = 0
        while true {
            let byte = UInt8(bitPattern: tail[index])
            switch byte {
            case 0:
                return false
            case 32, 9, 10, 13, 12, 59:  // whitespace and ';'
                index += 1
            case 45 where UInt8(bitPattern: tail[index + 1]) == 45:  // -- comment
                while tail[index] != 0, tail[index] != 10 { index += 1 }
            case 47 where UInt8(bitPattern: tail[index + 1]) == 42:  // /* comment */
                index += 2
                while tail[index] != 0, !(UInt8(bitPattern: tail[index]) == 42 && UInt8(bitPattern: tail[index + 1]) == 47) { index += 1 }
                if tail[index] != 0 { index += 2 }
            default:
                return true
            }
        }
    }

    private func column(_ statement: OpaquePointer, _ index: Int32) -> ResultColumn {
        let name = String(cString: sqlite3_column_name(statement, index))
        let declared = sqlite3_column_decltype(statement, index).map { String(cString: $0) } ?? ""
        var origin: ResultColumn.Origin?
        if let table = sqlite3_column_table_name(statement, index), let original = sqlite3_column_origin_name(statement, index) {
            origin = ResultColumn.Origin(
                schema: sqlite3_column_database_name(statement, index).map { String(cString: $0) },
                table: String(cString: table), column: String(cString: original)
            )
        }
        return ResultColumn(name: name, typeName: declared, origin: origin)
    }

    /// SQLite is dynamically typed: the storage class of *this* value decides what it is, whatever
    /// the column declares. A column declared `INTEGER` can hold text; it is shown as the text.
    private func value(_ statement: OpaquePointer, _ index: Int32, limits: ValueLimits = .standard) -> DatabaseValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER:
            return .int(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT:
            return .double(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard let pointer = sqlite3_column_text(statement, index) else { return .text("") }
            if count > limits.maxTextBytes {
                // Cut on a character boundary: back up while the first dropped byte is a UTF-8
                // continuation byte.
                var end = limits.maxTextBytes
                while end > 0, (pointer[end] & 0xC0) == 0x80 { end -= 1 }
                return .truncated(
                    preview: String(decoding: UnsafeBufferPointer(start: pointer, count: end), as: UTF8.self),
                    fullCount: count
                )
            }
            return .text(String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let pointer = sqlite3_column_blob(statement, index) else { return .bytes(count: 0, prefix: []) }
            let prefix = Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: min(count, limits.binaryPrefix)))
            return .bytes(count: count, prefix: prefix)
        default:
            return .null
        }
    }

    private func bind(_ parameters: [DatabaseValue], to statement: OpaquePointer, db: OpaquePointer) throws {
        let expected = Int(sqlite3_bind_parameter_count(statement))
        guard parameters.count == expected else {
            throw DatabaseError.executionFailed("The statement has \(expected) parameter(s) but \(parameters.count) value(s) were given.")
        }
        for (offset, parameter) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch parameter {
            case .null, .missing, .unloaded: code = sqlite3_bind_null(statement, index)
            case .bool(let flag): code = sqlite3_bind_int64(statement, index, flag ? 1 : 0)
            case .int(let number): code = sqlite3_bind_int64(statement, index, number)
            case .uint(let number):
                // SQLite integers are signed 64-bit: a larger value is kept exact as text.
                code = number <= UInt64(Int64.max)
                    ? sqlite3_bind_int64(statement, index, Int64(number))
                    : sqlite3_bind_text(statement, index, String(number), -1, Self.transient)
            case .double(let number): code = sqlite3_bind_double(statement, index, number)
            case .bytes(let count, let prefix):
                guard prefix.count == count else {
                    throw DatabaseError.executionFailed("A binary parameter was only partly loaded.")
                }
                code = prefix.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(count), Self.transient) }
            case .truncated:
                throw DatabaseError.executionFailed("A truncated value cannot be used as a parameter.")
            default:
                guard let text = parameter.rawText else { throw DatabaseError.executionFailed("Unsupported parameter.") }
                let bytes = text.utf8CString
                guard let length = Int32(exactly: bytes.count - 1) else {
                    throw DatabaseError.executionFailed("A text parameter is too large for SQLite.")
                }
                code = bytes.withUnsafeBufferPointer {
                    sqlite3_bind_text(statement, index, $0.baseAddress, length, Self.transient)
                }
            }
            guard code == SQLITE_OK else { throw serverError(db, sql: "") }
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    // MARK: - Read-only enforcement

    private func setQueryOnly(_ on: Bool) throws {
        guard let db = handle.raw else { throw DatabaseError.notConnected }
        guard sqlite3_exec(db, "PRAGMA query_only = \(on ? "ON" : "OFF")", nil, nil, nil) == SQLITE_OK else {
            throw serverError(db, sql: "")
        }
    }

    /// Allows reading and nothing else: no writes, no schema changes, no `ATTACH`, and no
    /// assigning a pragma (which can change the file).
    private func installReadOnlyAuthorizer() {
        guard let db = handle.raw else { return }
        sqlite3_set_authorizer(db, sqliteReadOnlyAuthorizer, nil)
    }

    private func removeAuthorizer() {
        guard let db = handle.raw else { return }
        sqlite3_set_authorizer(db, nil, nil)
    }

    // MARK: - State

    private func updateTransactionState() {
        guard let db = handle.raw else { return }
        transaction = sqlite3_get_autocommit(db) == 0 ? .active(readOnly: false) : .none
    }

    public func begin(immediate: Bool = false) async throws {
        guard !readOnly else {
            throw DatabaseError.executionFailed("This database is open read-only; it has no transactions to keep.")
        }
        guard !transaction.isOpen else { throw DatabaseError.executionFailed("A transaction is already open.") }
        _ = try await run(immediate ? "BEGIN IMMEDIATE" : "BEGIN", parameters: [])
        updateTransactionState()
    }

    public func commit() async throws {
        _ = try await run("COMMIT", parameters: [])
        updateTransactionState()
    }

    public func rollback() async throws {
        _ = try await run("ROLLBACK", parameters: [])
        updateTransactionState()
    }

    /// Changes whenever another connection commits to the file. A caller compares it before a run
    /// to notice that the file was modified from outside (and to refresh the schema).
    public func dataVersion() async throws -> Int64 {
        let rows = try await run("PRAGMA data_version", parameters: [])
        if case .int(let version)? = rows.first?.first { return version }
        return 0
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        handle.interrupt()
        handle.close()
    }

    // MARK: - Errors

    private func serverError(_ db: OpaquePointer, sql: String) -> any Error {
        let primary = sqlite3_errcode(db)
        let extended = sqlite3_extended_errcode(db)
        let message = String(cString: sqlite3_errmsg(db))
        var position: Int?
        let offset = sqlite3_error_offset(db)
        if offset >= 0 {
            // The offset is in bytes of the UTF-8 text; report it in characters for the editor.
            let utf8 = Array(sql.utf8)
            if offset <= utf8.count {
                position = String(decoding: utf8[0..<Int(offset)], as: UTF8.self).unicodeScalars.count + 1
            }
        }
        switch primary {
        case SQLITE_BUSY, SQLITE_LOCKED:
            return DatabaseServerError(
                message: "The database is locked by another connection (waited \(options.busyTimeoutMilliseconds) ms).",
                code: "SQLITE_BUSY", hint: "Close the other program or wait for its transaction to finish, then run it again."
            )
        case SQLITE_INTERRUPT:
            return DatabaseServerError(message: message, code: "SQLITE_INTERRUPT")
        case SQLITE_READONLY:
            return DatabaseServerError(message: message, code: "SQLITE_READONLY", hint: "The database or its folder is read-only.")
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            return DatabaseServerError(
                message: message, code: "SQLITE_CORRUPT",
                hint: "The file is damaged. Restore it from a backup, or try `.recover` in the sqlite3 shell."
            )
        case SQLITE_AUTH:
            return DatabaseError.readOnlyViolation
        default:
            return DatabaseServerError(message: message, code: "SQLITE_\(extended)", position: position)
        }
    }
}

/// Pragmas that take an argument and only read: `PRAGMA table_info(t)`. SQLite passes the argument
/// in the same slot whether it is a lookup or an assignment (`PRAGMA user_version = 5`), so any
/// other pragma that has an argument is refused.
private let readOnlyPragmasWithArgument: Set<String> = [
    "table_info", "table_xinfo", "table_list", "index_list", "index_info", "index_xinfo",
    "foreign_key_list", "foreign_key_check", "integrity_check", "quick_check", "database_list",
    "collation_list", "function_list", "module_list", "pragma_list", "compile_options",
]

private func sqliteReadOnlyAuthorizer(
    _: UnsafeMutableRawPointer?, _ action: Int32, _ argument1: UnsafePointer<CChar>?,
    _ argument2: UnsafePointer<CChar>?, _: UnsafePointer<CChar>?, _: UnsafePointer<CChar>?
) -> Int32 {
    switch action {
    case SQLITE_SELECT, SQLITE_READ, SQLITE_FUNCTION, SQLITE_RECURSIVE, SQLITE_TRANSACTION, SQLITE_SAVEPOINT:
        return SQLITE_OK
    case SQLITE_PRAGMA:
        guard argument2 != nil else { return SQLITE_OK }  // a plain read, `PRAGMA page_size`
        let name = argument1.map { String(cString: $0).lowercased() } ?? ""
        return readOnlyPragmasWithArgument.contains(name) ? SQLITE_OK : SQLITE_DENY
    default:
        return SQLITE_DENY
    }
}
