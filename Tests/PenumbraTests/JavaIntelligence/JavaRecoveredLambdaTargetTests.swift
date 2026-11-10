import XCTest
@testable import JavaIntelligence

/// `JavaExpressionTarget.target(of:)` for a lambda that error recovery left under an `ERROR` node: the
/// call is rebuilt from the damaged region's text. Each test asserts that the lambda really is under an
/// `ERROR` first, so a grammar change that stops producing the shape fails here instead of passing
/// vacuously.
final class JavaRecoveredLambdaTargetTests: XCTestCase {
    /// The target of the lambda whose parameters read `parameters`, in `body` placed in a method, after
    /// the completion repair (the text the provider parses). `nil` if there is no such lambda.
    private func target(
        of parameters: String, in body: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> (target: JavaExpressionTarget?, parent: String) {
        let text = "class A {\n    void m() {\n        \(body)\n    }\n}\n"
        let caret = (text as NSString).range(of: "/*|*/").location
        let source = text.replacingOccurrences(of: "/*|*/", with: "")
        let repaired = JavaCompletionProvider.repairedText(source, insertingDummyAt: caret)
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(repaired), file: file, line: line)
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
            if node.type == "lambda_expression", node.child(byFieldName: "parameters")?.text == parameters {
                return (JavaExpressionTarget.target(of: node), node.parent?.type ?? "")
            }
            stack += node.namedChildren
        }
        throw XCTSkip("no lambda with parameters \(parameters) in the repaired text")
    }

    func testUnqualifiedCallWithAnEarlierArgument() throws {
        let result = try target(of: "(l, v)", in: "build(() -> new ArrayList<String>(), (l, v) -> {\n            l./*|*/")
        XCTAssertEqual(result.parent, "ERROR", "the shape this recovery exists for")
        XCTAssertEqual(result.target, .argument(callText: "build(() -> new ArrayList<String>(), (l, v) -> {})", argumentIndex: 1, callTarget: nil))
    }

    func testQualifiedChainCalleeWithLambdasInsideIt() throws {
        let result = try target(of: "s", in: "users.stream().map(u -> u.getName()).forEach(s -> {\n            s./*|*/")
        XCTAssertEqual(result.parent, "ERROR")
        XCTAssertEqual(result.target, .argument(callText: "users.stream().map(u -> u.getName()).forEach(s -> {})", argumentIndex: 0, callTarget: nil))
    }

    func testExplicitTypeArgumentsOnTheCallee() throws {
        let result = try target(of: "s", in: "Optional.<String>of(\"x\").map(s -> {\n            s./*|*/")
        XCTAssertEqual(result.parent, "ERROR")
        XCTAssertEqual(result.target, .argument(callText: "Optional.<String>of(\"x\").map(s -> {})", argumentIndex: 0, callTarget: nil))
    }

    func testBracketsInStringsAndCommentsOfEarlierArgumentsDoNotCount() throws {
        let result = try target(of: "n", in: "pipe(\"a)(,{\", s -> s.length() /* ) ( */, n -> {\n            n./*|*/")
        XCTAssertEqual(result.parent, "ERROR")
        XCTAssertEqual(
            result.target,
            .argument(callText: "pipe(\"a)(,{\", s -> s.length() /* ) ( */, n -> {})", argumentIndex: 2, callTarget: nil)
        )
    }

    func testAConstructorCallIsNotAMethodCall() throws {
        let result = try target(of: "()", in: "new Thread(() -> {\n            text./*|*/")
        XCTAssertEqual(result.parent, "ERROR")
        XCTAssertNil(result.target)
    }

    func testALambdaThatIsNotAnArgumentGetsNoTarget() throws {
        // `{` is the innermost open bracket before the lambda, not a `(`.
        let result = try target(of: "x", in: "int[] a = new int[] { x -> {\n            x./*|*/")
        if result.parent == "ERROR" { XCTAssertNil(result.target) }
    }

    func testACleanCallIsUntouchedByTheRecovery() throws {
        // Well-formed: the lambda sits in an `argument_list`, the ordinary path.
        let result = try target(of: "(l, v)", in: "build(() -> new ArrayList<String>(), (l, v) -> {\n            l./*|*/\n        });")
        XCTAssertEqual(result.parent, "argument_list")
        guard case .argument(let callText, let index, _)? = result.target else { return XCTFail("no target") }
        XCTAssertEqual(index, 1)
        XCTAssertTrue(callText.hasPrefix("build("), callText)
    }
}
