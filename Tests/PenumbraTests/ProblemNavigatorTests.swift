import XCTest
@testable import EditorIntelligence

final class ProblemNavigatorTests: XCTestCase {
    private let a = URL(fileURLWithPath: "/proj/A.java")
    private let b = URL(fileURLWithPath: "/proj/B.java")
    private let c = URL(fileURLWithPath: "/proj/C.java")

    private func diagnostic(_ line: Int, _ column: Int = 0, _ severity: DiagnosticSeverity = .error,
                            _ message: String = "problem") -> Diagnostic {
        let start = TextPosition(line: line, column: column, utf16Offset: 0)
        let end = TextPosition(line: line, column: column + 1, utf16Offset: 0)
        return Diagnostic(severity: severity, message: message, range: TextRange(start: start, end: end), source: "test")
    }

    private func files(_ sets: [URL: [Diagnostic]]) -> [ProblemFile] {
        DiagnosticGrouping.files(from: [sets])
    }

    private func spot(_ row: ProblemRow?) -> String {
        guard let row else { return "nil" }
        return "\(row.url.lastPathComponent):\(row.diagnostic.range.start.line):\(row.diagnostic.range.start.column)"
    }

    private func step(_ url: URL?, _ line: Int, _ column: Int = 0, forward: Bool = true,
                      in files: [ProblemFile]) -> String {
        spot(ProblemNavigator.step(from: .init(url: url, line: line, column: column), forward: forward, in: files))
    }

    func testNextGoesToTheFirstProblemAfterTheCaretInTheSameFile() {
        let list = files([a: [diagnostic(2), diagnostic(8), diagnostic(20)]])
        XCTAssertEqual(step(a, 0, in: list), "A.java:2:0")
        XCTAssertEqual(step(a, 2, in: list), "A.java:8:0", "A problem at the caret is not the next one")
        XCTAssertEqual(step(a, 9, in: list), "A.java:20:0")
    }

    func testColumnsBreakTiesOnALine() {
        let list = files([a: [diagnostic(5, 2), diagnostic(5, 9)]])
        XCTAssertEqual(step(a, 5, 0, in: list), "A.java:5:2")
        XCTAssertEqual(step(a, 5, 2, in: list), "A.java:5:9")
    }

    func testNextContinuesIntoTheNextFileByPath() {
        let list = files([a: [diagnostic(1)], b: [diagnostic(4)], c: [diagnostic(7)]])
        XCTAssertEqual(step(a, 1, in: list), "B.java:4:0")
        XCTAssertEqual(step(b, 10, in: list), "C.java:7:0")
    }

    func testNextWrapsFromTheLastProblemToTheFirst() {
        let list = files([a: [diagnostic(1)], b: [diagnostic(4)]])
        XCTAssertEqual(step(b, 4, in: list), "A.java:1:0")
        XCTAssertEqual(step(b, 30, in: list), "A.java:1:0")
    }

    func testPreviousGoesBackAndWraps() {
        let list = files([a: [diagnostic(1), diagnostic(9)], b: [diagnostic(4)]])
        XCTAssertEqual(step(a, 9, forward: false, in: list), "A.java:1:0")
        XCTAssertEqual(step(b, 4, forward: false, in: list), "A.java:9:0")
        XCTAssertEqual(step(a, 1, forward: false, in: list), "B.java:4:0", "Wraps to the last problem")
    }

    func testACaretInAFileWithoutProblemsStillFindsTheNeighbours() {
        let list = files([a: [diagnostic(1)], c: [diagnostic(7)]])
        XCTAssertEqual(step(b, 0, in: list), "C.java:7:0")
        XCTAssertEqual(step(b, 0, forward: false, in: list), "A.java:1:0")
    }

    func testAnUnsavedBufferStartsFromTheTop() {
        let list = files([a: [diagnostic(1), diagnostic(5)]])
        XCTAssertEqual(spot(ProblemNavigator.step(from: nil, forward: true, in: list)), "A.java:1:0")
        XCTAssertEqual(spot(ProblemNavigator.step(from: nil, forward: false, in: list)), "A.java:5:0")
    }

    func testOnlyErrorsAndWarningsCountByDefault() {
        let list = files([a: [diagnostic(1, 0, .hint), diagnostic(3, 0, .information), diagnostic(6, 0, .warning)]])
        XCTAssertEqual(step(a, 0, in: list), "A.java:6:0")
        let everything = ProblemNavigator.step(from: .init(url: a, line: 0, column: 0), forward: true, in: list,
                                               severities: [.error, .warning, .information, .hint])
        XCTAssertEqual(spot(everything), "A.java:1:0")
    }

    func testNoProblemsMeansNoTarget() {
        XCTAssertNil(ProblemNavigator.step(from: .init(url: a, line: 0, column: 0), forward: true, in: []))
        let hintsOnly = files([a: [diagnostic(1, 0, .hint)]])
        XCTAssertNil(ProblemNavigator.step(from: .init(url: a, line: 0, column: 0), forward: true, in: hintsOnly))
    }

    func testTheOnlyProblemUnderTheCaretIsNotATarget() {
        let list = files([a: [diagnostic(3, 4)]])
        XCTAssertNil(ProblemNavigator.step(from: .init(url: a, line: 3, column: 4), forward: true, in: list))
        XCTAssertEqual(step(a, 0, in: list), "A.java:3:4", "From elsewhere it is")
    }

    func testProblemsStartingAtTheSamePlaceAreOneStop() {
        let list = files([a: [diagnostic(2, 0, .error, "one"), diagnostic(2, 0, .warning, "two"), diagnostic(6)]])
        XCTAssertEqual(step(a, 2, in: list), "A.java:6:0")
    }

    func testFileURLsAreComparedStandardized() {
        let list = files([a: [diagnostic(1), diagnostic(5)]])
        let messy = URL(fileURLWithPath: "/proj/../proj/A.java")
        XCTAssertEqual(step(messy, 1, in: list), "A.java:5:0")
    }
}
