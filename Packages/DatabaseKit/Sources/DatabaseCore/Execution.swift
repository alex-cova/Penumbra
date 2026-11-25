import Foundation

/// Where a session stands with respect to a transaction. "Local pending edits" in the UI are a
/// different thing and never appear here: this is what the server knows.
public enum TransactionState: Equatable, Sendable {
    /// Autocommit: each statement commits on its own.
    case none
    /// `BEGIN` ran and nothing has committed or rolled back since.
    case active(readOnly: Bool)
    /// A statement failed inside the transaction; only `ROLLBACK` is accepted now.
    case aborted
    /// The connection dropped while a transaction was open. Its work is gone.
    case lost

    public var isOpen: Bool {
        switch self {
        case .active, .aborted: true
        case .none, .lost: false
        }
    }
}

public enum IsolationLevel: String, Sendable, Codable, CaseIterable {
    case readUncommitted = "READ UNCOMMITTED"
    case readCommitted = "READ COMMITTED"
    case repeatableRead = "REPEATABLE READ"
    case serializable = "SERIALIZABLE"
}

public struct TransactionOptions: Equatable, Sendable {
    public var isolation: IsolationLevel?
    public var readOnly: Bool

    public init(isolation: IsolationLevel? = nil, readOnly: Bool = false) {
        self.isolation = isolation
        self.readOnly = readOnly
    }
}

/// An error the database reported, with what is needed to point at the cause in the editor.
public struct DatabaseServerError: Error, Equatable, Sendable, LocalizedError {
    public var message: String
    /// SQLSTATE (`42P01`) or the engine's own code, when it reports one.
    public var code: String?
    /// 1-based Unicode scalar position in the statement the server blames, when available.
    public var position: Int?
    public var detail: String?
    public var hint: String?

    public init(message: String, code: String? = nil, position: Int? = nil, detail: String? = nil, hint: String? = nil) {
        self.message = message
        self.code = code
        self.position = position
        self.detail = detail
        self.hint = hint
    }

    public var errorDescription: String? {
        var text = message
        if let detail, !detail.isEmpty { text += "\n" + detail }
        if let hint, !hint.isEmpty { text += "\nHint: " + hint }
        return text
    }
}

public struct DatabaseNotice: Equatable, Sendable {
    public let level: String
    public let code: String
    public let message: String

    public init(level: String, code: String, message: String) {
        self.level = level
        self.code = code
        self.message = message
    }
}

/// The outcome of one statement. The rows themselves are in the `ResultStore` the caller gave.
public struct ExecutionSummary: Equatable, Sendable {
    public var columns: [ResultColumn]
    /// Rows delivered into the store.
    public var rowCount: Int
    /// Rows changed by `INSERT`/`UPDATE`/`DELETE`/`MERGE` (from the command tag), when reported.
    public var affectedRows: Int?
    /// The server's command tag (`SELECT 3`, `UPDATE 1`, `BEGIN`).
    public var commandTag: String?
    public var duration: Duration
    /// The caller's store refused more rows, so the server was told to stop.
    public var limitReached: Bool
    /// The statement was cancelled before it finished.
    public var wasCancelled: Bool
    /// The statement committed the open transaction on its own (MySQL DDL and a few others), so
    /// what was done before it is permanent and the transaction is over.
    public var implicitlyCommitted: Bool
    public var notices: [DatabaseNotice]

    public init(
        columns: [ResultColumn] = [], rowCount: Int = 0, affectedRows: Int? = nil,
        commandTag: String? = nil, duration: Duration = .zero, limitReached: Bool = false,
        wasCancelled: Bool = false, implicitlyCommitted: Bool = false, notices: [DatabaseNotice] = []
    ) {
        self.implicitlyCommitted = implicitlyCommitted
        self.columns = columns
        self.rowCount = rowCount
        self.affectedRows = affectedRows
        self.commandTag = commandTag
        self.duration = duration
        self.limitReached = limitReached
        self.wasCancelled = wasCancelled
        self.notices = notices
    }
}

public struct ExecuteOptions: Equatable, Sendable {
    /// Run inside a read-only transaction regardless of how the connection is configured. Used for
    /// agent queries and previews, where the database, not a keyword scan, must refuse writes.
    public var forceReadOnly: Bool
    public var collectNotices: Bool

    public init(forceReadOnly: Bool = false, collectNotices: Bool = false) {
        self.forceReadOnly = forceReadOnly
        self.collectNotices = collectNotices
    }
}
