import XCTest
@testable import Penumbra

final class PaletteLineTargetTests: XCTestCase {
    func testSplitsLineAndColumn() {
        let split = PaletteLineTarget.split("Foo.java:12:4")
        XCTAssertEqual(split?.query, "Foo.java")
        XCTAssertEqual(split?.target, PaletteLineTarget(line: 12, column: 4))
    }

    func testSplitsLineOnly() {
        let split = PaletteLineTarget.split("Foo:7")
        XCTAssertEqual(split?.query, "Foo")
        XCTAssertEqual(split?.target, PaletteLineTarget(line: 7))
    }

    func testTrailingColonStripsWithoutATarget() {
        let split = PaletteLineTarget.split("Foo:")
        XCTAssertEqual(split?.query, "Foo")
        XCTAssertNil(split?.target)
    }

    func testIgnoresQueriesWithoutANumericSuffix() {
        XCTAssertNil(PaletteLineTarget.split("Foo"))
        XCTAssertNil(PaletteLineTarget.split("Foo:bar"))
        XCTAssertNil(PaletteLineTarget.split(":12"))
    }
}
