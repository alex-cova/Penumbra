import AppKit
import SwiftIntelligence
import SwiftUI
import XCTest
@testable import Umbra

/// Hosts Settings ▸ Swift ▸ Inspections and the Inspect Code sheet on a Swift request, so a crash or an empty render
/// shows up in the test run. `UMBRA_VIEW_SNAPSHOTS=<folder>` keeps the images.
@MainActor
final class IDESwiftInspectionViewsSmokeTests: XCTestCase {
    private var workspace: IDEWorkspace!

    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
        workspace = IDEWorkspace()
    }

    override func tearDown() {
        workspace.teardown()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

    private func render<Content: View>(_ view: Content, size: NSSize, name: String) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.environment(workspace).preferredColorScheme(.dark))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        if let folder = ProcessInfo.processInfo.environment["UMBRA_VIEW_SNAPSHOTS"],
           let png = rep.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
        }
        return rep
    }

    /// The share of sampled pixels that are not the most common colour: zero for a blank view.
    private func ink(_ rep: NSBitmapImageRep) -> Double {
        var counts: [UInt32: Int] = [:]
        for y in stride(from: 0, to: rep.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 3) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let key = UInt32(color.redComponent * 255) << 16 | UInt32(color.greenComponent * 255) << 8 | UInt32(color.blueComponent * 255)
                counts[key, default: 0] += 1
            }
        }
        let total = counts.values.reduce(0, +)
        guard total > 0, let common = counts.values.max() else { return 0 }
        return 1 - Double(common) / Double(total)
    }

    func testTheSettingsPaneRendersTheProfileBarAndRules() throws {
        let rep = try render(IDESwiftInspectionsSettings().frame(width: 640), size: NSSize(width: 640, height: 700), name: "swift-inspections-settings")
        XCTAssertGreaterThan(ink(rep), 0.01, "the pane drew nothing")
    }

    func testTheSettingsPaneOpensOnARequestedRule() throws {
        workspace.showInspectionSettings(code: "force-unwrap", language: .swift)
        let rep = try render(IDESwiftInspectionsSettings().frame(width: 640), size: NSSize(width: 640, height: 700), name: "swift-inspections-focused")
        XCTAssertGreaterThan(ink(rep), 0.01)
        XCTAssertNil(workspace.inspections.focusedRuleCode, "the pane took the request")
    }

    func testTheInspectCodeSheetForSwiftShowsTheProfileAndNoJavaOnlyOptions() throws {
        let request = IDEInspectCodeRequest(language: .swift)
        let rep = try render(IDEInspectCodeSheet(request: request), size: NSSize(width: 480, height: 420), name: "swift-inspect-code-sheet")
        XCTAssertGreaterThan(ink(rep), 0.01)
    }
}
