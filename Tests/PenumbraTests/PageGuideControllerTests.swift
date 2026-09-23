import XCTest
@testable import Penumbra

@MainActor
final class PageGuideControllerTests: XCTestCase {
    func testColumnOffsetScalesLinearlyWithColumn() {
        let controller = PageGuideController()
        controller.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)

        controller.column = 40
        let offset40 = controller.columnOffset

        controller.column = 80
        let offset80 = controller.columnOffset

        XCTAssertGreaterThan(offset80, offset40)
        XCTAssertEqual(offset80, offset40 * 2, accuracy: 0.5)
    }

    func testChangingFontInvalidatesCachedColumnOffset() {
        let controller = PageGuideController()
        controller.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        controller.column = 80
        let smallFontOffset = controller.columnOffset

        controller.font = UIFont.monospacedSystemFont(ofSize: 20, weight: .regular)
        let largeFontOffset = controller.columnOffset

        XCTAssertGreaterThan(largeFontOffset, smallFontOffset)
    }

    func testChangingColumnInvalidatesCachedColumnOffset() {
        let controller = PageGuideController()
        controller.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)

        controller.column = 80
        let offset80 = controller.columnOffset

        controller.column = 120
        let offset120 = controller.columnOffset

        XCTAssertGreaterThan(offset120, offset80)
        XCTAssertEqual(offset120 / offset80, 1.5, accuracy: 0.01)
    }
}
