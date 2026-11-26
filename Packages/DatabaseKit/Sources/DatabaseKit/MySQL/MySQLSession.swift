import DatabaseCore
import Foundation
import Logging
import MySQLNIO
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// One MySQL / MariaDB connection, owned by one actor.
///
/// The same rules as `PostgresSession`:
/// - one physical connection, so `START TRANSACTION … COMMIT`, `SET`, `USE` and temporary tables
///   behave (audit F-01); a second statement is refused while one runs;
/// - read-only is enforced by the server: each statement of a read-only session runs inside
///   `START TRANSACTION READ ONLY … ROLLBACK`, and the session default is read-only too;
/// - cancel runs `KILL QUERY <id>` on a second connection.
///
/// What differs, and is true of this driver rather than of the design:
/// - MySQL sends rows without cursor demand. The client pauses NIO socket reads at a high
///   watermark while the `ResultStore` consumes and spills them. A
///   row limit stops the server with `KILL QUERY`. It is not a lazily pulled cursor.
/// - Text responses supply column definitions even when empty. The driver's prepared
///   query callback supplies columns only when a row arrives.
/// - DDL and several other statements commit implicitly. The session says so in the summary
///   (`implicitlyCommitted`) instead of pretending a transaction survived.
public actor MySQLSession {
    public nonisolated let readOnly: Bool
    public nonisolated let login: SQLLogin
    public private(set) var serverInfo: ServerInfo
    public private(set) var capabilities: DatabaseCapabilities
    public private(set) var transaction: TransactionState = .none
    public nonisolated let connectionID: Int
    public let currentDatabase: String
    public let currentUser: String
    /// TLS is in use on this connection (the server reported a cipher).
    public let isEncrypted: Bool

    private let connection: MySQLConnection
    private let logger: Logger
    private var cancelConnection: MySQLConnection?
    private var isRunning = false
    private var cancelRequested = false
    private var isClosed = false

    private init(
        connection: MySQLConnection, login: SQLLogin, readOnly: Bool, logger: Logger,
        connectionID: Int, serverInfo: ServerInfo, capabilities: DatabaseCapabilities,
        currentDatabase: String, currentUser: String, isEncrypted: Bool
    ) {
        self.connection = connection
        self.login = login
        self.readOnly = readOnly
        self.logger = logger
        self.connectionID = connectionID
        self.serverInfo = serverInfo
        self.capabilities = capabilities
        self.currentDatabase = currentDatabase
        self.currentUser = currentUser
        self.isEncrypted = isEncrypted
    }

    // MARK: - Connecting

    public static func connect(login: SQLLogin, readOnly: Bool) async throws -> MySQLSession {
        var logger = Logger(label: "com.umbra.editor.database.mysql")
        logger.logLevel = .warning
        let connection = try await openConnection(login: login, logger: logger)
        do {
            let rows = try await collect(
                connection,
                """
                SELECT CONNECTION_ID(), VERSION(), @@version_comment, @@sql_mode, DATABASE(),
                       CURRENT_USER()
                """
            )
            guard let facts = rows.first, facts.count == 6, case .int(let id) = facts[0] else {
                throw DatabaseError.executionFailed("The server did not describe itself.")
            }
            let version = facts[1].rawText ?? ""
            let comment = facts[2].rawText ?? ""
            var features: Set<String> = []
            let isMaria = version.localizedCaseInsensitiveContains("mariadb") || comment.localizedCaseInsensitiveContains("mariadb")
            if isMaria { features.insert("mariadb") }
            let major = Int(version.split(separator: ".").first.map(String.init) ?? "") ?? 0
            let minor = Int(version.split(separator: ".").dropFirst().first.map(String.init) ?? "") ?? 0
            let info = ServerInfo(
                engine: .mysql, version: version, majorVersion: major, features: features,
                sqlMode: facts[3].rawText ?? ""
            )
            var capabilities: DatabaseCapabilities = [
                .transactions, .savepoints, .isolationLevels, .readOnlyTransactions, .cancellation,
                .explainText, .foreignKeys, .storedRoutines, .multipleDatabases, .ddlImplicitlyCommits,
                .spatial,
            ]
            // `EXPLAIN FORMAT=JSON`: MySQL 5.7+, MariaDB 10.1+. `EXPLAIN ANALYZE`: MySQL 8.0.18+.
            if (!isMaria && major >= 5) || (isMaria && major >= 10) { capabilities.insert(.explainStructured) }
            if !isMaria, major > 8 || (major == 8 && (minor > 0 || patchLevel(version) >= 18)) {
                capabilities.insert(.explainAnalyze)
            }
            if readOnly { capabilities.insert(.serverEnforcedReadOnly) }

            // Did TLS actually get negotiated? `requireTLS` is TLS or nothing.
            let cipher = try await collect(connection, "SHOW SESSION STATUS LIKE 'Ssl_cipher'")
            let encrypted = !(cipher.first?.dropFirst().first?.rawText ?? "").isEmpty
            if login.requireTLS, !encrypted {
                throw DatabaseError.executionFailed(
                    "The server did not negotiate TLS, and TLS is required for this connection."
                )
            }
            if readOnly {
                _ = try await collect(connection, "SET SESSION TRANSACTION READ ONLY")
            }
            return MySQLSession(
                connection: connection, login: login, readOnly: readOnly, logger: logger,
                connectionID: Int(id), serverInfo: info, capabilities: capabilities,
                currentDatabase: facts[4].rawText ?? "", currentUser: facts[5].rawText ?? login.username,
                isEncrypted: encrypted
            )
        } catch {
            try? await connection.close().get()
            throw map(error)
        }
    }

    public static func test(login: SQLLogin) async throws {
        let session = try await connect(login: login, readOnly: true)
        await session.close()
    }

    private static func patchLevel(_ version: String) -> Int {
        let parts = version.split(separator: ".")
        guard parts.count > 2 else { return 0 }
        return Int(parts[2].prefix { $0.isNumber }) ?? 0
    }

    private static func openConnection(login: SQLLogin, logger: Logger) async throws -> MySQLConnection {
        let address: SocketAddress
        do {
            if let socket = login.unixSocketPath {
                address = try SocketAddress(unixDomainSocketPath: socket)
            } else {
                address = try SocketAddress.makeAddressResolvingHost(login.host, port: login.port)
            }
        } catch {
            throw DatabaseError.executionFailed("Could not resolve \(login.host): \(error)")
        }
        let useTLS = login.useTLS || login.requireTLS
        do {
            return try await MySQLConnection.connect(
                to: address,
                username: login.username,
                database: login.handshakeDatabase,
                password: login.password.isEmpty ? nil : login.password,
                tlsConfiguration: useTLS ? .makeClientConfiguration() : nil,
                serverHostname: useTLS && login.unixSocketPath == nil && !Self.isIPAddress(login.host) ? login.host : nil,
                logger: logger,
                on: NIOSingletons.posixEventLoopGroup.next()
            ).get()
        } catch {
            throw map(error)
        }
    }

    /// SNI and certificate host-name checks need a DNS name; NIOSSL refuses an IP address.
    static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    // MARK: - Running statements

    public func execute(
        _ sql: String, parameters: [DatabaseValue] = [], into store: ResultStore, options: ExecuteOptions = ExecuteOptions()
    ) async throws -> ExecutionSummary {
        guard !isClosed else { throw DatabaseError.notConnected }
        guard !isRunning else {
            throw DatabaseError.executionFailed("A statement is already running on this connection.")
        }
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DatabaseError.executionFailed("Query is empty") }
        let bindings = try parameters.map { parameter -> MySQLData in
            switch parameter {
            case .null: .null
            case .text(let value): MySQLData(string: value)
            case .int(let value): MySQLData(int: Int(value))
            case .double(let value): MySQLData(double: value)
            case .bool(let value): MySQLData(bool: value)
            default: throw DatabaseError.executionFailed("Unsupported MySQL parameter type.")
            }
        }
        isRunning = true
        cancelRequested = false
        defer { isRunning = false }

        let start = ContinuousClock.now
        let wrapped = readOnly || options.forceReadOnly
        let wasInsideTransaction = transaction.isOpen

        return try await withTaskCancellationHandler {
            do {
                if wrapped, !wasInsideTransaction {
                    _ = try await Self.collect(connection, "START TRANSACTION READ ONLY")
                }
                let result = try await run(trimmed, bindings: bindings, into: store)
                var summary = result.summary
                if options.collectNotices, result.warningCount != 0, !cancelRequested, !summary.limitReached,
                   Self.canCollectNotices(after: trimmed) {
                    // SHOW WARNINGS must run on this connection before the read-only rollback.
                    if let warnings = try? await Self.collect(connection, "SHOW WARNINGS LIMIT 100") {
                        summary.notices = warnings.compactMap { row in
                            guard row.count == 3, let level = row[0].rawText, let code = row[1].rawText,
                                  let message = row[2].rawText else { return nil }
                            return DatabaseNotice(level: level, code: code, message: message)
                        }
                    }
                }
                summary.duration = ContinuousClock.now - start
                summary.wasCancelled = cancelRequested
                if wrapped, !wasInsideTransaction {
                    await rollbackQuietly()
                } else {
                    updateTransactionState(afterSuccessful: trimmed, summary: &summary)
                }
                return summary
            } catch {
                if wrapped, !wasInsideTransaction {
                    await rollbackQuietly()
                } else if transaction.isOpen {
                    transaction = .aborted
                }
                if cancelRequested || error is CancellationError {
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

    private static func canCollectNotices(after sql: String) -> Bool {
        guard SQLShaping.firstKeyword(in: sql) == "SHOW" else { return true }
        return !SQLShaping.words(in: sql).words.prefix(4).contains { $0 == "WARNINGS" || $0 == "ERRORS" }
    }

    private func run(
        _ sql: String, bindings: [MySQLData], into store: ResultStore
    ) async throws -> (summary: ExecutionSummary, warningCount: UInt16?) {
        let producesRows = Self.returnsRows(sql)
        let channel = connection.channel
        let producer = NIOAsyncSequenceProducer.makeSequence(
            elementType: [DatabaseValue].self,
            backPressureStrategy: NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark(
                lowWatermark: 64, highWatermark: 256
            ),
            finishOnDeinit: false,
            delegate: MySQLResultDemand(channel: channel)
        )
        let source = producer.source
        let columnsBox = NIOLockedValueBox<[ResultColumn]?>(nil)
        let affectedRows = NIOLockedValueBox<Int?>(nil)
        let warningCount = NIOLockedValueBox<UInt16?>(nil)
        let onRow: @Sendable (MySQLRow) -> Void = { row in
            columnsBox.withLockedValue { columns in
                if columns == nil { columns = row.columnDefinitions.map(Self.column) }
            }
            if source.yield(Self.decode(row)) == .stopProducing {
                // The callback is already on the connection's event loop. Pause subsequent
                // socket reads while allowing the current inbound buffer to finish decoding.
                channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in
                    channel.close(promise: nil)
                }
            }
        }
        let future: EventLoopFuture<Void>
        if bindings.isEmpty {
            let command = MySQLTextResultCommand(sql: sql, onColumns: { definitions in
                columnsBox.withLockedValue { $0 = definitions.map(Self.column) }
            }, onRow: onRow, onCompletion: { rows, warnings in
                affectedRows.withLockedValue { $0 = rows.flatMap { Int(exactly: $0) } }
                warningCount.withLockedValue { $0 = warnings }
            })
            future = connection.send(command, logger: connection.logger)
        } else {
            future = connection.query(sql, bindings, onRow: onRow) { metadata in
                affectedRows.withLockedValue { $0 = Int(exactly: metadata.affectedRows) }
            }
        }
        future.whenComplete { _ in source.finish() }

        var summary = ExecutionSummary()
        var batch: [[DatabaseValue]] = []
        batch.reserveCapacity(256)
        var stopped = false
        var announcedColumns = false
        var needsDrain = true

        do {
            for await values in producer.sequence {
                if stopped { continue }  // draining after the store asked us to stop
                if !announcedColumns, let columns = columnsBox.withLockedValue({ $0 }) {
                    announcedColumns = true
                    await store.setColumns(columns)
                    summary.columns = columns
                }
                batch.append(values)
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
            if !announcedColumns, let columns = columnsBox.withLockedValue({ $0 }) {
                announcedColumns = true
                await store.setColumns(columns)
                summary.columns = columns
            }
            needsDrain = false
            try await future.get()
        } catch {
            if !stopped {
                // If storage failed while the socket was paused, allow the response to drain
                // and cancel the server before releasing this session for another statement.
                if needsDrain {
                    await cancelRunning(markRequested: false)
                    try? await channel.setOption(ChannelOptions.autoRead, value: true).get()
                    try? await future.get()
                }
                throw error
            }
        }
        summary.rowCount = await store.rowCount
        if !producesRows {
            summary.affectedRows = affectedRows.withLockedValue { $0 }
        }
        summary.commandTag = producesRows ? "SELECT \(summary.rowCount)" : SQLShaping.firstKeyword(in: sql)
        await store.finish()
        return (summary, warningCount.withLockedValue { $0 })
    }

    /// Statements whose result is a set of rows. MySQL has no data-modifying CTE in `SELECT`
    /// position, but `WITH … UPDATE/DELETE` exists (8.0), so `WITH` is checked like PostgreSQL.
    static func returnsRows(_ sql: String) -> Bool {
        guard let keyword = SQLShaping.firstKeyword(in: sql) else { return false }
        switch keyword {
        case "SELECT", "SHOW", "DESCRIBE", "DESC", "EXPLAIN", "TABLE", "VALUES", "ANALYZE", "CHECK", "CHECKSUM", "OPTIMIZE", "REPAIR":
            return true
        case "WITH":
            return !SQLShaping.words(in: sql).words.contains { ["INSERT", "UPDATE", "DELETE"].contains($0) }
        case "CALL":
            return true  // a procedure may return a result set; ROW_COUNT would be misleading
        default:
            return false
        }
    }

    private static func decode(_ row: MySQLRow) -> [DatabaseValue] {
        row.columnDefinitions.indices.map { index in
            let definition = row.columnDefinitions[index]
            return MySQLValueDecoder.decode(
                typeCode: definition.columnType.rawValue,
                isUnsigned: definition.flags.contains(.COLUMN_UNSIGNED),
                charset: UInt16(truncatingIfNeeded: definition.characterSet.rawValue),
                bytes: row.values[index].map { Array($0.readableBytesView) },
                binaryProtocol: row.format == .binary
            )
        }
    }

    private static func column(_ definition: MySQLProtocol.ColumnDefinition41) -> ResultColumn {
        ResultColumn(
            name: definition.name,
            typeName: MySQLValueDecoder.typeName(
                typeCode: definition.columnType.rawValue,
                isUnsigned: definition.flags.contains(.COLUMN_UNSIGNED),
                charset: UInt16(truncatingIfNeeded: definition.characterSet.rawValue)
            ),
            origin: definition.orgTable.isEmpty
                ? nil
                : ResultColumn.Origin(
                    schema: definition.schema.isEmpty ? nil : definition.schema,
                    table: definition.orgTable, column: definition.orgName
                )
        )
    }

    /// Runs a small statement and returns its rows, for facts and housekeeping.
    private static func collect(_ connection: MySQLConnection, _ sql: String) async throws -> [[DatabaseValue]] {
        let rows = NIOLockedValueBox<[[DatabaseValue]]>([])
        try await connection.simpleQuery(sql) { row in
            let decoded = decode(row)
            rows.withLockedValue { $0.append(decoded) }
        }.get()
        return rows.withLockedValue { $0 }
    }

    // MARK: - Transactions

    public func begin(_ options: TransactionOptions = TransactionOptions()) async throws {
        guard !readOnly else {
            throw DatabaseError.executionFailed("This connection is read-only; it has no transactions to keep.")
        }
        guard !transaction.isOpen else {
            throw DatabaseError.executionFailed("A transaction is already open.")
        }
        // The level applies to the next transaction only, which is the one started below.
        if let isolation = options.isolation {
            try await simple("SET TRANSACTION ISOLATION LEVEL \(isolation.rawValue)")
        }
        try await simple(options.readOnly ? "START TRANSACTION READ ONLY" : "START TRANSACTION")
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
        guard !isRunning else { throw DatabaseError.executionFailed("A statement is running; cancel it first.") }
        do {
            _ = try await Self.collect(connection, statement)
        } catch {
            throw Self.map(error)
        }
    }

    private func rollbackQuietly() async {
        let connection = connection
        await Task { _ = try? await Self.collect(connection, "ROLLBACK") }.value
    }

    /// Statements that end the open transaction by themselves (DDL, `LOCK TABLES`, `SET
    /// autocommit = 1`, …). MySQL commits first, so the work done so far is permanent.
    static func commitsImplicitly(_ sql: String) -> Bool {
        guard let keyword = SQLShaping.firstKeyword(in: sql) else { return false }
        switch keyword {
        case "CREATE", "ALTER", "DROP", "TRUNCATE", "RENAME", "GRANT", "REVOKE", "LOCK", "UNLOCK", "ANALYZE", "OPTIMIZE", "REPAIR":
            return true
        case "SET":
            let words = SQLShaping.words(in: sql).words
            return words.contains("AUTOCOMMIT")
        default:
            return false
        }
    }

    private func updateTransactionState(afterSuccessful sql: String, summary: inout ExecutionSummary) {
        guard let keyword = SQLShaping.firstKeyword(in: sql) else { return }
        switch keyword {
        case "BEGIN", "START":
            transaction = .active(readOnly: SQLShaping.words(in: sql).words.contains("ONLY"))
        case "COMMIT":
            transaction = .none
        case "ROLLBACK":
            if !SQLShaping.words(in: sql).words.contains("TO") { transaction = .none }
        default:
            if transaction.isOpen, Self.commitsImplicitly(sql) {
                transaction = .none
                summary.implicitlyCommitted = true
            }
        }
    }

    // MARK: - Cancelling and closing

    public func cancelRunning() async {
        await cancelRunning(markRequested: true)
    }

    private func cancelRunning(markRequested: Bool) async {
        guard isRunning else { return }
        if markRequested { cancelRequested = true }
        do {
            let helper = try await cancelHelper()
            _ = try await Self.collect(helper, "KILL QUERY \(connectionID)")
        } catch {
            try? await cancelConnection?.close().get()
            cancelConnection = nil
        }
    }

    private func cancelHelper() async throws -> MySQLConnection {
        if let cancelConnection, !cancelConnection.isClosed { return cancelConnection }
        let helper = try await Self.openConnection(login: login, logger: logger)
        cancelConnection = helper
        return helper
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        if transaction.isOpen { transaction = .lost }
        try? await cancelConnection?.close().get()
        cancelConnection = nil
        try? await connection.close().get()
    }

    // MARK: - Errors

    static func map(_ error: any Error) -> any Error {
        guard let error = error as? MySQLError else { return error }
        switch error {
        case .server(let packet):
            return DatabaseServerError(
                message: packet.errorMessage,
                code: packet.sqlState ?? String(packet.errorCode.rawValue)
            )
        case .duplicateEntry(let message):
            return DatabaseServerError(message: message, code: "23000")
        case .invalidSyntax(let message):
            return DatabaseServerError(message: message, code: "42000")
        case .closed:
            return DatabaseError.executionFailed("The connection is closed.")
        default:
            return DatabaseError.executionFailed(error.message)
        }
    }
}

private struct MySQLResultDemand: NIOAsyncSequenceProducerDelegate {
    let channel: any Channel

    func produceMore() { resumeReads() }
    func didTerminate() { resumeReads() }

    private func resumeReads() {
        channel.eventLoop.execute {
            channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in
                channel.close(promise: nil)
            }
        }
    }
}
