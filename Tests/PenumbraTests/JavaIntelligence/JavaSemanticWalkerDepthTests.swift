import XCTest
@testable import JavaIntelligence

final class JavaSemanticWalkerDepthTests: XCTestCase {
    /// `LocaleISOData`-style: hundreds of concatenated literals parse as one very deep expression.
    private func deepConcatenation(terms: Int) -> String {
        let chain = (0..<terms).map { "\"t\($0)\"" }.joined(separator: "\n        + ")
        return "class T {\n    static final String ALL = \(chain);\n}\n"
    }

    /// Runs on a thread with the 512 KB stack of a Swift task thread, where the recursion overflowed.
    private func runOnSmallStack<T: Sendable>(_ body: @escaping @Sendable () -> T) -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            box.value = body()
            done.signal()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        done.wait()
        return box.value!
    }

    func testAVeryDeepExpressionIsSkippedInsteadOfOverflowingTheStack() throws {
        let source = deepConcatenation(terms: 900)
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        let finished = runOnSmallStack { () -> Bool in
            let walker = JavaSemanticWalker(tree: tree, source: source)
            return walker.run()
        }
        XCTAssertFalse(finished)
    }

    func testTheInspectionPassStillBuildsAContextAndRunsItsRules() throws {
        let source = deepConcatenation(terms: 900)
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        let ids = runOnSmallStack { () -> [String] in
            guard let context = JavaInspectionContext(source: source, tree: tree, url: URL(fileURLWithPath: "/p/T.java"), index: JavaIndex()) else { return ["no context"] }
            return JavaInspectionRunner.run(context: context, enabled: Set(JavaInspectionRule.allCases)).map { $0.id }
        }
        XCTAssertEqual(ids, [])
    }

    func testOrdinaryNestingIsStillWalked() throws {
        let source = deepConcatenation(terms: 40)
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        XCTAssertTrue(JavaSemanticWalker(tree: tree, source: source).run())
    }
}

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}
