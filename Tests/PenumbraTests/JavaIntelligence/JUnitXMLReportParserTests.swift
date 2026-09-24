import JavaIntelligence
import XCTest

final class JUnitXMLReportParserTests: XCTestCase {
    func testParsesFailure() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <testsuite name="com.example.FooTest" tests="1" failures="1" skipped="0" time="0.01">
          <testcase classname="com.example.FooTest" name="bar" time="0.01">
            <failure message="expected:&lt;1&gt; but was:&lt;2&gt;">org.opentest4j.AssertionFailedError: expected:&lt;1&gt; but was:&lt;2&gt;</failure>
          </testcase>
        </testsuite>
        """
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("TEST-com.example.FooTest.xml")
        try xml.write(to: file, atomically: true, encoding: .utf8)
        let result = JUnitXMLReportParser.parseReports(in: [dir], projectRoot: dir.deletingLastPathComponent())
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.cases.first?.name, "bar")
        XCTAssertEqual(result.cases.first?.status, .failed)
    }
}
