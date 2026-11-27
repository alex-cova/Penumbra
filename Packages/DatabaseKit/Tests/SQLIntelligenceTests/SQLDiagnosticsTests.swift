import Foundation
import Testing

@testable import SQLIntelligence

private func col(_ name: String, _ type: String = "integer") -> SQLCatalog.Column { SQLCatalog.Column(name: name, typeName: type) }

private let catalog = SQLCatalog(
    relations: [
        .init(name: "customers", columns: [col("id"), col("name", "text"), col("email", "text"), col("created_at", "timestamp")]),
        .init(name: "orders", columns: [col("id"), col("customer_id"), col("total", "numeric"), col("placed_at", "timestamp")]),
        .init(name: "employees", columns: [col("id"), col("name", "text"), col("manager_id")]),
    ],
    isComplete: true
)

private func diagnose(_ sql: String, _ dialect: SQLDialect = .postgres, catalog: SQLCatalog = catalog) -> [SQLDiagnostic] {
    SQLDiagnosticsEngine.diagnose(text: sql, dialect: dialect, catalog: catalog)
}

private func codes(_ sql: String, _ dialect: SQLDialect = .postgres, catalog: SQLCatalog = catalog) -> [String] {
    diagnose(sql, dialect, catalog: catalog).map(\.code)
}

struct SQLDiagnosticsNoFalsePositivesTests {
    @Test func validQueriesProduceNothing() {
        let valid = [
            "SELECT 1",
            "SELECT now()",
            "SELECT * FROM customers",
            "SELECT c.id, c.name AS who, count(*) AS n FROM customers c GROUP BY c.id, c.name HAVING count(*) > 1 ORDER BY n DESC, who",
            "SELECT id, name FROM customers WHERE email LIKE '%@x.com' AND created_at > now() - interval '1 day'",
            "SELECT c.name, o.total FROM customers c LEFT JOIN orders o ON o.customer_id = c.id WHERE o.total IS NOT NULL ORDER BY o.total DESC LIMIT 10",
            "SELECT CASE WHEN total > 100 THEN 'big' WHEN total > 10 THEN 'mid' ELSE 'small' END AS size FROM orders",
            "SELECT customer_id, sum(total) OVER (PARTITION BY customer_id ORDER BY placed_at ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) FROM orders",
            "SELECT EXTRACT(YEAR FROM created_at) AS y, count(*) FROM customers GROUP BY y",
            "SELECT id::text, total::numeric(10,2) FROM orders",
            "SELECT cast(total AS integer) FROM orders",
            "SELECT * FROM customers c WHERE EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.id)",
            "SELECT * FROM customers WHERE id IN (SELECT customer_id FROM orders WHERE total > 10)",
            "WITH big AS (SELECT customer_id, sum(total) AS spent FROM orders GROUP BY customer_id) SELECT c.name, b.spent FROM customers c JOIN big b ON b.customer_id = c.id",
            "WITH RECURSIVE tree AS (SELECT id, manager_id, 1 AS depth FROM employees WHERE manager_id IS NULL UNION ALL SELECT e.id, e.manager_id, t.depth + 1 FROM employees e JOIN tree t ON e.manager_id = t.id) SELECT * FROM tree",
            "SELECT d.id FROM (SELECT id FROM customers) d",
            "SELECT coalesce(email, 'none'), nullif(name, ''), upper(name), length(name) FROM customers",
            "INSERT INTO customers (id, name) VALUES (1, 'a'), (2, 'b')",
            "INSERT INTO customers (name, email) SELECT name, email FROM employees_import",
            "UPDATE customers SET name = upper(name), email = NULL WHERE id = 1",
            "DELETE FROM orders WHERE total < 0 AND customer_id IN (SELECT id FROM customers)",
            "SELECT count(DISTINCT customer_id) FROM orders",
            "SELECT a.id, b.id FROM customers a, customers b WHERE a.id < b.id",
            "SELECT id FROM customers UNION SELECT id FROM employees ORDER BY 1",
            "SELECT 'it''s' || name, \"name\" FROM customers",
            "SELECT t.* FROM customers t",
            "select ID, NAME from CUSTOMERS",
            "SELECT * FROM generate_series(1, 3)",
            "SELECT trim(both ' ' from name), replace(name, 'a', 'b') FROM customers",
        ]
        for sql in valid {
            // `employees_import` is not in the catalog: the unknown table is the one expected finding there.
            let found = codes(sql).filter { $0 != "unknown-table" || !sql.contains("employees_import") }
            #expect(found.isEmpty, Comment(rawValue: "false positive \(found) in: \(sql)"))
        }
    }

    @Test func otherDialectsWriteTheirOwnValidSQL() {
        #expect(codes("SELECT `name`, IFNULL(email, '') FROM `customers` WHERE id = 1", .mysql).isEmpty)
        #expect(codes("SELECT name, iif(id > 1, 'a', 'b'), strftime('%Y', created_at) FROM customers", .sqlite).isEmpty)
        #expect(codes("SELECT [name] FROM customers", .sqlite).isEmpty)
        #expect(codes("INSERT INTO customers (name) VALUES ('a') ON DUPLICATE KEY UPDATE name = VALUES(name)", .mysql).isEmpty)
        #expect(codes("INSERT INTO customers (id, name) VALUES (1, 'a') ON CONFLICT (id) DO UPDATE SET name = excluded.name", .postgres).isEmpty)
    }
}

struct SQLDiagnosticsFindingsTests {
    @Test func unknownTablesAreReportedOnlyForACompleteCatalog() {
        let result = diagnose("SELECT * FROM cutomers")
        #expect(result.map(\.code) == ["unknown-table"])
        #expect(result[0].severity == .error)
        #expect(result[0].message == "There is no table or view named \"cutomers\".")
        #expect((("SELECT * FROM cutomers" as NSString).substring(with: result[0].range)) == "cutomers")
        #expect(codes("SELECT * FROM customers c JOIN ordrs o ON o.customer_id = c.id") == ["unknown-table"])
        var incomplete = catalog
        incomplete.isComplete = false
        #expect(codes("SELECT * FROM cutomers", catalog: incomplete).isEmpty, "not loaded is not unknown")
        // A CTE is not a missing table.
        #expect(codes("WITH cutomers AS (SELECT 1 AS x) SELECT x FROM cutomers").isEmpty)
        // An offline catalog (nothing loaded) says nothing at all.
        #expect(codes("SELECT nope FROM nothing", catalog: SQLCatalog()).isEmpty)
    }

    @Test func unknownColumnsNameTheSourceWhenQualified() {
        let qualified = diagnose("SELECT c.nmae FROM customers c")
        #expect(qualified.map(\.code) == ["unknown-column"])
        #expect(qualified[0].message == "\"c\" has no column \"nmae\".")
        #expect(codes("SELECT nmae FROM customers") == ["unknown-column"])
        #expect(codes("SELECT * FROM customers WHERE emial = 'x'") == ["unknown-column"])
        #expect(codes("SELECT * FROM customers c JOIN orders o ON o.custmer_id = c.id") == ["unknown-column"])
        #expect(codes("SELECT * FROM customers ORDER BY nmae") == ["unknown-column"])
        // An unknown table makes its columns unknowable, so no column is blamed.
        #expect(codes("SELECT x.anything FROM cutomers x") == ["unknown-table"])
        // Neither does a table function.
        #expect(codes("SELECT g.anything FROM generate_series(1, 3) g").isEmpty)
    }

    @Test func ambiguousColumnsOfferTheQualifyingFix() {
        let result = diagnose("SELECT id FROM customers c JOIN orders o ON o.customer_id = c.id")
        #expect(result.map(\.code) == ["ambiguous-column"])
        #expect(result[0].message == "\"id\" is ambiguous: it is in \"c\" and \"o\".")
        #expect(result[0].fixes.map(\.title) == ["Qualify as c.id", "Qualify as o.id"])
        #expect(result[0].fixes.map(\.replacement) == ["c.id", "o.id"])
        #expect(codes("SELECT c.id, o.id FROM customers c JOIN orders o ON o.customer_id = c.id").isEmpty)
        #expect(codes("SELECT name FROM customers c JOIN orders o ON o.customer_id = c.id").isEmpty, "name is only in customers")
    }

    @Test func selectAliasesAreVisibleToOrderByAndHaving() {
        #expect(codes("SELECT customer_id, sum(total) AS spent FROM orders GROUP BY customer_id HAVING sum(total) > 1 ORDER BY spent").isEmpty)
        #expect(codes("SELECT customer_id, sum(total) AS spent FROM orders WHERE spent > 1") == ["unknown-column"], "but not to WHERE")
    }

    @Test func textProblems() {
        #expect(codes("SELECT 'abc") == ["unterminated-string"])
        #expect(codes("SELECT 1 /* never closed") == ["unterminated-comment"])
        #expect(codes("SELECT \"half FROM customers") == ["unterminated-identifier"])
        #expect(codes("SELECT count(* FROM customers").contains("unclosed-parenthesis"))
        #expect(codes("SELECT 1)") == ["unmatched-parenthesis"])
        #expect(codes("SELECT ((1)").contains("unclosed-parenthesis"))
    }

    @Test func insertCountsMustMatch() {
        let result = diagnose("INSERT INTO customers (id, name) VALUES (1, 'a', 'extra'), (2, 'b')")
        #expect(result.map(\.code) == ["insert-count"])
        #expect(result[0].message == "2 columns listed but 3 values given.")
        #expect(codes("INSERT INTO customers (id, name) VALUES (1)") == ["insert-count"])
        #expect(codes("INSERT INTO customers (id, name) VALUES (1, 'a'), (2, 'b')").isEmpty)
        #expect(codes("INSERT INTO customers (id) VALUES (now()), (coalesce(1, 2))").isEmpty, "commas inside a call are not values")
        #expect(codes("INSERT INTO customers VALUES (1, 'a')").isEmpty, "no column list: nothing to compare")
    }

    @Test func wrongArgumentCounts() {
        #expect(codes("SELECT nullif(name) FROM customers") == ["function-arity"])
        #expect(diagnose("SELECT nullif(name) FROM customers")[0].message == "nullif() takes 2 arguments, but 1 is given.")
        #expect(codes("SELECT replace(name, 'a') FROM customers") == ["function-arity"])
        #expect(codes("SELECT coalesce() FROM customers") == ["function-arity"])
        #expect(codes("SELECT lower(name, email) FROM customers") == ["function-arity"])
        #expect(codes("SELECT coalesce(a.x, b(1, 2), 3) FROM (SELECT 1 AS x) a, (SELECT 1) b") != ["function-arity"])
        #expect(codes("SELECT round(total, 2), round(total) FROM orders").isEmpty)
    }

    @Test func dialectProblems() {
        #expect(codes("SELECT * FROM customers WHERE name ILIKE 'a%'", .mysql) == ["dialect-ilike"])
        #expect(codes("SELECT * FROM customers WHERE name ILIKE 'a%'", .sqlite) == ["dialect-ilike"])
        #expect(codes("SELECT * FROM customers WHERE name ILIKE 'a%'", .postgres).isEmpty)
        #expect(codes("SELECT id::text FROM customers", .mysql) == ["dialect-cast"])
        #expect(codes("SELECT id::text FROM customers", .sqlite) == ["dialect-cast"])
        #expect(codes("INSERT INTO customers (id) VALUES (1) RETURNING id", .mysql) == ["dialect-returning"])
        #expect(codes("INSERT INTO customers (id) VALUES (1) RETURNING id", .postgres).isEmpty)
        #expect(codes("SELECT `name` FROM customers", .postgres).contains("dialect-backtick"))
        #expect(codes("INSERT INTO customers (id) VALUES (1) ON CONFLICT DO NOTHING", .mysql).contains("dialect-on-conflict"))
        #expect(codes("INSERT INTO customers (id) VALUES (1) ON DUPLICATE KEY UPDATE id = 1", .postgres).contains("dialect-on-duplicate"))
        #expect(codes("CREATE TABLE t (id INT AUTO_INCREMENT)", .postgres).contains("dialect-auto-increment"))
        #expect(codes("CREATE TABLE t (id SERIAL)", .mysql).contains("dialect-serial"))
    }

    @Test func diagnosticsAreOrderedAndEachStatementIsCheckedOnItsOwn() {
        let result = diagnose("SELECT * FROM cutomers;\nSELECT x.zzz FROM customers x;\nSELECT 'open")
        #expect(result.map(\.code) == ["unknown-table", "unknown-column", "unterminated-string"])
        #expect(result.map(\.range.location) == result.map(\.range.location).sorted())
    }

    @Test func anythingYouTypeProducesDiagnosticsWithoutTrapping() {
        let pieces = ["(", ")", "'", "\"", "SELECT", "FROM", "customers", "c", ".", "id", ",", ";", "JOIN", "ON", "=", "WITH", "AS", "$$", "/*", "x", "VALUES", "INSERT INTO", "::", "😀"]
        var seed: UInt64 = 42
        func next() -> Int { seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return Int(seed >> 33) }
        for _ in 0..<500 {
            let text = (0..<(next() % 16 + 1)).map { _ in pieces[next() % pieces.count] }.joined(separator: " ")
            for dialect in SQLDialect.allCases {
                let findings = SQLDiagnosticsEngine.diagnose(text: text, dialect: dialect, catalog: catalog)
                for finding in findings { #expect(finding.range.location >= 0 && finding.range.location + finding.range.length <= text.utf16.count) }
            }
        }
    }
}
