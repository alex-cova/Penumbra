import Foundation
import Testing

@testable import SQLIntelligence

private let catalog = SQLCatalog(
    relations: [
        .init(name: "customers", columns: [
            .init(name: "id", typeName: "integer", isNotNull: true, isPrimaryKey: true), .init(name: "name", typeName: "text"), .init(name: "email", typeName: "text", isNotNull: true),
        ]),
        .init(name: "orders", columns: [.init(name: "id", typeName: "integer", isPrimaryKey: true), .init(name: "customer_id", typeName: "integer"), .init(name: "total", typeName: "numeric")]),
        .init(name: "Order Details", columns: [.init(name: "qty")]),
    ],
    isComplete: true
)

private func at(_ marked: String) -> (String, Int) {
    (marked.replacingOccurrences(of: "|", with: ""), (marked as NSString).range(of: "|").location)
}

private func hover(_ marked: String, _ dialect: SQLDialect = .postgres) -> String? {
    let (text, caret) = at(marked)
    return SQLAssist.hover(text: text, caret: caret, dialect: dialect, catalog: catalog)?.markdown
}

struct SQLHoverTests {
    @Test func columnsShowTheirTypeAndKeys() {
        #expect(hover("SELECT c.em|ail FROM customers c") == "**customers.email**\n\ntext, not null")
        #expect(hover("SELECT c.i|d FROM customers c") == "**customers.id**\n\ninteger, primary key, not null")
        #expect(hover("SELECT em|ail FROM customers") == "**customers.email**\n\ntext, not null", "an unqualified column resolves through the FROM")
    }

    @Test func tablesListTheirColumns() {
        let text = hover("SELECT * FROM cust|omers c")
        #expect(text?.hasPrefix("**customers** (table, 3 columns)") == true)
        #expect(text?.contains("- `email` text") == true)
        #expect(text?.contains("primary key") == true)
        #expect(hover("SELECT * FROM nowhe|re")?.contains("No table or view with this name") == true)
        var incomplete = catalog
        incomplete.isComplete = false
        let (text2, caret2) = at("SELECT * FROM nowhe|re")
        #expect(SQLAssist.hover(text: text2, caret: caret2, dialect: .postgres, catalog: incomplete) == nil, "not loaded is not unknown")
    }

    @Test func aliasesCtesAndAmbiguity() {
        #expect(hover("SELECT c|.name FROM customers c") == "**c** is an alias of `customers`")
        #expect(hover("SELECT * FROM customers c|") == "**c** is an alias of `customers`")
        #expect(hover("WITH w AS (SELECT 1 AS x) SELECT * FROM w|") == "**w**\n\ncommon table expression")
        #expect(hover("SELECT i|d FROM customers c, orders o")?.hasPrefix("**id** is ambiguous") == true)
        #expect(hover("SELECT i|d FROM customers c, orders o")?.contains("`c.id`") == true)
        #expect(hover("SELECT x.zz|z FROM customers x") == nil)
    }

    @Test func functionsShowSignatureAndSummary() {
        #expect(hover("SELECT cou|nt(*) FROM customers") == "**count(expression | *)**\n\nNumber of rows, or of non-null values.")
        #expect(hover("SELECT date_tr|unc('day', now())", .postgres)?.hasPrefix("**date_trunc(field, source)**") == true)
        #expect(hover("SELECT date_tr|unc('day', now())", .mysql) == nil, "a function the dialect does not have is not documented")
        #expect(hover("SELECT 1 + |") == nil)
    }
}

struct SQLDeclarationTests {
    private func declaration(_ marked: String) -> SQLDeclaration? {
        let (text, caret) = at(marked)
        return SQLAssist.declaration(text: text, caret: caret, dialect: .postgres, catalog: catalog)
    }

    @Test func tablesAndColumnsLeadToTheCatalog() {
        #expect(declaration("SELECT * FROM cust|omers") == .relation("customers"))
        #expect(declaration("SELECT c.em|ail FROM customers c") == .column(relation: "customers", name: "email"))
        #expect(declaration("SELECT na|me FROM customers") == .column(relation: "customers", name: "name"))
        #expect(declaration("SELECT * FROM \"Order De|tails\"") == .relation("Order Details"))
    }

    @Test func aliasesAndCtesLeadToWhereTheyAreWritten() {
        let sql = "SELECT c.name FROM customers c"
        let (text, caret) = at("SELECT c|.name FROM customers c")
        let found = SQLAssist.declaration(text: text, caret: caret, dialect: .postgres, catalog: catalog)
        #expect(found == .local(NSRange(location: (sql as NSString).range(of: " c", options: .backwards).location + 1, length: 1)))

        let cte = "WITH w AS (SELECT 1 AS x) SELECT * FROM w"
        let (text2, caret2) = at("WITH w AS (SELECT 1 AS x) SELECT * FROM w|")
        #expect(SQLAssist.declaration(text: text2, caret: caret2, dialect: .postgres, catalog: catalog) == .local(NSRange(location: 5, length: 1)))
        #expect(text2 == cte)
    }

    @Test func unknownNamesLeadNowhere() {
        #expect(declaration("SELECT * FROM nowh|ere") == nil)
        #expect(declaration("SELECT zz|z FROM customers") == nil)
    }
}

struct SQLSignatureHelpTests {
    private func help(_ marked: String, _ dialect: SQLDialect = .postgres) -> SQLSignatureHelp? {
        let (text, caret) = at(marked)
        return SQLAssist.signatureHelp(text: text, caret: caret, dialect: dialect)
    }

    @Test func theActiveParameterFollowsTheCommas() {
        #expect(help("SELECT replace(|")?.activeParameter == 0)
        #expect(help("SELECT replace(a, |")?.activeParameter == 1)
        #expect(help("SELECT replace(a, 'x', |)")?.activeParameter == 2)
        #expect(help("SELECT replace(a, lower(b, c), |)")?.activeParameter == 2, "commas inside a nested call are not ours")
        #expect(help("SELECT replace(a, lower(|b, c), 'z')")?.function == "lower", "the innermost call")
        #expect(help("SELECT replace(a, 'x', 'y')|") == nil, "after the closing parenthesis it is over")
        #expect(help("SELECT (1 + |2)") == nil, "a plain parenthesis is not a call")
        #expect(help("SELECT strftime(|", .sqlite)?.signature == "strftime(format, time, modifier, …)")
        #expect(help("SELECT strftime(|", .postgres) == nil)
    }
}

struct SQLCodeActionTests {
    private func expand(_ marked: String, _ dialect: SQLDialect = .postgres) -> SQLTextEdit? {
        let (text, caret) = at(marked)
        return SQLAssist.expandStar(text: text, caret: caret, dialect: dialect, catalog: catalog)
    }

    private func apply(_ edit: SQLTextEdit, to marked: String) -> String {
        (marked.replacingOccurrences(of: "|", with: "") as NSString).replacingCharacters(in: edit.range, with: edit.newText)
    }

    @Test func starBecomesTheColumnsItStandsFor() {
        let marked = "SELECT *| FROM customers"
        let edit = expand(marked)
        #expect(edit?.title == "Expand * into 3 columns")
        #expect(edit.map { apply($0, to: marked) } == "SELECT id, name, email FROM customers")
    }

    @Test func severalSourcesGetQualifiedNames() {
        let marked = "SELECT *| FROM customers c JOIN orders o ON o.customer_id = c.id"
        #expect(expand(marked).map { apply($0, to: marked) } == "SELECT c.id, c.name, c.email, o.id, o.customer_id, o.total FROM customers c JOIN orders o ON o.customer_id = c.id")
    }

    @Test func aliasStarExpandsOnlyThatSource() {
        let marked = "SELECT c.*| FROM customers c JOIN orders o ON o.customer_id = c.id"
        #expect(expand(marked).map { apply($0, to: marked) } == "SELECT c.id, c.name, c.email FROM customers c JOIN orders o ON o.customer_id = c.id")
        let more = "SELECT o.total, c.*| FROM customers c JOIN orders o ON o.customer_id = c.id"
        #expect(expand(more).map { apply($0, to: more) }?.hasPrefix("SELECT o.total, c.id, c.name, c.email FROM") == true)
    }

    @Test func namesThatNeedQuotingAreQuoted() {
        let marked = "SELECT *| FROM \"Order Details\""
        #expect(expand(marked).map { apply($0, to: marked) } == "SELECT qty FROM \"Order Details\"")
    }

    @Test func notWhereItWouldBeWrong() {
        #expect(expand("SELECT count(*|) FROM customers") == nil, "count(*) is not a select item")
        #expect(expand("SELECT 2 *| 3 FROM customers") == nil, "multiplication is not a star")
        #expect(expand("SELECT *| FROM unknown_table") == nil, "unknown columns cannot be listed")
        var partial = catalog
        partial.relations[0].columns = nil
        let (text, caret) = at("SELECT *| FROM customers")
        #expect(SQLAssist.expandStar(text: text, caret: caret, dialect: .postgres, catalog: partial) == nil, "columns not loaded yet")
    }
}
