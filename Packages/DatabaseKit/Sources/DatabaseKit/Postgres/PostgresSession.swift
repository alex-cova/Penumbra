import DatabaseCore
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOSSL
import PostgresNIO

/// One PostgreSQL connection, owned by one actor.
///
/// Why one connection and no pool: a transaction, `SET search_path`, a temporary table or a
/// cursor belongs to a *connection*. With a pool, `BEGIN` and `COMMIT` typed in a console could
/// run on different connections (audit F-01). Here every statement of the session runs on the
/// same connection, in order, and a second statement is refused while one is running.
///
/// Cancellation uses a separate, lazily created connection that calls `pg_cancel_backend(pid)`,
/// so it is never queued behind the statement it is trying to stop.
///
/// Read-only: when the session is read-only (or a call passes `forceReadOnly`), each statement
/// runs as `BEGIN READ ONLY; <statement>; ROLLBACK`. The server refuses writes inside it, including
/// writes hidden in a CTE or a function, so no scan of the SQL text is trusted for safety. The
/// extended query protocol also carries one statement per message, so a statement cannot smuggle
/// in a `COMMIT` to leave the read-only transaction and keep going.
public actor PostgresSession {
    public nonisolated let readOnly: Bool
    public nonisolated let login: SQLLogin
    public private(set) var serverInfo: ServerInfo
    public private(set) var capabilities: DatabaseCapabilities
    public private(set) var transaction: TransactionState = .none
    /// The backend process id, used to cancel from another connection.
    public nonisolated let backendPID: Int
    public let currentDatabase: String
    public let currentUser: String

    private let connection: PostgresConnection
    private let logger: Logger
    private var cancelConnection: PostgresConnection?
    private var isRunning = false
    private var cancelRequested = false
    private var isClosed = false

    private init(
        connection: PostgresConnection, login: SQLLogin, readOnly: Bool, logger: Logger,
        backendPID: Int, serverInfo: ServerInfo, capabilities: DatabaseCapabilities,
        currentDatabase: String, currentUser: String
    ) {
        self.connection = connection
        self.login = login
        self.readOnly = readOnly
        self.logger = logger
        self.backendPID = backendPID
        self.serverInfo = serverInfo
        self.capabilities = capabilities
        self.currentDatabase = currentDatabase
        self.currentUser = currentUser
    }

    // MARK: - Connecting

    public static func connect(login: SQLLogin, readOnly: Bool) async throws -> PostgresSession {
        var logger = Logger(label: "com.umbra.editor.database.postgres")
        logger.logLevel = .warning
        let connection = try await openConnection(login: login, logger: logger)
        do {
            // Server facts, read once. These are the only queries that run on connect.
            let rows = try await connection.query(
                """
                SELECT pg_backend_pid(), current_setting('server_version_num')::int,
                       current_setting('server_version'), current_database(), current_user,
                       EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'postgis')
                """,
                logger: logger
            )
            var facts: [DatabaseValue] = []
            for try await row in rows {
                facts = row.map { PostgresValueDecoder.decode(
                    oid: $0.dataType.rawValue, isBinary: $0.format == .binary,
                    bytes: $0.bytes.map { Array($0.readableBytesView) }
                ) }
            }
            guard facts.count == 6, case .int(let pid) = facts[0], case .int(let versionNumber) = facts[1] else {
                throw DatabaseError.executionFailed("The server did not describe itself.")
            }
            var features: Set<String> = []
            if case .bool(true) = facts[5] { features.insert("postgis") }
            let info = ServerInfo(
                engine: .postgres, version: facts[2].rawText ?? "",
                majorVersion: Int(versionNumber) / 10_000, features: features
            )
            var capabilities: DatabaseCapabilities = [
                .transactions, .savepoints, .isolationLevels, .readOnlyTransactions, .cancellation,
                .explainText, .explainStructured, .explainAnalyze, .streamingCursor, .foreignKeys,
                .storedRoutines, .schemas, .notices,
            ]
            if features.contains("postgis") { capabilities.insert(.spatial) }
            if readOnly { capabilities.insert(.serverEnforcedReadOnly) }
            if readOnly {
                // Belt and braces: the per-statement `BEGIN READ ONLY` below is the guarantee;
                // this also covers anything that reaches the connection another way.
                try await connection.query("SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY", logger: logger)
            }
            return PostgresSession(
                connection: connection, login: login, readOnly: readOnly, logger: logger,
                backendPID: Int(pid), serverInfo: info, capabilities: capabilities,
                currentDatabase: facts[3].rawText ?? login.handshakeDatabase,
                currentUser: facts[4].rawText ?? login.username
            )
        } catch {
            try? await connection.close()
            throw Self.map(error)
        }
    }

    public static func test(login: SQLLogin) async throws {
        let session = try await connect(login: login, readOnly: true)
        await session.close()
    }

    private static func openConnection(login: SQLLogin, logger: Logger) async throws -> PostgresConnection {
        let password = login.password.isEmpty ? nil : login.password
        let configuration: PostgresConnection.Configuration
        if let socket = login.unixSocketPath {
            configuration = PostgresConnection.Configuration(
                unixSocketPath: socket, username: login.username, password: password,
                database: login.handshakeDatabase
            )
        } else {
            // `requireTLS` is TLS or nothing, with full certificate and host verification: a
            // server (or a man in the middle) that declines TLS is an error. `useTLS` alone is the
            // historical "prefer": TLS when offered, plain text otherwise (audit F-04).
            let tls: PostgresConnection.Configuration.TLS
            if login.useTLS || login.requireTLS {
                do {
                    let context = try NIOSSLContext(configuration: .makeClientConfiguration())
                    tls = login.requireTLS ? .require(context) : .prefer(context)
                } catch {
                    throw DatabaseError.executionFailed("Could not prepare TLS: \(error)")
                }
            } else {
                tls = .disable
            }
            configuration = PostgresConnection.Configuration(
                host: login.host, port: login.port, username: login.username, password: password,
                database: login.handshakeDatabase, tls: tls
            )
        }
        do {
            return try await PostgresConnection.connect(configuration: configuration, id: Self.nextConnectionID(), logger: logger)
        } catch {
            throw map(error)
        }
    }

    private static let connectionCounter = ConnectionCounter()
    private static func nextConnectionID() -> Int { connectionCounter.next() }

    // MARK: - Running statements

    /// Runs one statement, delivering rows into `store`. Throws `DatabaseServerError` for a
    /// server-side error; the session stays usable (and `transaction` becomes `.aborted` if a
    /// transaction was open).
    public func execute(
        _ sql: String, parameters: [DatabaseValue] = [], into store: ResultStore, options: ExecuteOptions = ExecuteOptions()
    ) async throws -> ExecutionSummary {
        guard !isClosed else { throw DatabaseError.notConnected }
        guard !isRunning else {
            throw DatabaseError.executionFailed("A statement is already running on this connection.")
        }
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DatabaseError.executionFailed("Query is empty") }
        var bindings = PostgresBindings(capacity: parameters.count)
        for parameter in parameters {
            switch parameter {
            case .null: bindings.appendNull()
            case .text(let value): bindings.append(value)
            case .int(let value): bindings.append(value)
            case .double(let value): bindings.append(value)
            case .bool(let value): bindings.append(value)
            default: throw DatabaseError.executionFailed("Unsupported PostgreSQL parameter type.")
            }
        }
        let query = PostgresQuery(unsafeSQL: trimmed, binds: bindings)
        isRunning = true
        cancelRequested = false
        defer { isRunning = false }

        let start = ContinuousClock.now
        let wrapped = readOnly || options.forceReadOnly
        let statementWasInsideTransaction = transaction.isOpen

        return try await withTaskCancellationHandler {
            do {
                if wrapped, !statementWasInsideTransaction {
                    try await connection.query("BEGIN READ ONLY", logger: logger)
                }
                var summary = try await run(query, into: store)
                summary.duration = ContinuousClock.now - start
                summary.wasCancelled = cancelRequested
                if wrapped, !statementWasInsideTransaction { await rollbackQuietly() }
                else { updateTransactionState(afterSuccessful: trimmed) }
                return summary
            } catch {
                if wrapped, !statementWasInsideTransaction {
                    await rollbackQuietly()
                } else if transaction.isOpen {
                    transaction = .aborted
                }
                if cancelRequested || error is CancellationError {
                    // A cancelled statement is an outcome, not a failure.
                    var summary = ExecutionSummary()
                    summary.columns = await store.columns
                    summary.rowCount = await store.rowCount
                    summary.duration = ContinuousClock.now - start
                    summary.wasCancelled = true
                    return summary
                }
                throw Self.map(error)
            }
        } onCancel: {
            Task { await self.cancelRunning() }
        }
    }

    private func run(_ query: PostgresQuery, into store: ResultStore) async throws -> ExecutionSummary {
        let shape = Self.readShape(query.sql)
        if shape.readsRows {
            let mayWriteInCTE = SQLShaping.firstKeyword(in: query.sql) == "WITH"
                && !SQLShaping.isReadOnlyStatement(query.sql)
            if !mayWriteInCTE { return try await stream(query, into: store) }
            if await store.rowLimit == nil { return try await stream(query, into: store) }
        }
        if let command = shape.returningCommand, await store.rowLimit == nil {
            return try await stream(query, into: store, returningCommand: command)
        }
        // A statement that changes data returns no rows, and the async query API does not expose
        // the command tag that carries the affected-row count. The future-based API does, and
        // collecting "no rows" costs nothing. Row-limited callers of a mutation with RETURNING
        // also use the command tag, so reaching their display limit does not interrupt the write.
        let result = try await connection.query(query, logger: logger).get()
        var summary = ExecutionSummary(commandTag: result.metadata.command)
        summary.affectedRows = result.metadata.rows
        if let first = result.rows.first {
            let columns = first.map { ResultColumn(
                name: $0.columnName, typeName: PostgresValueDecoder.typeName(oid: $0.dataType.rawValue)
            ) }
            await store.setColumns(columns)
            summary.columns = columns
            var batch: [[DatabaseValue]] = []
            for row in result.rows {
                batch.append(row.map(Self.decode))
            }
            let accepted = try await store.append(batch)
            summary.limitReached = !accepted
            summary.rowCount = await store.rowCount
        }
        await store.finish()
        return summary
    }

    /// Rows arrive in a pulled sequence: the server is only read as fast as the store takes rows.
    private func stream(
        _ query: PostgresQuery, into store: ResultStore, returningCommand: String? = nil
    ) async throws -> ExecutionSummary {
        let sequence = try await connection.query(query, logger: logger)
        let columns = sequence.columns.map { column in
            ResultColumn(
                name: column.name,
                typeName: PostgresValueDecoder.typeName(oid: column.dataType.rawValue),
                origin: nil  // table OIDs are resolved to names when a result is made editable
            )
        }
        await store.setColumns(columns)
        var summary = ExecutionSummary(columns: columns)
        var batch: [[DatabaseValue]] = []
        batch.reserveCapacity(256)
        var stopped = false
        do {
            for try await row in sequence {
                if stopped { continue }  // draining after a stop request
                batch.append(row.map(Self.decode))
                if batch.count >= 256 {
                    let accepted = try await store.append(batch)
                    batch.removeAll(keepingCapacity: true)
                    if !accepted {
                        stopped = true
                        summary.limitReached = true
                        await cancelRunning(markRequested: false)
                    }
                }
            }
            if !batch.isEmpty, !stopped {
                if try await store.append(batch) == false { summary.limitReached = true }
            }
        } catch {
            // Telling the server to stop ends the statement with "canceling statement"; that is
            // the expected end of a stopped stream, not an error to show.
            if !stopped { throw error }
        }
        summary.rowCount = await store.rowCount
        if let returningCommand {
            summary.commandTag = returningCommand
            if !stopped, !cancelRequested { summary.affectedRows = summary.rowCount }
        } else {
            summary.commandTag = "SELECT \(summary.rowCount)"
        }
        await store.finish()
        return summary
    }

    /// Statements that produce a result set and can be read incrementally. Everything else (DML,
    /// DDL, session commands) goes through the path that returns the command tag.
    private static func readShape(_ sql: String) -> (readsRows: Bool, returningCommand: String?) {
        guard let first = SQLShaping.firstKeyword(in: sql) else { return (false, nil) }
        let reads: Set<String> = ["SELECT", "TABLE", "VALUES", "SHOW", "EXPLAIN", "FETCH"]
        let writes: Set<String> = ["INSERT", "UPDATE", "DELETE", "MERGE"]
        if reads.contains(first) { return (true, nil) }
        guard first == "WITH" || writes.contains(first) else { return (false, nil) }
        let source = sql as NSString
        var command = first == "WITH" ? nil : first
        var depth = 0
        for token in SQLLexer(sql, dialect: .postgres).tokenize() where token.kind == .word || token.kind == .symbol {
            let text = source.substring(with: token.range)
            if token.kind == .symbol {
                if text == "(" { depth += 1 }
                if text == ")" { depth -= 1 }
                continue
            }
            guard depth == 0 else { continue }
            let word = text.uppercased()
            if command == nil {
                if reads.contains(word) { return (true, nil) }
                if writes.contains(word) { command = word }
            } else if word == "RETURNING" {
                return (false, command)
            }
        }
        return (false, nil)
    }

    private static func decode(_ cell: PostgresCell) -> DatabaseValue {
        PostgresValueDecoder.decode(
            oid: cell.dataType.rawValue, isBinary: cell.format == .binary,
            bytes: cell.bytes.map { Array($0.readableBytesView) }
        )
    }

    // MARK: - Transactions

    public func begin(_ options: TransactionOptions = TransactionOptions()) async throws {
        guard !readOnly else {
            throw DatabaseError.executionFailed("This connection is read-only; it has no transactions to keep.")
        }
        guard !transaction.isOpen else {
            throw DatabaseError.executionFailed("A transaction is already open.")
        }
        var statement = "BEGIN"
        if let isolation = options.isolation { statement += " ISOLATION LEVEL \(isolation.rawValue)" }
        if options.readOnly { statement += " READ ONLY" }
        try await simple(statement)
        transaction = .active(readOnly: options.readOnly)
    }

    public func commit() async throws {
        try await simple("COMMIT")
        transaction = .none
    }

    public func rollback() async throws {
        try await simple("ROLLBACK")
        transaction = .none
    }

    private func simple(_ statement: String) async throws {
        guard !isClosed else { throw DatabaseError.notConnected }
        guard !isRunning else {
            throw DatabaseError.executionFailed("A statement is running; cancel it first.")
        }
        do {
            try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger)
        } catch {
            throw Self.map(error)
        }
    }

    private func rollbackQuietly() async {
        // Unstructured on purpose: if the caller was cancelled, this cleanup must still run.
        let connection = connection, logger = logger
        await Task {
            _ = try? await connection.query(PostgresQuery(unsafeSQL: "ROLLBACK"), logger: logger)
        }.value
    }

    private func updateTransactionState(afterSuccessful sql: String) {
        guard let keyword = SQLShaping.firstKeyword(in: sql) else { return }
        switch keyword {
        case "BEGIN", "START":
            transaction = .active(readOnly: SQLShaping.words(in: sql).words.contains("ONLY"))
        case "COMMIT", "END", "ABORT":
            transaction = .none
        case "ROLLBACK":
            // `ROLLBACK TO SAVEPOINT x` keeps the transaction open.
            let words = SQLShaping.words(in: sql).words
            if !words.contains("TO") { transaction = .none } else if case .aborted = transaction { transaction = .active(readOnly: false) }
        default:
            break
        }
    }

    // MARK: - Cancelling and closing

    /// Asks the server to stop the running statement. Returns once the request has been sent,
    /// not once the statement has ended. Safe to call at any time and from any task.
    public func cancelRunning() async {
        await cancelRunning(markRequested: true)
    }

    private func cancelRunning(markRequested: Bool) async {
        guard isRunning else { return }
        if markRequested { cancelRequested = true }
        do {
            let helper = try await cancelHelper()
            _ = try await helper.query(
                PostgresQuery(unsafeSQL: "SELECT pg_cancel_backend(\(backendPID))"), logger: logger
            )
            .get()
        } catch {
            // The helper may have gone stale; drop it so the next cancel reconnects.
            try? await cancelConnection?.close()
            cancelConnection = nil
        }
    }

    private func cancelHelper() async throws -> PostgresConnection {
        if let cancelConnection, !cancelConnection.isClosed { return cancelConnection }
        let helper = try await Self.openConnection(login: login, logger: logger)
        cancelConnection = helper
        return helper
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        if transaction.isOpen { transaction = .lost }
        try? await cancelConnection?.close()
        cancelConnection = nil
        try? await connection.close()
    }

    // MARK: - Errors

    static func map(_ error: any Error) -> any Error {
        if let error = error as? PSQLError {
            if let info = error.serverInfo {
                return DatabaseServerError(
                    message: info[.message] ?? "\(error.code)",
                    code: info[.sqlState],
                    position: info[.position].flatMap(Int.init),
                    detail: info[.detail],
                    hint: info[.hint]
                )
            }
            return DatabaseError.executionFailed(Self.describe(error))
        }
        return error
    }

    private static func describe(_ error: PSQLError) -> String {
        switch error.code {
        case .connectionError: "Could not connect to the database server."
        case .sslUnsupported: "The server does not support TLS, and TLS is required for this connection."
        case .server: "The server reported an error."
        case .serverClosedConnection: "The server closed the connection."
        case .clientClosedConnection: "The connection was closed."
        default: "\(error.code)"
        }
    }
}

/// A process-wide counter for connection ids, used only in log metadata.
private final class ConnectionCounter: Sendable {
    private let storage = NIOLockedValueBox(0)
    func next() -> Int { storage.withLockedValue { $0 += 1; return $0 } }
}
