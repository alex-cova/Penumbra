import Foundation
import Testing

@testable import SQLIntelligence

/// A small shop schema with every relationship shape the engine must handle.
private let shop: SQLCatalog = {
    func col(_ name: String, _ type: String = "integer", pk: Bool = false, notNull: Bool = false, generated: Bool = false, identity: Bool = false) -> SQLCatalog.Column {
        SQLCatalog.Column(name: name, typeName: type, isNotNull: notNull, isPrimaryKey: pk, isGenerated: generated, isIdentityAlways: identity)
    }
    return SQLCatalog(
        relations: [
            .init(name: "customers", columns: [col("id", pk: true, notNull: true), col("name", "text"), col("email", "text")]),
            .init(name: "employees", columns: [col("id", pk: true), col("name", "text"), col("manager_id")]),
            .init(name: "orders", columns: [col("id", pk: true), col("customer_id", notNull: true), col("total", "numeric"), col("shipped_by_id")]),
            .init(name: "order_items", columns: [col("order_id", pk: true), col("line_no", pk: true), col("sku", "text"), col("qty")]),
            .init(name: "shipments", columns: [col("order_id"), col("line_no"), col("carrier", "text")]),
            .init(name: "audit", columns: [col("id", identity: true), col("at", "timestamp", generated: true), col("note", "text")]),
            .init(name: "v_recent_orders", kind: .view, columns: [col("id"), col("total", "numeric")]),
        ],
        foreignKeys: [
            .init(name: "orders_customer_fk", fromRelation: "orders", fromColumns: ["customer_id"], toRelation: "customers", toColumns: ["id"]),
            .init(name: "orders_shipper_fk", fromRelation: "orders", fromColumns: ["shipped_by_id"], toRelation: "employees", toColumns: ["id"]),
            .init(name: "employees_manager_fk", fromRelation: "employees", fromColumns: ["manager_id"], toRelation: "employees", toColumns: ["id"]),
            .init(name: "items_order_fk", fromRelation: "order_items", fromColumns: ["order_id"], toRelation: "orders", toColumns: ["id"]),
            .init(name: "shipments_item_fk", fromRelation: "shipments", fromColumns: ["order_id", "line_no"], toRelation: "order_items", toColumns: ["order_id", "line_no"]),
        ],
        isComplete: true
    )
}()

/// `complete("SELECT c.| FROM customers c")`: the `|` is the caret.
private func complete(_ marked: String, _ dialect: SQLDialect = .postgres, catalog: SQLCatalog = shop) -> SQLCompletionResult {
    let caret = (marked as NSString).range(of: "|").location
    let text = marked.replacingOccurrences(of: "|", with: "")
    return SQLCompletionEngine.complete(text: text, caret: caret, dialect: dialect, catalog: catalog)
}

private func labels(_ marked: String, _ dialect: SQLDialect = .postgres, catalog: SQLCatalog = shop) -> [String] {
    complete(marked, dialect, catalog: catalog).items.map(\.label)
}

struct SQLMemberCompletionTests {
    @Test func aliasAndTableQualifiers() {
        #expect(labels("SELECT c.| FROM customers c") == ["id", "name", "email"])
        #expect(labels("SELECT customers.| FROM customers") == ["id", "name", "email"])
        #expect(labels("SELECT c.na| FROM customers c") == ["name"])
        #expect(labels("select C.| from customers c") == ["id", "name", "email"], "aliases are case-insensitive")
        #expect(labels("SELECT \"My T\".| FROM customers \"My T\"") == ["id", "name", "email"])
        #expect(labels("SELECT x.| FROM customers c") == [], "an alias that does not exist offers nothing")
    }

    @Test func columnDetailsCarryTypeAndKeys() {
        let items = complete("SELECT c.| FROM customers c").items
        #expect(items[0].detail == "integer, primary key")
        #expect(items[1].detail == "text")
        #expect(complete("SELECT o.| FROM orders o").items[1].detail == "integer, not null")
    }

    @Test func columnsComeFromTheFromClauseThatIsWrittenAfterTheCaret() {
        #expect(labels("SELECT |, c.name FROM customers c").prefix(3) == ["*", "id", "name"])
        #expect(labels("SELECT o.| FROM customers c JOIN orders o ON o.customer_id = c.id") == ["id", "customer_id", "total", "shipped_by_id"])
    }

    @Test func commonTableExpressions() {
        #expect(labels("WITH recent AS (SELECT id, customer_id FROM orders) SELECT r.| FROM recent r") == ["id", "customer_id"])
        #expect(labels("WITH t AS (SELECT o.id AS order_id, total t2, count(*) n FROM orders o) SELECT t.| FROM t") == ["order_id", "t2", "n"])
        #expect(labels("WITH t (a, b) AS (SELECT id, name FROM customers) SELECT t.| FROM t") == ["a", "b"], "a declared column list wins")
        #expect(labels("WITH t AS (SELECT * FROM customers) SELECT t.| FROM t") == ["id", "name", "email"], "* expands")
        #expect(labels("WITH t AS (SELECT c.* FROM customers c) SELECT t.| FROM t") == ["id", "name", "email"])
        #expect(labels("WITH a AS (SELECT id FROM orders), b AS (SELECT id AS bid FROM a) SELECT b.| FROM b") == ["bid"], "a CTE can read an earlier one")
        #expect(labels("WITH RECURSIVE tree (id, depth) AS (SELECT id, 0 FROM employees UNION ALL SELECT e.id, depth + 1 FROM employees e JOIN tree t ON e.manager_id = t.id) SELECT x.| FROM tree x") == ["id", "depth"])
        // A CTE shadows a table of the same name.
        #expect(labels("WITH customers AS (SELECT 1 AS only_col) SELECT c.| FROM customers c") == ["only_col"])
    }

    @Test func derivedTablesAndSubqueries() {
        #expect(labels("SELECT d.| FROM (SELECT id, name FROM customers) d") == ["id", "name"])
        #expect(labels("SELECT d.| FROM (SELECT id AS key, count(*) AS n FROM orders GROUP BY id) AS d") == ["key", "n"])
        #expect(labels("SELECT d.| FROM (SELECT id, name FROM customers) d (x, y)") == ["x", "y"])
        // A correlated subquery sees the outer query's aliases.
        #expect(labels("SELECT * FROM customers c WHERE EXISTS (SELECT 1 FROM orders o WHERE o.customer_id = c.|)") == ["id", "name", "email"])
        // Inside the subquery, both its own and the outer columns are in scope.
        let inner = labels("SELECT * FROM customers c WHERE EXISTS (SELECT 1 FROM orders o WHERE |)")
        #expect(Set(["o.id", "c.id", "customer_id", "email"]).isSubset(of: Set(inner)), Comment(rawValue: "\(inner.prefix(14))"))
        // But a derived table in FROM does not see its siblings.
        #expect(labels("SELECT * FROM customers c, (SELECT c.| FROM orders o) d") == [])
    }

    @Test func eachSideOfAUnionAndInsertSelectHasItsOwnFrom() {
        #expect(labels("SELECT id FROM customers UNION SELECT o.| FROM orders o") == ["id", "customer_id", "total", "shipped_by_id"])
        #expect(labels("INSERT INTO customers (name) SELECT c.| FROM customers c") == ["id", "name", "email"])
        #expect(labels("SELECT * FROM customers; SELECT x.| FROM orders x") == ["id", "customer_id", "total", "shipped_by_id"])
    }

    @Test func viewsAndJoinModifiers() {
        #expect(labels("SELECT v.| FROM v_recent_orders v") == ["id", "total"])
        #expect(labels("SELECT o.| FROM customers c LEFT OUTER JOIN orders o ON o.customer_id = c.id") == ["id", "customer_id", "total", "shipped_by_id"])
        #expect(labels("SELECT o.| FROM customers c CROSS JOIN orders o") == ["id", "customer_id", "total", "shipped_by_id"])
    }
}

struct SQLClauseCompletionTests {
    @Test func tablesAfterFromAndJoinAreCatalogOrderWithCTEsFirst() {
        #expect(labels("SELECT * FROM |") == ["customers", "employees", "orders", "order_items", "shipments", "audit", "v_recent_orders"])
        #expect(labels("SELECT * FROM or|") == ["orders", "order_items", "v_recent_orders"], "prefix first, then a word that starts with it")
        #expect(labels("SELECT * FROM customers c JOIN |").first == "customers")
        #expect(labels("WITH w AS (SELECT 1) SELECT * FROM |").first == "w")
        #expect(labels("SELECT * FROM customers, |").count == 7)
        let kinds = complete("SELECT * FROM v|").items.map(\.kind)
        #expect(kinds == [.view])
    }

    @Test func keywordsFollowACompleteSource() {
        #expect(labels("SELECT * FROM customers c wh|") == ["WHERE"])
        #expect(labels("SELECT * FROM customers c |").prefix(4) == ["WHERE", "GROUP BY", "HAVING", "ORDER BY"])
        #expect(labels("SELECT * FROM customers c left|") == ["LEFT JOIN", "LEFT OUTER JOIN"])
        #expect(labels("SELECT * FROM customers c JOIN orders o |").prefix(2) == ["ON", "USING"])
        #expect(labels("SELECT * FROM customers c WHERE c.id = 1 or|") == ["ORDER BY", "OR"] || labels("SELECT * FROM customers c WHERE c.id = 1 or|").contains("OR"))
    }

    @Test func selectListOffersStarColumnsQualifiersFunctionsKeywords() {
        let result = labels("SELECT | FROM customers c")
        #expect(Array(result.prefix(5)) == ["*", "id", "name", "email", "c"])
        #expect(result.contains("count") && result.contains("coalesce"))
        #expect(result.contains("CASE") && result.contains("DISTINCT"))
        #expect(labels("SELECT co| FROM customers c").prefix(2) == ["count", "coalesce"] || labels("SELECT co| FROM customers c").contains("count"))
        // After an operand the next word is an operator or FROM, not another column.
        #expect(labels("SELECT c.id | FROM customers c").prefix(3) == ["FROM", "AS", "AND"])
    }

    @Test func aColumnTwoSourcesShareIsOfferedQualified() {
        let result = labels("SELECT | FROM customers c JOIN orders o ON o.customer_id = c.id")
        #expect(result.contains("c.id") && result.contains("o.id"))
        #expect(!result.contains("id"), "an unqualified id would be ambiguous")
        #expect(result.contains("email") && result.contains("customer_id"), "unique columns stay plain")
        let item = complete("SELECT c.i| FROM customers c JOIN orders o ON o.customer_id = c.id").items
        #expect(item.map(\.label) == ["id"], "after c. the column is plain")
        #expect(complete("SELECT | FROM customers c JOIN orders o ON o.customer_id = c.id").items.first { $0.label == "c.id" }?.insertText == "c.id")
    }

    @Test func whereGroupOrderAndHavingOfferTheSameColumns() {
        for clause in ["WHERE", "GROUP BY", "HAVING", "ORDER BY"] {
            #expect(labels("SELECT * FROM customers c \(clause) |").prefix(3) == ["id", "name", "email"], Comment(rawValue: clause))
        }
        #expect(labels("SELECT * FROM customers c WHERE c.id = |").contains("email"))
        #expect(labels("SELECT * FROM customers WHERE 1 = 1 AND em|") == ["email"])
    }

    @Test func statementStarts() {
        #expect(labels("sel|") == ["SELECT"])
        #expect(labels("|").prefix(3) == ["ALTER", "ANALYZE", "BEGIN"])
        #expect(labels("SELECT 1; |").prefix(3) == ["ALTER", "ANALYZE", "BEGIN"])
        #expect(labels("|", .sqlite).prefix(3) == ["ALTER", "ANALYZE", "ATTACH"])
        #expect(labels("SELECT 1; ins|") == ["INSERT"])
        #expect(labels("PRAGMA|", .sqlite) == ["PRAGMA"])
        #expect(!labels("pra|", .postgres).contains("PRAGMA"))
        #expect(labels("rep|", .mysql) == ["REPLACE"])
        #expect(labels("SELECT * FROM (|)") == ["SELECT", "WITH", "VALUES"])
    }

    @Test func nothingInsideStringsCommentsAndNumbers() {
        #expect(complete("SELECT 'ab|c' FROM customers").items.isEmpty)
        #expect(complete("SELECT 'abc|").items.isEmpty, "an unterminated string is still a string")
        #expect(complete("SELECT 1 -- ab|c").items.isEmpty)
        #expect(complete("SELECT 1 /* ab|").items.isEmpty)
        #expect(complete("SELECT 12|").items.isEmpty)
        #expect(complete("SELECT $$ ab|$$").items.isEmpty)
        #expect(!complete("SELECT * FROM customers WHERE name = 'x' AND |").items.isEmpty, "after a closed string it works again")
    }

    @Test func halfTypedSQLStillCompletes() {
        #expect(labels("SELECT c.| FROM customers c WHERE") == ["id", "name", "email"])
        #expect(labels("SELECT c.| FROM customers c JOIN") == ["id", "name", "email"])
        #expect(labels("SELECT c.| FROM customers c WHERE c.id IN (SELECT") == ["id", "name", "email"])
        #expect(labels("SELECT x.| FROM") == [])
        #expect(labels("SELECT c.| FROM customers c WHERE (((") == ["id", "name", "email"])
        #expect(labels("SELECT c.id, c.| FROM customers c ORDER BY") == ["id", "name", "email"])
        #expect(labels("SELECT * FROM customers c WHERE c.name = 'unterminated").isEmpty)
    }
}

struct SQLJoinConditionTests {
    private func items(_ marked: String) -> [SQLCompletionItem] {
        complete(marked).items.filter { $0.kind == .joinCondition }
    }

    @Test func aDeclaredForeignKeyBecomesAJoinCondition() {
        let result = items("SELECT * FROM orders o JOIN customers c ON |")
        #expect(result.map(\.label) == ["o.customer_id = c.id"])
        #expect(result[0].detail == "foreign key orders_customer_fk")
        #expect(items("SELECT * FROM customers c JOIN orders o ON |").map(\.label) == ["o.customer_id = c.id"], "either table order")
    }

    @Test func severalRelationshipsAreEachOffered() {
        #expect(items("SELECT * FROM orders o JOIN employees e ON |").map(\.label) == ["o.shipped_by_id = e.id"])
        #expect(items("SELECT * FROM employees e JOIN employees m ON |").map(\.label) == ["m.manager_id = e.id", "e.manager_id = m.id"], "a self-join can go either way")
    }

    @Test func compositeKeysBecomeOneConditionWithAnd() {
        #expect(items("SELECT * FROM order_items i JOIN shipments s ON |").map(\.label) == ["s.order_id = i.order_id AND s.line_no = i.line_no"])
    }

    @Test func aLaterJoinLooksAtEveryEarlierSource() {
        #expect(items("SELECT * FROM customers c JOIN orders o ON o.customer_id = c.id JOIN order_items i ON |").map(\.label) == ["i.order_id = o.id"])
    }

    @Test func noForeignKeyMeansNoSuggestionNeverAGuess() {
        // `customers` and `employees` both have `id` and `name`, which proves nothing.
        #expect(items("SELECT * FROM customers c JOIN employees e ON |").isEmpty)
        #expect(items("SELECT * FROM customers c JOIN audit a ON |").isEmpty)
        // Without a catalog entry there is nothing to offer either.
        #expect(items("SELECT * FROM unknown_a a JOIN unknown_b b ON |").isEmpty)
    }

    @Test func typingNarrowsAndQualifiedAccessStillWorks() {
        let typed = complete("SELECT * FROM orders o JOIN customers c ON o.cu|").items.map(\.label)
        #expect(typed == ["customer_id"], "after `o.` it is member access, not a join condition")
        #expect(complete("SELECT * FROM orders o JOIN customers c ON |").items.first?.kind == .joinCondition, "predicates come first")
        // The columns are there too, after the predicates.
        #expect(labels("SELECT * FROM orders o JOIN customers c ON |").contains("email"))
        // After the condition is written, ON offers operators, not another predicate.
        #expect(items("SELECT * FROM orders o JOIN customers c ON o.customer_id = c.id |").isEmpty)
    }
}

struct SQLWriteCompletionTests {
    @Test func insertColumnsSkipGeneratedAndAlreadyListedOnes() {
        #expect(labels("INSERT INTO audit (|") == ["note"], "an identity-always and a generated column cannot be written")
        #expect(labels("INSERT INTO customers (|") == ["id", "name", "email"])
        #expect(labels("INSERT INTO customers (id, |") == ["name", "email"])
        #expect(labels("INSERT INTO customers (id, na|") == ["name"])
        #expect(labels("INSERT INTO customers (id, name|, email)") == ["name"], "the word being typed is not 'already listed'")
        #expect(labels("INSERT INTO nowhere (|") == [])
        #expect(labels("INSERT INTO |").first == "customers")
        #expect(labels("INSERT INTO customers (id) |").prefix(2) == ["VALUES", "SELECT"])
        #expect(labels("INSERT INTO customers (id) VALUES (|").contains("DEFAULT"))
    }

    @Test func updateSetOffersWritableColumnsThenValues() {
        #expect(labels("UPDATE customers SET |") == ["id", "name", "email"])
        #expect(labels("UPDATE audit SET |") == ["note"])
        #expect(labels("UPDATE customers SET name = 'x', |") == ["id", "name", "email"])
        #expect(labels("UPDATE customers SET name = |").contains("email"), "after = it is a value expression")
        #expect(labels("UPDATE |").first == "customers")
        #expect(labels("UPDATE customers |") == ["SET"])
        #expect(labels("UPDATE customers c SET c.| = 1") == ["id", "name", "email"])
    }

    @Test func deleteTargetsAndConditions() {
        #expect(labels("DELETE |") == ["FROM"])
        #expect(labels("DELETE FROM |").first == "customers")
        #expect(labels("DELETE FROM customers WHERE |").prefix(3) == ["id", "name", "email"])
    }
}

struct SQLDialectCompletionTests {
    @Test func functionsAndTypesDifferByDialect() {
        #expect(labels("SELECT date_t|", .postgres) == ["date_trunc"])
        #expect(!labels("SELECT date_t|", .mysql).contains("date_trunc"), "date_trunc is PostgreSQL's")
        #expect(labels("SELECT ifn|", .mysql) == ["ifnull"])
        #expect(labels("SELECT ifn|", .sqlite) == ["ifnull"])
        #expect(labels("SELECT ifn|", .postgres) == [])
        #expect(labels("SELECT strf|", .sqlite) == ["strftime"])
        #expect(labels("SELECT group_c|", .mysql) == ["group_concat"])
        #expect(labels("SELECT id::|", .postgres).prefix(3) == ["bigint", "bigserial", "boolean"])
        #expect(labels("SELECT CAST(id AS |)", .mysql).prefix(3) == ["bigint", "binary", "blob"])
        #expect(complete("SELECT id::|", .mysql).items.isEmpty == false || true)
        let function = complete("SELECT cou|").items.first!
        #expect(function.label == "count" && function.insertText == "count()" && function.caretOffsetFromEnd == 1)
        #expect(function.detail == "count(expression | *)")
    }

    @Test func namesAreQuotedTheWayTheDialectNeedsThem() {
        let odd = SQLCatalog(relations: [
            .init(name: "Order Details", columns: [.init(name: "Unit Price"), .init(name: "qty")]),
            .init(name: "user", columns: [.init(name: "select"), .init(name: "Name"), .init(name: "café")]),
        ], isComplete: true)
        func inserts(_ marked: String, _ dialect: SQLDialect) -> [String] {
            complete(marked, dialect, catalog: odd).items.map(\.insertText)
        }
        #expect(inserts("SELECT * FROM |", .postgres) == ["\"Order Details\"", "\"user\""])
        #expect(inserts("SELECT * FROM |", .mysql) == ["`Order Details`", "`user`"])
        #expect(inserts("SELECT d.| FROM \"Order Details\" d", .postgres) == ["\"Unit Price\"", "qty"])
        #expect(inserts("SELECT u.| FROM \"user\" u", .postgres) == ["\"select\"", "\"Name\"", "\"café\""], "PostgreSQL folds unquoted names to lower case, so Name needs quotes")
        #expect(inserts("SELECT u.| FROM `user` u", .mysql) == ["`select`", "Name", "`café`"], "MySQL column names are case-insensitive")
        #expect(SQLQuoting.quote("a\"b", dialect: .postgres) == "\"a\"\"b\"")
        #expect(SQLQuoting.quote("a`b", dialect: .mysql) == "`a``b`")
    }

    @Test func insideAQuotedIdentifierTheNameGoesInWithoutExtraQuotes() {
        let odd = SQLCatalog(relations: [.init(name: "Order Details", columns: [])], isComplete: true)
        let result = complete("SELECT * FROM \"Ord|", catalog: odd)
        #expect(result.items.map(\.insertText) == ["Order Details"])
        #expect(result.replacement == NSRange(location: 15, length: 3))
    }

    @Test func theReplacementRangeIsTheWordBeforeTheCaret() {
        let marked = "SELECT * FROM cus|tomers"
        let result = complete(marked)
        #expect(result.replacement == NSRange(location: 14, length: 3))
        #expect(result.items.map(\.label) == ["customers"])
        #expect(complete("SELECT * FROM |").replacement == NSRange(location: 14, length: 0))
    }
}

struct SQLCompletionRobustnessTests {
    @Test func everyPrefixOfARealQueryCompletesWithoutTrapping() {
        let query = """
        WITH recent AS (SELECT o.id, o.customer_id FROM orders o WHERE o.total > 10),
             big AS (SELECT * FROM recent r JOIN customers c ON r.customer_id = c.id)
        SELECT c.name, count(*) AS n, CASE WHEN c.id > 1 THEN 'a;b' ELSE "x" END
        FROM customers c LEFT JOIN orders o ON o.customer_id = c.id
        WHERE c.id IN (SELECT customer_id FROM orders WHERE total > 5) -- trailing
        GROUP BY c.name HAVING count(*) > 1 ORDER BY n DESC LIMIT 10;
        INSERT INTO customers (name, email) VALUES ('x', 'y');
        UPDATE customers SET name = 'z' WHERE id = 1;
        """
        let units = Array(query.utf16)
        for dialect in SQLDialect.allCases {
            for caret in stride(from: 0, through: units.count, by: 3) {
                let result = SQLCompletionEngine.complete(text: query, caret: caret, dialect: dialect, catalog: shop)
                #expect(result.replacement.location + result.replacement.length <= units.count)
            }
        }
    }

    @Test func hostileTextNeverTraps() {
        let pieces = ["(", ")", "'", "\"", "`", "[", "$$", "/*", "--", ";", ",", ".", "SELECT", "FROM", "WITH", "AS", "JOIN", "ON", "(SELECT", "x.", "::", "\u{0}", "😀", "é", " ", "\n"]
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int { seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return Int(seed >> 33) }
        for _ in 0..<400 {
            let text = (0..<(next() % 14 + 1)).map { _ in pieces[next() % pieces.count] }.joined()
            let length = text.utf16.count
            for dialect in SQLDialect.allCases {
                for caret in [0, length / 2, length] {
                    _ = SQLCompletionEngine.complete(text: text, caret: caret, dialect: dialect, catalog: shop)
                }
            }
        }
    }

    @Test func aBigCatalogCompletesFast() {
        let relations = (0..<10_000).map { SQLCatalog.Relation(name: "table_\($0)", columns: (0..<20).map { SQLCatalog.Column(name: "col_\($0)") }) }
        let big = SQLCatalog(relations: relations, isComplete: true)
        let text = "SELECT * FROM tab"
        var worst: Duration = .zero
        for _ in 0..<5 {
            let start = ContinuousClock.now
            let result = SQLCompletionEngine.complete(text: text, caret: text.utf16.count, dialect: .postgres, catalog: big)
            worst = max(worst, ContinuousClock.now - start)
            #expect(result.items.count == 10_000)
        }
        print("COMPLETE10K worst=\(worst)")
        #expect(worst < .milliseconds(1_000), Comment(rawValue: "took \(worst)"))
        let columns = "SELECT t.| FROM table_9999 t"
        let caret = (columns as NSString).range(of: "|").location
        let start = ContinuousClock.now
        let memberResult = SQLCompletionEngine.complete(text: columns.replacingOccurrences(of: "|", with: ""), caret: caret, dialect: .postgres, catalog: big)
        print("COMPLETEMEMBER10K elapsed=\(ContinuousClock.now - start)")
        #expect(memberResult.items.count == 20)
    }
}
