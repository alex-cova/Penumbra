import XCTest
@testable import Umbra

final class IDEExecutionLineTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/tmp/project/Main.java")

    func testBandCoversTheStoppedLineOfTheShownFile() {
        let bands = IDEWorkspace.executionLineBackgrounds(stopFile: file, stopLine: 21, shownFile: file)
        XCTAssertEqual(bands.map(\.line), [21])
        XCTAssertEqual(bands.map(\.lineCount), [1])
    }

    func testNoBandForAnotherFile() {
        let other = URL(fileURLWithPath: "/tmp/project/Other.java")
        XCTAssertTrue(IDEWorkspace.executionLineBackgrounds(stopFile: file, stopLine: 3, shownFile: other).isEmpty)
        XCTAssertTrue(IDEWorkspace.executionLineBackgrounds(stopFile: file, stopLine: 3, shownFile: nil).isEmpty)
    }

    func testNoBandWithoutAStop() {
        XCTAssertTrue(IDEWorkspace.executionLineBackgrounds(stopFile: nil, stopLine: nil, shownFile: file).isEmpty)
        XCTAssertTrue(IDEWorkspace.executionLineBackgrounds(stopFile: file, stopLine: 0, shownFile: file).isEmpty)
    }

    func testPathsAreCompared_standardized() {
        let unnormalized = URL(fileURLWithPath: "/tmp/project/../project/Main.java")
        XCTAssertEqual(IDEWorkspace.executionLineBackgrounds(stopFile: unnormalized, stopLine: 2, shownFile: file).count, 1)
    }
}
