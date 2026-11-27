import Foundation
import Testing

@testable import SQLIntelligence

private func texts(_ script: String, _ dialect: SQLDialect) -> [String] {
    SQLStatementSplitter.split(script, dialect: dialect).map(\.text)
}

struct SQLLexerTests {
    private func kinds(_ text: String, _ dialect: SQLDialect = .postgres) -> [SQLToken.Kind] {
        SQLLexer(text, dialect: dialect).tokenize().map(\.kind)
    }

    private func tokenTexts(_ text: String, _ dialect: SQLDialect = .postgres) -> [String] {
        let lexer = SQLLexer(text, dialect: dialect)
        return lexer.tokenize().map { $0.text(in: lexer.units) }
    }

    @Test func wordsNumbersOperatorsAndParameters() {
        #expect(tokenTexts("SELECT a.b, 1.5e3 FROM t WHERE x >= $1 AND y <> :name AND z = ?") ==
            ["SELECT", "a", ".", "b", ",", "1.5e3", "FROM", "t", "WHERE", "x", ">=", "$1", "AND", "y", "<>", ":name", "AND", "z", "=", "?"])
        #expect(tokenTexts("a::int || b ->> 'k'") == ["a", "::", "int", "||", "b", "->>", "'k'"])
        #expect(kinds("$1 ?2 :p @v") == [.parameter, .parameter, .parameter, .parameter])
    }

    @Test func stringsAndIdentifiersFollowTheDialect() {
        #expect(tokenTexts("'it''s'") == ["'it''s'"])
        #expect(kinds("\"My Col\"") == [.quotedIdentifier])
        #expect(kinds("\"text\"", .mysql) == [.string], "a double-quoted token is a string in MySQL")
        #expect(kinds("`My Col`", .mysql) == [.quotedIdentifier])
        #expect(kinds("[My Col]", .sqlite) == [.quotedIdentifier])
        #expect(tokenTexts("a[1]", .postgres) == ["a", "[", "1", "]"], "brackets are array syntax in PostgreSQL")
        // Backslash escapes: MySQL always, PostgreSQL only in E'..', SQLite never.
        #expect(tokenTexts("'a\\'b' x", .mysql) == ["'a\\'b'", "x"])
        #expect(tokenTexts("E'a\\'b' x", .postgres) == ["E'a\\'b'", "x"])
        #expect(tokenTexts("'a\\' x", .postgres) == ["'a\\'", "x"], "no escape in a plain PostgreSQL string")
        #expect(tokenTexts("'a\\' x", .sqlite) == ["'a\\'", "x"])
        #expect(tokenTexts("N'x' X'ff'", .mysql) == ["N'x'", "X'ff'"])
    }

    @Test func commentsFollowTheDialect() {
        #expect(kinds("a -- c\nb") == [.word, .comment, .word])
        #expect(kinds("a # c\nb", .mysql) == [.word, .comment, .word])
        #expect(kinds("a # c", .postgres) == [.word, .symbol, .word], "# is an operator in PostgreSQL")
        #expect(tokenTexts("/* a /* b */ c */ x", .postgres) == ["/* a /* b */ c */", "x"], "PostgreSQL nests block comments")
        #expect(tokenTexts("/* a /* b */ c */ x", .mysql) == ["/* a /* b */", "c", "*", "/", "x"], "MySQL does not")
    }

    @Test func dollarQuotesBelongToPostgres() {
        #expect(kinds("$$ a; b $$") == [.string])
        #expect(tokenTexts("$fn$ x $$ y $fn$ z") == ["$fn$ x $$ y $fn$", "z"])
        #expect(kinds("$1") == [.parameter])
        #expect(kinds("select $$x$$ ") == [.word, .string])
    }

    @Test func unfinishedTextNeverFailsAndSaysSo() {
        let open = SQLLexer("SELECT 'abc", dialect: .postgres).tokenize()
        #expect(open.last?.kind == .string)
        #expect(open.last?.isTerminated == false)
        #expect(SQLLexer("/* never closed", dialect: .postgres).tokenize().first?.isTerminated == false)
        #expect(SQLLexer("\"half", dialect: .postgres).tokenize().first?.isTerminated == false)
        #expect(SQLLexer("$$ never", dialect: .postgres).tokenize().first?.isTerminated == false)
        #expect(SQLLexer("", dialect: .mysql).tokenize().isEmpty)
        // Stray and non-ASCII characters are tokens, not failures.
        #expect(!SQLLexer("SELECT € ¥ ☃ \u{0} ~ ^", dialect: .sqlite).tokenize().isEmpty)
    }

    @Test func offsetsAreUTF16SoTheyMatchTheEditor() {
        let text = "SELECT 'héllo😀' AS x"
        let lexer = SQLLexer(text, dialect: .postgres)
        let tokens = lexer.tokenize()
        let ns = text as NSString
        #expect(ns.substring(with: tokens[1].range) == "'héllo😀'")
        #expect(ns.substring(with: tokens[3].range) == "x")
    }

    @Test func aDelimiterDirectiveChangesTheTerminator() {
        let lexer = SQLLexer("DELIMITER //\nSELECT 1; SELECT 2//\ndelimiter ;\nSELECT 3;", dialect: .mysql)
        let tokens = lexer.tokenize()
        #expect(tokens.filter { $0.kind == .directive }.count == 2)
        #expect(tokens.filter { $0.kind == .delimiter }.map { $0.text(in: lexer.units) } == ["//", ";"])
        // `DELIMITER` is a MySQL client directive only.
        #expect(!SQLLexer("DELIMITER //\nx", dialect: .postgres).tokenize().contains { $0.kind == .directive })
    }
}

struct SQLStatementSplitterTests {
    @Test func plainScriptsSplitOnSemicolons() {
        #expect(texts("SELECT 1; SELECT 2;\nSELECT 3", .postgres) == ["SELECT 1", "SELECT 2", "SELECT 3"])
        #expect(texts("", .sqlite).isEmpty)
        #expect(texts(";;; ;", .sqlite).isEmpty, "empty statements are nothing")
        let adjacent = SQLStatementSplitter.split("SELECT 1;SELECT 2", dialect: .sqlite)
        #expect(SQLStatementSplitter.statement(containing: 9, in: adjacent)?.text == "SELECT 2")
    }

    @Test func parametersAreRewrittenOnlyOutsideLiteralsAndComments() {
        let postgres = SQLParameterPlan("SELECT $2, :value, $2, body ? 'key', ':value', $$ $3 $$", dialect: .postgres)
        #expect(postgres.sql == "SELECT $1, $2, $1, body ? 'key', ':value', $$ $3 $$")
        #expect(postgres.labels == ["$2", ":value"])
        #expect(postgres.bindingOrder == [0, 1])
        let sqlite = SQLParameterPlan("SELECT :value, ?, :value, $1, '?', \"?1\" /* :ignored */", dialect: .sqlite)
        #expect(sqlite.sql == "SELECT ?, ?, ?, ?, '?', \"?1\" /* :ignored */")
        #expect(sqlite.bindingOrder == [0, 1, 0, 2])
        let mysql = SQLParameterPlan("SELECT @@sql_mode, @variable, :value, ?, :value", dialect: .mysql)
        #expect(mysql.sql == "SELECT @@sql_mode, @variable, ?, ?, ?")
        #expect(mysql.bindingOrder == [0, 1, 0])
    }

    @Test func errorWithinRewrittenParameterCoversOriginalPlaceholder() {
        let original = "SELECT 'e\u{301}😀', :long_name, :long_name"
        let plan = SQLParameterPlan(original, dialect: .postgres)
        let first = "SELECT 'e\u{301}😀', ".unicodeScalars.count + 1
        let second = "SELECT 'e\u{301}😀', $1, ".unicodeScalars.count + 1
        #expect(plan.sourceRange(at: first + 1) == (original as NSString).range(of: ":long_name"))
        #expect(plan.sourceRange(at: second) == (original as NSString).range(of: ":long_name", options: .backwards))
        #expect(plan.sourceRange(at: plan.sql.unicodeScalars.count + 1) ==
                NSRange(location: original.utf16.count, length: 0))
        #expect(plan.sourceRange(at: 0) == nil)
        #expect(plan.sourceRange(at: Int.max) == nil)
    }

    @Test func formatterLaysOutQueriesWithoutChangingTokens() {
        let text = "select 'FROM; WHERE' as value from items where id = :id; select 2 -- comment"
        let output = NSMutableString(string: text)
        for edit in SQLFormatter.edits(in: text, dialect: .sqlite).reversed() {
            output.replaceCharacters(in: edit.range, with: edit.newText)
        }
        let formatted = output as String
        #expect(formatted == "select 'FROM; WHERE' as value\nfrom items\nwhere id = :id;\nselect 2 -- comment")
        #expect(SQLFormatter.edits(in: formatted, dialect: .sqlite).isEmpty)

        let pg = "SELECT $$FROM t; WHERE$$, 'unterminated"
        #expect(SQLFormatter.edits(in: pg, dialect: .postgres).isEmpty)
    }

    @Test func semicolonsInsideStringsCommentsAndQuotedNamesDoNotSplit() {
        #expect(texts("SELECT 'a;b'; SELECT \"c;d\" FROM t", .postgres) == ["SELECT 'a;b'", "SELECT \"c;d\" FROM t"])
        #expect(texts("SELECT 1 -- ; not here\n; SELECT 2 /* ; */", .postgres) == ["SELECT 1", "SELECT 2"])
        #expect(texts("SELECT `a;b` FROM t; SELECT 2", .mysql) == ["SELECT `a;b` FROM t", "SELECT 2"])
        #expect(texts("SELECT 'it''s; fine'; SELECT 2", .sqlite) == ["SELECT 'it''s; fine'", "SELECT 2"])
        #expect(texts("SELECT 'a\\'; b'; SELECT 2", .mysql) == ["SELECT 'a\\'; b'", "SELECT 2"])
    }

    @Test func postgresDollarQuotedBodiesAreOneStatement() {
        let script = """
        CREATE FUNCTION f() RETURNS int AS $$
        BEGIN
          PERFORM 1; RETURN 2;
        END;
        $$ LANGUAGE plpgsql;
        SELECT f();
        DO $body$ BEGIN RAISE NOTICE 'x;y'; END $body$;
        """
        let result = texts(script, .postgres)
        #expect(result.count == 3)
        #expect(result[0].hasSuffix("LANGUAGE plpgsql"))
        #expect(result[1] == "SELECT f()")
        #expect(result[2].hasPrefix("DO $body$"))
    }

    @Test func postgresBeginAtomicAndTransactionBegin() {
        let script = "BEGIN; INSERT INTO t VALUES (1); COMMIT;\nCREATE FUNCTION g() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1; SELECT 2; END;\nSELECT 3"
        let result = texts(script, .postgres)
        #expect(result == ["BEGIN", "INSERT INTO t VALUES (1)", "COMMIT",
                           "CREATE FUNCTION g() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1; SELECT 2; END", "SELECT 3"],
            "a transaction BEGIN is its own statement; BEGIN ATOMIC opens a body")
    }

    @Test func sqliteTriggersKeepTheirBodies() {
        let script = """
        CREATE TABLE t (a, b);
        CREATE TRIGGER t_ai AFTER INSERT ON t
        BEGIN
          UPDATE t SET b = 1 WHERE a = new.a;
          INSERT INTO log VALUES (new.a);
        END;
        INSERT INTO t VALUES (1, 2);
        """
        let result = texts(script, .sqlite)
        #expect(result.count == 3)
        #expect(result[1].hasPrefix("CREATE TRIGGER") && result[1].hasSuffix("END"))
        #expect(result[1].contains("INSERT INTO log"))
        #expect(result[2] == "INSERT INTO t VALUES (1, 2)")
    }

    @Test func caseExpressionsAreNotBlocks() {
        #expect(texts("SELECT CASE WHEN a THEN 1 ELSE 2 END FROM t; SELECT 2", .sqlite)
            == ["SELECT CASE WHEN a THEN 1 ELSE 2 END FROM t", "SELECT 2"])
        #expect(texts("SELECT CASE WHEN a THEN CASE WHEN b THEN 1 END END; SELECT 2", .mysql).count == 2)
    }

    @Test func mysqlDelimiterScriptsAndInlineProcedures() {
        let script = """
        DELIMITER //
        CREATE PROCEDURE p()
        BEGIN
          SELECT 1;
          IF x THEN SELECT 2; END IF;
        END//
        DELIMITER ;
        SELECT 3;
        """
        let result = texts(script, .mysql)
        #expect(result.count == 2)
        #expect(result[0].hasPrefix("CREATE PROCEDURE p()") && result[0].hasSuffix("END"))
        #expect(result[0].contains("END IF;"))
        #expect(result[1] == "SELECT 3")
        // Without DELIMITER, BEGIN/END, IF/END IF and loops still hold the body together.
        let inline = "CREATE PROCEDURE q() BEGIN DECLARE i INT; WHILE i < 3 DO SET i = i + 1; END WHILE; IF i = 3 THEN SELECT 1; END IF; END; SELECT 9"
        #expect(texts(inline, .mysql).count == 2)
        // IF( is a function, not a block.
        #expect(texts("SELECT IF(a, 1, 2); SELECT 2", .mysql) == ["SELECT IF(a, 1, 2)", "SELECT 2"])
    }

    @Test func rangesLinesAndTheTerminator() {
        let script = "-- first\nSELECT 1;\n\n  SELECT\n    2\n;"
        let statements = SQLStatementSplitter.split(script, dialect: .sqlite)
        #expect(statements.count == 2)
        let ns = script as NSString
        #expect(ns.substring(with: statements[0].range) == "SELECT 1")
        #expect(statements[0].startLine == 2 && statements[0].endLine == 2)
        #expect(statements[1].startLine == 4 && statements[1].endLine == 5)
        #expect(statements[0].isTerminated && statements[1].isTerminated)
        #expect(ns.substring(to: statements[0].extendedEnd).hasSuffix(";"))
        #expect(!SQLStatementSplitter.split("SELECT 1", dialect: .sqlite)[0].isTerminated)
        #expect(SQLStatementSplitter.split("-- only a comment\n/* and another */", dialect: .sqlite).isEmpty)
    }

    @Test func theCaretPicksTheRightStatement() {
        let script = "SELECT 1;\n\nSELECT 2;\nSELECT 3"
        let statements = SQLStatementSplitter.split(script, dialect: .sqlite)
        func pick(_ marker: String, after: String = "") -> String? {
            let offset = (script as NSString).range(of: marker).location + after.utf16.count
            return SQLStatementSplitter.statement(containing: offset, in: statements)?.text
        }
        #expect(pick("SELECT 2", after: "SELE") == "SELECT 2")
        #expect(pick("SELECT 2;", after: "SELECT 2;") == "SELECT 2", "a caret just after the terminator is still in it")
        #expect(SQLStatementSplitter.statement(containing: 10, in: statements)?.text == "SELECT 1", "in the blank gap, the statement above")
        #expect(SQLStatementSplitter.statement(containing: 0, in: statements)?.text == "SELECT 1")
        #expect(SQLStatementSplitter.statement(containing: script.utf16.count, in: statements)?.text == "SELECT 3")
        #expect(SQLStatementSplitter.statement(atLine: 3, in: statements)?.text == "SELECT 2")
        #expect(SQLStatementSplitter.statement(atLine: 2, in: statements) == nil, "a blank line is no statement")
        #expect(SQLStatementSplitter.statement(containing: 3, in: []) == nil)
    }

    @Test func incompleteAndHostileTextNeverTrapsAndNeverLosesText() {
        for text in ["SELECT 'abc", "SELECT /* x", "CREATE TRIGGER t BEGIN SELECT 1;", "$$ x", "SELECT (1;", "\"", "SELECT 1 END END END; SELECT 2"] {
            for dialect in SQLDialect.allCases {
                let statements = SQLStatementSplitter.split(text, dialect: dialect)
                for statement in statements {
                    #expect(statement.start >= 0 && statement.end <= text.utf16.count && statement.start <= statement.end)
                }
            }
        }
        // An unterminated body swallows the rest rather than cutting it into wrong pieces.
        #expect(texts("CREATE TRIGGER t AFTER INSERT ON x BEGIN SELECT 1; SELECT 2;", .sqlite).count == 1)
        // A stray END does not cause a negative depth.
        #expect(texts("SELECT 1 END; SELECT 2", .sqlite).count == 2)
    }

    @Test func aLongScriptSplitsInLinearTime() {
        let script = (0..<20_000).map { "INSERT INTO t VALUES (\($0), 'v;\($0)');" }.joined(separator: "\n")
        let start = ContinuousClock.now
        let statements = SQLStatementSplitter.split(script, dialect: .postgres)
        let elapsed = ContinuousClock.now - start
        #expect(statements.count == 20_000)
        #expect(statements.last?.startLine == 20_000)
        print("SPLIT20K elapsed=\(elapsed)")
        #expect(elapsed < .seconds(5), "took \(elapsed)")
    }
}
