import XCTest
@testable import JavaIntelligence

final class JUnitXMLReportParserTests: XCTestCase {
    private func results(since: Date? = nil) -> [JavaTestResult] {
        JUnitXMLReportParser.parse(directory: JUnitFixtures.directory, since: since)
    }

    func testParsesStatusesAndFailureDetails() {
        let calc = results().filter { $0.className == "com.acme.CalcTest" }
        XCTAssertEqual(calc.map(\.methodName), ["adds", "divides", "crashes", "later"])
        XCTAssertEqual(calc.map(\.status), [.passed, .failed, .errored, .skipped])
        let divides = calc[1]
        XCTAssertEqual(divides.failureMessage, "expected: <2> but was: <3>")
        XCTAssertEqual(divides.failureType, "org.opentest4j.AssertionFailedError")
        XCTAssertEqual(JavaStackTraceParser.firstProjectFrame(in: divides.stackTrace ?? "")?.line, 42)
        XCTAssertEqual(divides.durationSeconds, 0.02, accuracy: 0.0001)
        XCTAssertEqual(calc[2].failureType, "java.lang.IllegalStateException")
    }

    func testSuiteOutputIsAttachedToEveryCase() {
        let calc = results().filter { $0.className == "com.acme.CalcTest" }
        XCTAssertTrue(calc.allSatisfy { $0.systemOut == "hello | out\nline two" })
        XCTAssertTrue(calc.allSatisfy { $0.systemErr == "warn" })
    }

    func testParameterizedNames() {
        let param = results().filter { $0.className == "com.acme.ParamTest" }
        XCTAssertEqual(param.map(\.methodName), ["square", "square", ""])
        XCTAssertEqual(param.map(\.displayName), ["square(int)[1]", "square(int)[2]", "[1] arg"])
        XCTAssertEqual(param.map(\.status), [.passed, .failed, .passed])
        XCTAssertTrue(param.allSatisfy(\.isInvocation))
    }

    func testNestedClassKeepsBinaryName() throws {
        let nested = try XCTUnwrap(results().first { $0.className.contains("Inner") })
        XCTAssertEqual(nested.className, "com.acme.Outer$Inner")
        XCTAssertEqual(nested.outerClassName, "com.acme.Outer")
        XCTAssertEqual(nested.methodName, "nested")
    }

    func testOnlyFilesModifiedSinceAreParsed() throws {
        XCTAssertEqual(results(since: Date().addingTimeInterval(3600)).count, 0)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("junit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = JUnitFixtures.directory.appendingPathComponent("TEST-com.acme.CalcTest.xml")
        let dst = dir.appendingPathComponent("TEST-com.acme.CalcTest.xml")
        try FileManager.default.copyItem(at: src, to: dst)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: dst.path)
        XCTAssertEqual(JUnitXMLReportParser.parse(directory: dir, since: Date(timeIntervalSince1970: 2000)).count, 0)
        XCTAssertEqual(JUnitXMLReportParser.parse(directory: dir, since: Date(timeIntervalSince1970: 500)).count, 4)
    }

    func testGarbageYieldsNothing() {
        XCTAssertEqual(JUnitXMLReportParser.parse(data: Data("not xml".utf8)).count, 0)
    }
}
