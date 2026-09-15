import AppKit
import XCTest
@testable import Runestone

final class MetalColorTests: XCTestCase {
    func testPremultiplicationUsesRequestedOutputColorSpace() {
        let color = NSColor(
            colorSpace: .displayP3,
            components: [1, 0.2, 0.1, 0.5],
            count: 4
        )
        let p3 = MetalColor.premultiplied(color, appearance: nil, colorSpace: .displayP3)
        let srgb = MetalColor.premultiplied(color, appearance: nil, colorSpace: .sRGB)

        XCTAssertEqual(p3.w, 0.5, accuracy: 0.001)
        XCTAssertEqual(p3.x, 0.5, accuracy: 0.001)
        XCTAssertNotEqual(p3, srgb, "wide-gamut colors must not be flattened through sRGB")
    }
}
