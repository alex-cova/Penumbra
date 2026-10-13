import XCTest
@testable import Umbra

final class IDESwiftUIPreviewLayoutTests: XCTestCase {
    // MARK: Zoom

    func testZoomStepsMoveToTheNextLargerAndSmallerLevel() {
        XCTAssertEqual(IDESwiftUIPreviewZoom.next(after: 1), 1.25)
        XCTAssertEqual(IDESwiftUIPreviewZoom.previous(before: 1), 0.75)
        // A value between steps (a pinch, or a fit) goes to the step on its side.
        XCTAssertEqual(IDESwiftUIPreviewZoom.next(after: 0.76), 1)
        XCTAssertEqual(IDESwiftUIPreviewZoom.previous(before: 0.76), 0.75)
        XCTAssertEqual(IDESwiftUIPreviewZoom.previous(before: 0.7), 0.5)
        // The ends stay put.
        XCTAssertEqual(IDESwiftUIPreviewZoom.next(after: 4), 4)
        XCTAssertEqual(IDESwiftUIPreviewZoom.previous(before: 0.25), 0.25)
    }

    func testZoomIsClampedAndTitled() {
        XCTAssertEqual(IDESwiftUIPreviewZoom.clamped(10), 4)
        XCTAssertEqual(IDESwiftUIPreviewZoom.clamped(0.01), 0.25)
        XCTAssertEqual(IDESwiftUIPreviewZoom.percentTitle(0.755), "76%")
        XCTAssertNil(IDESwiftUIPreviewZoom.fit.factor)
        XCTAssertEqual(IDESwiftUIPreviewZoom.scale(1.5).factor, 1.5)
    }

    // MARK: Layout

    func testTheCanvasWindowIsThePanelDividedByTheZoom() {
        let panel = CGSize(width: 840, height: 600)
        XCTAssertEqual(IDESwiftUIPreviewLayout.canvasWindowSize(viewport: panel, zoom: .fit), panel)
        XCTAssertEqual(IDESwiftUIPreviewLayout.canvasWindowSize(viewport: panel, zoom: .scale(1)), panel)
        XCTAssertEqual(IDESwiftUIPreviewLayout.canvasWindowSize(viewport: panel, zoom: .scale(0.5)),
                       CGSize(width: 1680, height: 1200))
        XCTAssertEqual(IDESwiftUIPreviewLayout.canvasWindowSize(viewport: panel, zoom: .scale(2)),
                       CGSize(width: 420, height: 300))
        // Never a window of more than 4096 points a side.
        let tall = IDESwiftUIPreviewLayout.canvasWindowSize(viewport: CGSize(width: 840, height: 3000), zoom: .scale(0.25))
        XCTAssertEqual(tall.height, 4096)
    }

    func testFitShrinksAFrameThatIsLargerThanThePanelAndNeverEnlargesIt() {
        let panel = CGSize(width: 840, height: 600)
        // 1100 × 720 in 840 × 600, leaving the margin on each side.
        let scale = IDESwiftUIPreviewLayout.displayScale(
            zoom: .fit, fillsCanvas: false, frameSize: CGSize(width: 1100, height: 720), extra: .zero, panel: panel
        )
        XCTAssertEqual(scale, (840 - 32) / 1100, accuracy: 0.0001)
        // A small device is shown at 100%.
        XCTAssertEqual(IDESwiftUIPreviewLayout.displayScale(
            zoom: .fit, fillsCanvas: false, frameSize: CGSize(width: 393, height: 500), extra: .zero, panel: panel
        ), 1)
        // The bezel counts: the device alone fits at 100%, with its body it does not.
        let withBezel = IDESwiftUIPreviewLayout.displayScale(
            zoom: .fit, fillsCanvas: false, frameSize: CGSize(width: 393, height: 580),
            extra: CGSize(width: 24, height: 24), panel: panel
        )
        XCTAssertLessThan(withBezel, 1)
        // A frame that is the panel's own size is not scaled by Fit, and an explicit zoom is used as given.
        XCTAssertEqual(IDESwiftUIPreviewLayout.displayScale(
            zoom: .fit, fillsCanvas: true, frameSize: panel, extra: .zero, panel: panel
        ), 1)
        XCTAssertEqual(IDESwiftUIPreviewLayout.displayScale(
            zoom: .scale(2), fillsCanvas: false, frameSize: CGSize(width: 1100, height: 720), extra: .zero, panel: panel
        ), 2)
    }

    func testAPointOnAZoomedFrameIsAPointOfThePreview() {
        // The 400 × 300 preview is shown at 50%: 200 × 150 on the canvas.
        let mapped = IDESwiftUIPreviewLayout.framePoint(
            CGPoint(x: 100, y: 75), viewSize: CGSize(width: 200, height: 150), frameSize: CGSize(width: 400, height: 300)
        )
        XCTAssertEqual(mapped, CGPoint(x: 200, y: 150))
        // No size yet: the point is passed through.
        XCTAssertEqual(IDESwiftUIPreviewLayout.framePoint(CGPoint(x: 5, y: 6), viewSize: .zero, frameSize: .zero),
                       CGPoint(x: 5, y: 6))
    }

    // MARK: Devices

    func testDevicesHaveUniqueIdsAndPortraitPhoneSizes() {
        let devices = IDESwiftUIPreviewDevice.all
        XCTAssertEqual(Set(devices.map(\.id)).count, devices.count)
        XCTAssertEqual(Set(devices.map(\.name)).count, devices.count)
        for device in devices {
            XCTAssertGreaterThan(device.height, device.width, device.name)
            XCTAssertTrue((300...500).contains(device.width), device.name)
            XCTAssertGreaterThan(device.bodyCornerRadius, 0, device.name)
            // The safe area leaves the screen most of its height and the island or notch inside it.
            XCTAssertTrue((20...70).contains(device.safeTop), device.name)
            XCTAssertTrue(device.safeBottom == 0 || device.safeBottom == 34, device.name)
            XCTAssertLessThan(device.safeTop + device.safeBottom, Double(device.height) / 8, device.name)
        }
        let sixteenPro = devices.first { $0.id == "iphone-16-pro" }
        XCTAssertEqual(sixteenPro?.size, CGSize(width: 402, height: 874))
        XCTAssertEqual(sixteenPro?.cutout, .dynamicIsland)
        XCTAssertEqual(devices.first { $0.id == "iphone-se" }?.cutout, .homeButton)
    }

    func testSizePresetsHaveStableUniqueIdentities() {
        let all = IDESwiftUIPreviewSession.SizePreset.all
        XCTAssertEqual(Set(all.map(\.id)).count, all.count)
        XCTAssertEqual(IDESwiftUIPreviewSession.SizePreset.canvas.id, "canvas")
        XCTAssertEqual(IDESwiftUIPreviewSession.SizePreset.content.title, "Content Size")
        let device = IDESwiftUIPreviewSession.SizePreset.devices.first
        XCTAssertNotNil(device?.device)
        XCTAssertTrue(device?.id.hasPrefix("device-") == true)
        // The picker groups together hold exactly the presets.
        XCTAssertEqual(all.count,
                       IDESwiftUIPreviewSession.SizePreset.layouts.count
                       + IDESwiftUIPreviewSession.SizePreset.devices.count
                       + IDESwiftUIPreviewSession.SizePreset.windows.count)
    }
}
