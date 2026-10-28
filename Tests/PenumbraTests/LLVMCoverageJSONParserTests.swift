import Foundation
@testable import JavaIntelligence
import XCTest

/// `llvm-cov export` JSON from a real `swift test --enable-code-coverage` run of a two-file package
/// (`Fixtures/SwiftCoverage`: `Area.swift` is half covered, `Circle.swift` not at all).
final class LLVMCoverageJSONParserTests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/SwiftCoverage")

    private func fixture() throws -> Data {
        try Data(contentsOf: Self.fixtures.appendingPathComponent("shapes.json"))
    }

    private func report(includeTests: Bool = false) throws -> JavaCoverageReport {
        try LLVMCoverageJSONParser.parse(
            fixture(), name: "Shapes", options: .init(projectRoot: URL(fileURLWithPath: "/proj"), includeTests: includeTests)
        )
    }

    func testATargetIsAPackageAndAFileIsAClass() throws {
        let report = try report()
        XCTAssertEqual(report.packages.map(\.name), ["Shapes"], "the generated test entry point in .build and the tests are left out")
        let package = try XCTUnwrap(report.packages.first)
        XCTAssertEqual(package.sourceFiles.map(\.name), ["Area.swift", "Circle.swift"])
        XCTAssertEqual(package.classes.map(\.displayName), ["Area", "Circle"])
        XCTAssertEqual(package.sourceFiles.first?.url, URL(fileURLWithPath: "/proj/Sources/Shapes/Area.swift"))
        XCTAssertEqual(report.sourceFile(at: URL(fileURLWithPath: "/proj/Sources/Shapes/Circle.swift"))?.name, "Circle.swift")
    }

    func testLinesAndCountsAreTheOnesLLVMCovShowPrints() throws {
        let area = try XCTUnwrap(report().sourceFiles.first { $0.name == "Area.swift" })
        // `llvm-cov show` prints a count on exactly these 20 lines, 15 of them above zero. (The export's summary says 21:
        // it counts a line `show` does not print, so the editor follows `show`.)
        XCTAssertEqual(area.totals.lines.total, 20)
        XCTAssertEqual(area.totals.lines.covered, 15)
        XCTAssertEqual(area.lines.map(\.number), [5, 6, 7, 8, 10, 11, 12, 14, 15, 16, 17, 18, 19, 20, 22, 23, 24, 26, 27, 28])
        XCTAssertEqual(area.totals.methods, JavaCoverageCounter(missed: 2, covered: 4))
    }

    func testLinesAreCoveredOrMissedByTheToolsOwnRule() throws {
        let area = try XCTUnwrap(report().sourceFiles.first { $0.name == "Area.swift" })
        // The source is `Fixtures/SwiftCoverage/Area.swift.txt`.
        XCTAssertEqual(area.status(atLine: 11), .covered, "area()")
        XCTAssertEqual(area.status(atLine: 16), .covered, "describe(verbose:) when true")
        XCTAssertEqual(area.status(atLine: 17), .covered, "`} else {` is reached through the true branch")
        XCTAssertEqual(area.status(atLine: 18), .missed, "the else branch never ran")
        XCTAssertEqual(area.status(atLine: 27), .missed, "unused()")
        XCTAssertNil(area.status(atLine: 1), "the declaration line has no code")
        XCTAssertNil(area.status(atLine: 9), "a blank line between functions")
        XCTAssertEqual(area.bands.map { "\($0.lines.lowerBound)-\($0.lines.upperBound) \($0.status)" },
                       ["5-8 covered", "10-12 covered", "14-17 covered", "18-19 missed", "20-20 covered", "22-24 covered", "26-28 missed"])
    }

    func testALineWithTwoRegionsOneOfThemUnexecutedIsPartial() {
        // `a ? b : c` style: two regions start on line 3, one never ran.
        let segments = [
            segment(1, 1, 5, true, true), segment(3, 4, 5, true, true), segment(3, 20, 0, true, true), segment(3, 30, 5, true, false),
            segment(4, 1, 0, false, false),
        ]
        let lines = LLVMCoverageJSONParser.lines(from: segments)
        XCTAssertEqual(lines.map(\.number), [1, 2, 3, 4])
        XCTAssertEqual(lines.map(\.status), [.covered, .covered, .partial, .covered])
    }

    private func segment(_ line: Int, _ column: Int, _ count: Int, _ hasCount: Bool, _ entry: Bool) -> LLVMCoverageJSONParser.Segment {
        let json = "[\(line),\(column),\(count),\(hasCount),\(entry),false]"
        return try! JSONDecoder().decode(LLVMCoverageJSONParser.Segment.self, from: Data(json.utf8))
    }

    func testAFileNothingRanIsEntirelyMissed() throws {
        let circle = try XCTUnwrap(report().sourceFiles.first { $0.name == "Circle.swift" })
        XCTAssertEqual(circle.totals.lines.covered, 0)
        XCTAssertTrue(circle.lines.allSatisfy { $0.status == .missed })
        XCTAssertEqual(circle.totals.classes, JavaCoverageCounter(missed: 1))
        XCTAssertEqual(circle.bands.count, circle.bands.map(\.lines).count)
    }

    func testReportTotalsAreTheSumOfTheFiles() throws {
        let report = try report()
        let area = try XCTUnwrap(report.sourceFiles.first { $0.name == "Area.swift" })
        let circle = try XCTUnwrap(report.sourceFiles.first { $0.name == "Circle.swift" })
        XCTAssertEqual(report.totals.lines, area.totals.lines + circle.totals.lines)
        XCTAssertEqual(report.totals.lines.percent, report.totals.lines.covered * 100 / report.totals.lines.total)
    }

    func testTestSourcesAreOptional() throws {
        let report = try report(includeTests: true)
        XCTAssertEqual(report.packages.map(\.name), ["Shapes", "ShapesTests"])
    }

    func testNothingIsReadFromOutsideTheProject() throws {
        XCTAssertThrowsError(try LLVMCoverageJSONParser.parse(
            fixture(), name: "x", options: .init(projectRoot: URL(fileURLWithPath: "/elsewhere"))
        )) { XCTAssertEqual($0 as? LLVMCoverageJSONParser.ParseError, .noFiles) }
    }

    func testOtherDataIsRefused() {
        XCTAssertThrowsError(try LLVMCoverageJSONParser.parse(Data("<report/>".utf8), name: "x")) {
            XCTAssertEqual($0 as? LLVMCoverageJSONParser.ParseError, .notCoverageData)
        }
        XCTAssertThrowsError(try LLVMCoverageJSONParser.parse(Data(#"{"type":"something","data":[]}"#.utf8), name: "x")) {
            XCTAssertEqual($0 as? LLVMCoverageJSONParser.ParseError, .notCoverageData)
        }
    }
}
