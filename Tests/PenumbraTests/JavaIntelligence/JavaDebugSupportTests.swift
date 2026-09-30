import Foundation
import XCTest
@testable import JavaIntelligence

final class JavaDebugSupportTests: XCTestCase {
    // MARK: - Call sites

    func testCallsOnALineComeInTheOrderTheyRun() {
        let source = """
        class A {
            void run() {
                int r = b(a(), new Point(1, 2).x);
                list.forEach(x -> log(x));
            }
        }
        """
        XCTAssertEqual(JavaCallSites.calls(onLine: 3, in: source).map(\.methodName), ["a", "<init>", "b"])
        XCTAssertEqual(JavaCallSites.calls(onLine: 3, in: source).map(\.displayText), ["a()", "new Point(1, 2)", "b(a(), new Point(1, 2).x)"])
        // A lambda's body runs later: only forEach itself.
        XCTAssertEqual(JavaCallSites.calls(onLine: 4, in: source).map(\.methodName), ["forEach"])
        XCTAssertEqual(JavaCallSites.calls(onLine: 1, in: source), [])
    }

    // MARK: - Expression syntax

    func testExpressionSyntax() {
        XCTAssertNil(JavaExpressionSyntax.problem(in: "i == 3 && name.startsWith(\"a\")"))
        XCTAssertNil(JavaExpressionSyntax.problem(in: "list.stream().anyMatch(x -> x > 2)"))
        XCTAssertNil(JavaExpressionSyntax.problem(in: ""))
        XCTAssertNotNil(JavaExpressionSyntax.problem(in: "i == "))
        XCTAssertNotNil(JavaExpressionSyntax.problem(in: "if (x) {}"))
    }

    // MARK: - Stream chains

    private let streams = """
    import java.util.*;
    import java.util.stream.*;

    class S {
        void run(List<Integer> list) {
            List<Integer> out = list.stream().filter(x -> x > 1).map(x -> x * 2).sorted().toList();
            long n = IntStream.range(0, 5)
                .boxed()
                .count();
            list.forEach(System.out::println);
            String s = list.toString();
        }
    }
    """

    func testFindsAChainWithItsStages() throws {
        let chain = try XCTUnwrap(JavaStreamChain.chains(onLine: 6, in: streams).first)
        XCTAssertEqual(chain.source, "list.stream()")
        XCTAssertEqual(chain.sourceName, "stream()")
        XCTAssertEqual(chain.intermediates.map(\.name), ["filter", "map", "sorted"])
        XCTAssertEqual(chain.intermediates.map(\.text), [".filter(x -> x > 1)", ".map(x -> x * 2)", ".sorted()"])
        XCTAssertEqual(chain.terminal.name, "toList")
        XCTAssertEqual(chain.stageNames, ["stream()", "filter", "map", "sorted"])
    }

    func testFindsAChainSpanningLinesFromAnyOfThem() throws {
        for line in 7...9 {
            let chain = try XCTUnwrap(JavaStreamChain.chains(onLine: line, in: streams).first, "line \(line)")
            XCTAssertEqual(chain.sourceName, "IntStream.range(…)")
            XCTAssertEqual(chain.intermediates.map(\.name), ["boxed"])
            XCTAssertEqual(chain.terminal.name, "count")
            XCTAssertEqual(chain.lines, 7...9)
        }
    }

    func testIgnoresCallsThatAreNotStreams() {
        XCTAssertTrue(JavaStreamChain.chains(onLine: 10, in: streams).isEmpty, "Iterable.forEach is not a stream")
        XCTAssertTrue(JavaStreamChain.chains(onLine: 11, in: streams).isEmpty)
    }

    func testTracedExpressionPeeksAfterEveryStage() throws {
        let chain = try XCTUnwrap(JavaStreamChain.chains(onLine: 6, in: streams).first)
        let traced = chain.tracedExpression()
        XCTAssertEqual(traced.components(separatedBy: ".peek(").count - 1, 4)
        XCTAssertTrue(traced.contains("list.stream().peek("))
        XCTAssertTrue(traced.contains(".sorted().peek(__umbraValue -> __umbraStage3.add("))
        XCTAssertTrue(traced.hasSuffix(".get()"))
        XCTAssertNil(JavaExpressionSyntax.problem(in: traced), "the rewrite is valid Java")
    }

    func testLinksByTimeAndByIdentityForSorted() throws {
        let chain = try XCTUnwrap(JavaStreamChain.chains(onLine: 6, in: streams).first)
        func element(_ time: Int64, _ identity: String) -> JavaStreamTraceElement {
            JavaStreamTraceElement(time: time, value: identity, identity: identity)
        }
        // filter: 3 then 1 then 2 go in; 3 and 2 come out right after them.
        let source = [element(1, "#3"), element(3, "#1"), element(4, "#2")]
        let filtered = [element(2, "#3"), element(5, "#2")]
        XCTAssertEqual(chain.links(from: source, to: filtered, operation: "filter"), [0, 2])
        // sorted sees everything first, then emits in order: link by identity.
        let mapped = [element(6, "#6"), element(8, "#4")]
        let sorted = [element(9, "#4"), element(10, "#6")]
        XCTAssertEqual(chain.links(from: mapped, to: sorted, operation: "sorted"), [1, 0])
    }

    // MARK: - Test runner

    func testDebugRunsCleanTheTaskAndWaitForADebugger() {
        let request = JavaTestRunRequest(gradleTaskPath: ":app:test", testFilter: "a.BTest", projectRoot: URL(fileURLWithPath: "/p"), reportDirectories: [])
        XCTAssertEqual(JavaTestRunner.taskPaths(for: request, debug: false), [":app:test"])
        XCTAssertEqual(JavaTestRunner.taskPaths(for: request, debug: true), [":app:cleanTest", ":app:test"])
        XCTAssertTrue(JavaTestRunner.gradleArguments(for: request, debug: true).contains("--debug-jvm"))
        XCTAssertFalse(JavaTestRunner.gradleArguments(for: request).contains("--debug-jvm"))
        let root = JavaTestRunRequest(gradleTaskPath: ":test", testFilter: nil, projectRoot: URL(fileURLWithPath: "/p"), reportDirectories: [])
        XCTAssertEqual(JavaTestRunner.taskPaths(for: root, debug: true), [":cleanTest", ":test"])
    }

    func testSeveralFiltersForRerunningFailedTests() throws {
        let request = try XCTUnwrap(JavaTestRunner.request(
            scope: .tests(taskPath: ":test", filters: ["a.BTest.one", "a.CTest.two"]),
            projectRoot: URL(fileURLWithPath: "/p"), model: nil
        ))
        XCTAssertEqual(JavaTestRunner.gradleArguments(for: request), ["--no-configuration-cache", "--continue", "--tests", "a.BTest.one", "--tests", "a.CTest.two"])
    }

    func testReportsKeepEachTestsOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("junit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuite name="a.BTest" tests="2">
          <testcase name="one" classname="a.BTest" time="0.01">
            <system-out><![CDATA[printed by one
        ]]></system-out>
          </testcase>
          <testcase name="two" classname="a.BTest" time="0.02">
            <failure message="boom" type="java.lang.AssertionError">java.lang.AssertionError: boom
            at a.BTest.two(BTest.java:12)</failure>
          </testcase>
          <system-out><![CDATA[suite output]]></system-out>
          <system-err><![CDATA[suite errors]]></system-err>
        </testsuite>
        """
        try Data(xml.utf8).write(to: directory.appendingPathComponent("TEST-a.BTest.xml"))
        let result = JUnitXMLReportParser.parseReports(in: [directory], projectRoot: directory)
        XCTAssertEqual(result.cases.map(\.output), ["printed by one", "suite output\nsuite errors"])
        XCTAssertEqual(result.cases.last?.message, "boom")
    }
}
