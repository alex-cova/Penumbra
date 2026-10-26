import XCTest
@testable import Umbra

@MainActor
final class IDEZoomTests: XCTestCase {
    func testZoomMovesInTenPercentSteps() {
        XCTAssertEqual(IDEPreferences.zoomed(100, bySteps: 1), 110)
        XCTAssertEqual(IDEPreferences.zoomed(100, bySteps: -1), 90)
        XCTAssertEqual(IDEPreferences.zoomed(100, bySteps: 3), 130)
    }

    func testZoomStaysWithinItsRange() {
        XCTAssertEqual(IDEPreferences.zoomed(300, bySteps: 1), 300)
        XCTAssertEqual(IDEPreferences.zoomed(50, bySteps: -1), 50)
        XCTAssertEqual(IDEPreferences.zoomed(100, bySteps: 100), 300)
        XCTAssertEqual(IDEPreferences.zoomed(100, bySteps: -100), 50)
    }

    func testTheFontIsScaledByThePercentage() {
        XCTAssertEqual(IDEPreferences.scaledFontSize(13, zoomPercent: 100), 13)
        XCTAssertEqual(IDEPreferences.scaledFontSize(13, zoomPercent: 150), 19.5, accuracy: 0.0001)
        XCTAssertEqual(IDEPreferences.scaledFontSize(20, zoomPercent: 50), 10, accuracy: 0.0001)
    }
}
