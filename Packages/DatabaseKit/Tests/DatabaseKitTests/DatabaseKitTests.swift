import Testing
import Foundation
@testable import DatabaseKit

struct DatabaseURLTests {
    @Test func parseMySQLConnectionURL() throws {
        let draft = try DatabaseURL.parse("mysql://root:secret@db.example.com:3307/app_db")
        #expect(draft.connection.engine == .mysql)
        #expect(draft.connection.host == "db.example.com")
        #expect(draft.connection.port == 3307)
        #expect(draft.connection.username == "root")
        #expect(draft.password == "secret")
        #expect(draft.connection.database == "app_db")
        #expect(draft.connection.useTLS)
    }

    @Test func parsePostgresConnectionURL() throws {
        let draft = try DatabaseURL.parse("postgres://alice:pass@localhost:5433/analytics?tlsmode=disable")
        #expect(draft.connection.engine == .postgres)
        #expect(draft.connection.host == "localhost")
        #expect(draft.connection.port == 5433)
        #expect(draft.connection.username == "alice")
        #expect(draft.password == "pass")
        #expect(draft.connection.database == "analytics")
        #expect(!draft.connection.useTLS)
    }

    @Test func buildOmitsPathWhenDatabaseIsEmpty() throws {
        let connection = DatabaseConnection(engine: .mysql, host: "db.example.com", port: 3306, username: "root")
        let url = DatabaseURL.build(connection, password: "secret")
        #expect(url == "mysql://root:secret@db.example.com:3306")
        let reparsed = try DatabaseURL.parse(url)
        #expect(reparsed.connection.database.isEmpty)
    }

    @Test func buildIncludesDatabaseWhenSet() {
        let connection = DatabaseConnection(
            engine: .postgres, host: "localhost", port: 5432, username: "alice", database: "analytics"
        )
        #expect(DatabaseURL.build(connection, password: "pass") == "postgresql://alice:pass@localhost:5432/analytics")
    }

    @Test func redactedSQLHidesThePassword() {
        let connection = DatabaseConnection(engine: .mysql, host: "db.example.com", port: 3306, username: "root")
        let redacted = DatabaseURL.redacted(connection, password: "secret")
        #expect(redacted.contains("***"))
        #expect(!redacted.contains("secret"))
    }

    @Test func quoteIdentifierUsesEngineSpecificQuoting() throws {
        let mysql = DatabaseConnection(engine: .mysql)
        let postgres = DatabaseConnection(engine: .postgres)
        #expect(try mysql.selectAll(from: "order") == "SELECT * FROM `order`")
        #expect(try postgres.selectAll(from: "items") == "SELECT * FROM \"items\"")
    }

    @Test func quoteIdentifierNeverLetsANameEscapeItsQuotes() throws {
        let mysql = DatabaseConnection(engine: .mysql)
        let postgres = DatabaseConnection(engine: .postgres)
        let sqlite = DatabaseConnection(engine: .sqlite)
        // A hostile name is one quoted identifier, not a second statement.
        #expect(try mysql.selectAll(from: "users; DROP TABLE users") == "SELECT * FROM `users; DROP TABLE users`")
        #expect(try postgres.selectAll(from: "a\" ; DROP TABLE x; --") == "SELECT * FROM \"a\"\" ; DROP TABLE x; --\"")
        #expect(try mysql.selectAll(from: "a` ; DROP TABLE x; --") == "SELECT * FROM `a`` ; DROP TABLE x; --`")
        // Real tables have such names.
        #expect(try sqlite.selectAll(from: "Order Details") == "SELECT * FROM \"Order Details\"")
        #expect(try postgres.selectAll(from: "Café") == "SELECT * FROM \"Café\"")
    }

    @Test func quoteIdentifierRefusesWhatCannotBeQuoted() {
        let connection = DatabaseConnection(engine: .mysql)
        #expect(throws: DatabaseError.self) { try connection.selectAll(from: "") }
        #expect(throws: DatabaseError.self) { try connection.selectAll(from: "a\u{0}b") }
        #expect(throws: DatabaseError.self) { try connection.selectAll(from: "a\nb") }
    }
}

struct SQLLoginHandshakeTests {
    @Test func emptyDatabaseOpensTheSchemaEveryServerKeeps() {
        #expect(SQLLogin(engine: .mysql, username: "root").handshakeDatabase == "information_schema")
        #expect(SQLLogin(engine: .postgres, username: "root").handshakeDatabase == "postgres")
    }

    @Test func explicitDatabaseIsKept() {
        #expect(SQLLogin(engine: .mysql, username: "root", database: "shop").handshakeDatabase == "shop")
        #expect(SQLLogin(engine: .postgres, username: "root", database: "shop").handshakeDatabase == "shop")
    }
}

struct SQLStatementTests {
    @Test func pagingDoesNotWrapWritesThatStartLikeSelects() {
        #expect(DatabaseQuery.canPage("WITH ready AS (SELECT id FROM jobs) SELECT * FROM ready"))
        #expect(!DatabaseQuery.canPage("WITH ready AS (SELECT id FROM jobs) DELETE FROM jobs WHERE id IN (SELECT id FROM ready)"))
        #expect(!DatabaseQuery.canPage("SELECT * INTO backup FROM jobs"))
        #expect(!DatabaseQuery.canPage("SELECT nextval('job_id')"))
    }

    @Test func readOnlyAllowsReadsAndBlocksWrites() {
        #expect(SQLShaping.isReadOnlyStatement("SELECT * FROM users"))
        #expect(SQLShaping.isReadOnlyStatement("-- Browse products\nSELECT * FROM product;"))
        #expect(SQLShaping.isReadOnlyStatement("/* Browse products */ SELECT * FROM product;"))
        #expect(SQLShaping.isReadOnlyStatement("WITH cte AS (SELECT 1) SELECT * FROM cte"))
        #expect(SQLShaping.isReadOnlyStatement("SHOW TABLES"))
        #expect(SQLShaping.isReadOnlyStatement("EXPLAIN SELECT 1"))
        #expect(!SQLShaping.isReadOnlyStatement("INSERT INTO users VALUES (1)"))
        #expect(!SQLShaping.isReadOnlyStatement("UPDATE users SET active = 1"))
        #expect(!SQLShaping.isReadOnlyStatement("DELETE FROM users"))
    }

    @Test func readOnlyRefusesWritesHiddenBehindAReadKeyword() {
        // Data-modifying CTE: starts with WITH, deletes rows.
        #expect(!SQLShaping.isReadOnlyStatement(
            "WITH gone AS (DELETE FROM users RETURNING *) SELECT * FROM gone"
        ))
        #expect(!SQLShaping.isReadOnlyStatement("EXPLAIN ANALYZE DELETE FROM users"))
        #expect(!SQLShaping.isReadOnlyStatement("SELECT * INTO backup FROM users"))
        #expect(!SQLShaping.isReadOnlyStatement("SELECT * FROM users INTO OUTFILE '/tmp/x'"))
        #expect(!SQLShaping.isReadOnlyStatement("SELECT nextval('seq')"))
        #expect(!SQLShaping.isReadOnlyStatement("SELECT pg_terminate_backend(42)"))
        #expect(!SQLShaping.isReadOnlyStatement("SELECT 1; DROP TABLE users"))
        #expect(!SQLShaping.isReadOnlyStatement("SELECT 1; SELECT 2"))
        #expect(!SQLShaping.isReadOnlyStatement("PRAGMA writable_schema = 1"))
    }

    @Test func readOnlyIgnoresWriteWordsInsideStringsCommentsAndQuotedNames() {
        #expect(SQLShaping.isReadOnlyStatement("SELECT 'DELETE FROM users' AS note"))
        #expect(SQLShaping.isReadOnlyStatement("SELECT 'it''s an INSERT' FROM t"))
        #expect(SQLShaping.isReadOnlyStatement("SELECT \"update\" FROM t"))
        #expect(SQLShaping.isReadOnlyStatement("SELECT `into` FROM t"))
        #expect(SQLShaping.isReadOnlyStatement("SELECT 1 /* DROP TABLE x */ FROM t -- DELETE\n"))
        #expect(SQLShaping.isReadOnlyStatement("SELECT $q$DELETE FROM t$q$ AS body"))
        #expect(SQLShaping.isReadOnlyStatement("SELECT * FROM t WHERE id = $1"))
        #expect(SQLShaping.isReadOnlyStatement("SELECT 1;"))
    }

    @Test func composedQueryAddsLimitAndOffset() {
        let sql = SQLShaping.composedQuery(
            base: "SELECT * FROM users", quotedSortColumn: nil, sortAscending: true, limit: 50, offset: 100
        )
        #expect(sql == "SELECT * FROM (SELECT * FROM users) AS __umbra_q LIMIT 50 OFFSET 100")
    }

    @Test func composedQueryWithSortAddsOrderBy() {
        let sql = SQLShaping.composedQuery(
            base: "SELECT * FROM users;", quotedSortColumn: "\"name\"", sortAscending: false, limit: 20, offset: 0
        )
        #expect(sql == "SELECT * FROM (SELECT * FROM users) AS __umbra_q ORDER BY \"name\" DESC LIMIT 20 OFFSET 0")
    }

    @Test func composedQueryAlwaysRecomposesFromBase() {
        let first = SQLShaping.composedQuery(
            base: "SELECT * FROM users", quotedSortColumn: "\"id\"", sortAscending: true, limit: 10, offset: 0
        )
        let second = SQLShaping.composedQuery(
            base: "SELECT * FROM users", quotedSortColumn: "\"name\"", sortAscending: true, limit: 10, offset: 10
        )
        #expect(first.filter { $0 == "(" }.count == 1)
        #expect(second.filter { $0 == "(" }.count == 1)
    }
}

struct MongoURLTests {
    @Test func connectionURIIncludesAuthSourceAndTLS() {
        let login = MongoLogin(
            host: "db.local", port: 27017, username: "alice", password: "s3cret!",
            authSource: "admin", defaultDatabase: "shop", useTLS: true
        )
        let uri = MongoURLs.connectionURI(from: login)
        #expect(uri.hasPrefix("mongodb://alice:"))
        #expect(uri.contains("@db.local:27017/shop?"))
        #expect(uri.contains("directConnection=true"))
        #expect(uri.contains("authSource=admin"))
        #expect(uri.contains("tls=true"))
        #expect(!uri.contains("s3cret!"))
    }

    @Test func redactedURIHidesPassword() {
        let connection = DatabaseConnection(
            engine: .mongo, host: "localhost", username: "bob", database: "app"
        )
        let redacted = DatabaseURL.redacted(connection, password: "hunter2")
        #expect(redacted.contains("***"))
        #expect(!redacted.contains("hunter2"))
    }

    @Test func parseRoundTripsSRV() throws {
        let draft = try DatabaseURL.parse(
            "mongodb+srv://myDatabaseUser:D1fficultP%40ssw0rd@server.example.com/"
        )
        #expect(draft.connection.engine == .mongo)
        #expect(draft.connection.useSRV)
        #expect(draft.connection.host == "server.example.com")
        #expect(draft.password == "D1fficultP@ssw0rd")
        #expect(draft.connection.useTLS)
        #expect(!draft.connection.directConnection)
        let built = DatabaseURL.build(draft.connection, password: draft.password)
        #expect(built.hasPrefix("mongodb+srv://"))
        #expect(!built.contains(":27017"))
        #expect(!built.contains("D1fficultP@ssw0rd"))
    }

    @Test func parseAcceptsReplicaSetAndSemicolonSeparators() throws {
        let draft = try DatabaseURL.parse(
            "mongodb://alice:secret@db0.example.com:27017,db1.example.com:27017/app?replicaSet=myRepl;tls=true"
        )
        #expect(draft.connection.host == "db0.example.com")
        #expect(draft.connection.port == 27017)
        #expect(draft.connection.replicaSet == "myRepl")
        #expect(draft.connection.useTLS)
        #expect(!draft.connection.directConnection)
        #expect(draft.connection.database == "app")
        #expect(draft.connection.authSource == "app")
    }

    @Test func parseRejectsSRVWithAPort() {
        #expect(throws: DatabaseError.self) {
            try DatabaseURL.parse("mongodb+srv://cluster.example.com:27017/")
        }
    }
}

private struct FakeSQL: SQLExecuting, @unchecked Sendable {
    var queryHandler: @Sendable (String) -> QueryResult

    func query(_ sql: String) async throws -> QueryResult {
        queryHandler(sql)
    }
}

struct DatabaseQueryTests {
    @Test func selectFillsTheResultAndPagesIt() async throws {
        let session = FakeSQL { sql in
            #expect(sql.contains("LIMIT 200 OFFSET 0"))
            return QueryResult(columns: ["n"], rows: [["1"]], rowsAffected: nil, isReadQuery: true)
        }
        let result = try await DatabaseQuery.run(
            statement: "SELECT 1",
            readOnly: false,
            page: 0,
            pageSize: DatabasePageSize.sql,
            engine: .postgres,
            using: session
        )
        #expect(result.columns == ["n"])
        #expect(result.rows == [["1"]])
    }

    @Test func readOnlyRefusesAMutatingStatement() async {
        let session = FakeSQL { _ in
            Issue.record("The session must not run a refused statement")
            return QueryResult(columns: [], rows: [], rowsAffected: nil, isReadQuery: false)
        }
        await #expect(throws: DatabaseError.readOnlyViolation) {
            try await DatabaseQuery.run(
                statement: "DELETE FROM users",
                readOnly: true,
                page: 0,
                pageSize: 200,
                engine: .mysql,
                using: session
            )
        }
    }
}
