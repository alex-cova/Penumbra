import XCTest
@testable import Penumbra

final class PalettePathElisionTests: XCTestCase {
    private let path = "src/test/kotlin/com/sicarx/conciliator/yuri/integration"

    func testKeepsAPathThatFits() {
        XCTAssertEqual(PalettePathElision.elide(path) { _ in true }, path)
    }

    func testDropsTheFewestMiddleComponentsKeepingThreeInFront() {
        let elided = PalettePathElision.elide(path) { $0.count <= 46 }
        XCTAssertEqual(elided, "src/test/kotlin/…/conciliator/yuri/integration")
    }

    func testShrinksTheHeadBeforeTheTailRunsOut() {
        let elided = PalettePathElision.elide(path) { $0.count <= 18 }
        XCTAssertEqual(elided, "src/…/integration")
    }

    func testFallsBackToTheLastComponent() {
        XCTAssertEqual(PalettePathElision.elide(path) { _ in false }, "…/integration")
    }

    func testShortPathsAreLeftToTheField() {
        XCTAssertEqual(PalettePathElision.elide("src/main") { _ in false }, "src/main")
    }
}
