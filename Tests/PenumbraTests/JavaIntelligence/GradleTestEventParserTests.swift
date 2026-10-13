import XCTest
@testable import JavaIntelligence

final class GradleTestEventParserTests: XCTestCase {
    func testParsesAllEventKinds() {
        XCTAssertEqual(GradleTestEventParser.parse(line: "##umbra-test|suiteStart|:app:test|pkg.A||||"),
                       .suiteStarted(taskPath: ":app:test", className: "pkg.A"))
        XCTAssertEqual(GradleTestEventParser.parse(line: "##umbra-test|testStart|:app:test|pkg.A|foo()||"),
                       .testStarted(taskPath: ":app:test", className: "pkg.A", methodName: "foo()"))
        XCTAssertEqual(GradleTestEventParser.parse(line: "##umbra-test|testEnd|:app:test|pkg.A|foo()|FAILED|12"),
                       .testFinished(taskPath: ":app:test", className: "pkg.A", methodName: "foo()", status: .failed, durationMs: 12))
        XCTAssertEqual(GradleTestEventParser.parse(line: "##umbra-test|testEnd|:t|pkg.A|x|SKIPPED|0"),
                       .testFinished(taskPath: ":t", className: "pkg.A", methodName: "x", status: .skipped, durationMs: 0))
        XCTAssertEqual(GradleTestEventParser.parse(line: "##umbra-test|suiteEnd|:t|pkg.A||PASSED|99"),
                       .suiteFinished(taskPath: ":t", className: "pkg.A", status: .passed, durationMs: 99))
    }

    func testIgnoresNonMarkerAndMalformedLines() {
        XCTAssertNil(GradleTestEventParser.parse(line: "> Task :app:test"))
        XCTAssertNil(GradleTestEventParser.parse(line: ""))
        XCTAssertNil(GradleTestEventParser.parse(line: "##umbra-test|bogus|:t|A|m|PASSED|1"))
        XCTAssertNil(GradleTestEventParser.parse(line: "##umbra-test|testEnd|:t|A|m|WEIRD|1"))
        XCTAssertNil(GradleTestEventParser.parse(line: "##umbra-test|testEnd"))
    }

    func testToleratesInterleavedOutputBeforeMarker() {
        let line = "some println##umbra-test|testEnd|:t|pkg.A|m|PASSED|5"
        XCTAssertEqual(GradleTestEventParser.parse(line: line),
                       .testFinished(taskPath: ":t", className: "pkg.A", methodName: "m", status: .passed, durationMs: 5))
    }

    func testUnescapesFields() {
        let line = #"##umbra-test|testStart|:t|pkg.A|a\pb\\c\nd||"#
        XCTAssertEqual(GradleTestEventParser.parse(line: line),
                       .testStarted(taskPath: ":t", className: "pkg.A", methodName: "a|b\\c\nd"))
    }

    func testScriptEmitsTheMarkerFormat() {
        XCTAssertTrue(GradleTestEventsScript.source.contains("##umbra-test|"))
        XCTAssertTrue(GradleTestEventsScript.source.contains("addTestListener"))
    }
}
