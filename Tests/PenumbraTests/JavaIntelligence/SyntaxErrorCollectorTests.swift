import LanguageSyntax
import XCTest
@testable import JavaIntelligence

/// The shared tree-sitter error walk, exercised on the Java grammar.
final class SyntaxErrorCollectorTests: XCTestCase {
    private func parse(_ source: String) -> JavaSyntaxTree {
        let tree = JavaSyntaxParser().parse(source)
        XCTAssertNotNil(tree)
        return tree!
    }

    private func utf8Offset(of needle: String, after prefix: String? = nil, in source: String) -> Int {
        let start = prefix.flatMap { source.range(of: $0)?.upperBound } ?? source.startIndex
        let found = source.range(of: needle, range: start..<source.endIndex)!
        return source.utf8.distance(from: source.startIndex, to: found.lowerBound)
    }

    func testMissingSemicolonReportedAtEndOfPreviousToken() {
        let source = "class Foo {\n    void m() {\n        int x = 1\n    }\n}\n"
        let problems = SyntaxErrorCollector.problems(in: parse(source))
        XCTAssertEqual(problems.count, 1)
        guard let problem = problems.first else { return }
        XCTAssertEqual(problem.kind, .missing(token: ";"))
        // Zero-width, at the end of `1`.
        let endOfOne = utf8Offset(of: "1", in: source) + 1
        XCTAssertEqual(problem.bytes, endOfOne..<endOfOne)
        XCTAssertEqual(problem.message(tokenName: SyntaxProblem.javacTokenName), "';' expected")
    }

    func testMissingCloseParen() {
        let source = "class Foo {\n    void m(int x {\n    }\n}\n"
        let problems = SyntaxErrorCollector.problems(in: parse(source))
        XCTAssertFalse(problems.isEmpty)
        let missing = problems.filter {
            if case .missing = $0.kind { return true }
            return false
        }
        XCTAssertFalse(missing.isEmpty, "expected a MISSING node, got \(problems)")
        for problem in missing {
            XCTAssertTrue(
                problem.message(tokenName: SyntaxProblem.javacTokenName).hasSuffix("expected"),
                "unexpected message: \(problem.message(tokenName: SyntaxProblem.javacTokenName))"
            )
        }
    }

    func testStrayTokenSquigglesOnlyThatToken() {
        let source = "class Foo {\n    void m() {\n        foo();\n        )\n    }\n}\n"
        let problems = SyntaxErrorCollector.problems(in: parse(source))
        XCTAssertEqual(problems.count, 1, "expected one ERROR report, got \(problems)")
        guard let problem = problems.first else { return }
        guard case .unexpected(let token) = problem.kind else {
            return XCTFail("expected .unexpected, got \(problem.kind)")
        }
        XCTAssertEqual(token, ")")
        // Only the stray token, not the rest of the file.
        let start = utf8Offset(of: ")", after: "foo();", in: source)
        XCTAssertEqual(problem.bytes, start..<start + 1)
    }

    func testUnclosedBraceAtEOF() {
        let problems = SyntaxErrorCollector.problems(in: parse("class Foo {\n    void m() {\n"))
        XCTAssertFalse(problems.isEmpty)
    }

    func testCleanFileYieldsNothing() {
        let source = "class Foo {\n    void m() {\n        int x = 1;\n    }\n}\n"
        let tree = parse(source)
        XCTAssertFalse(tree.rootNode.hasError)
        XCTAssertEqual(SyntaxErrorCollector.problems(in: tree), [])
    }

    func testLimitCapsProblems() {
        var source = "class Foo {\n    void m() {\n"
        for index in 0..<150 {
            source += "        int v\(index) = \(index)\n"
        }
        source += "    }\n}\n"
        let tree = parse(source)
        let capped = SyntaxErrorCollector.problems(in: tree, limit: 5)
        XCTAssertEqual(capped.count, 5)
        let all = SyntaxErrorCollector.problems(in: tree)
        XCTAssertGreaterThan(all.count, 5)
        XCTAssertTrue(all.allSatisfy { $0.expected.count <= 3 })
    }

    func testExpectedTokenMessagesAndFallback() {
        XCTAssertEqual(
            SyntaxProblem(bytes: 0..<0, kind: .missing(token: ";")).message(),
            "';' expected"
        )
        XCTAssertEqual(
            SyntaxProblem(bytes: 0..<0, kind: .missing(token: "identifier")).message(),
            "<identifier> expected"
        )
        XCTAssertEqual(
            SyntaxProblem(bytes: 0..<0, kind: .unexpected(token: "foo"), expected: [";", ")"])
                .message(),
            "';' or ')' expected"
        )
        // A long lookahead set becomes [], and the message falls back.
        XCTAssertEqual(
            SyntaxProblem(bytes: 0..<1, kind: .unexpected(token: "foo")).message(),
            "Unexpected 'foo'"
        )
        // javac spells every identifier-shaped symbol `<identifier>`.
        XCTAssertEqual(SyntaxProblem.javacTokenName("type_identifier"), "<identifier>")
        XCTAssertEqual(
            SyntaxProblem(bytes: 0..<0, kind: .missing(token: "type_identifier"))
                .message(tokenName: SyntaxProblem.javacTokenName),
            "<identifier> expected"
        )
    }

    func testDeepNestingDoesNotOverflow() {
        let depth = 5_000
        let source = "class Foo {\n    int x = \(String(repeating: "(", count: depth))1\(String(repeating: ")", count: depth));\n}\n"
        let problems = SyntaxErrorCollector.problems(in: parse(source))
        XCTAssertEqual(problems, [])

        let broken = "class Foo {\n    int x = \(String(repeating: "(", count: depth))1;\n}\n"
        let brokenProblems = SyntaxErrorCollector.problems(in: parse(broken))
        XCTAssertFalse(brokenProblems.isEmpty)
    }
}
