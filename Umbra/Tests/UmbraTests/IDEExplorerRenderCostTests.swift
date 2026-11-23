import AppKit
import SwiftUI
import XCTest
@testable import Umbra

/// Main-thread cost of the Explorer on a large expanded tree (`EXPLORERCOST`): a click that only
/// moves the selection, and a tick of a sidebar-width drag. Needs a window server, so it runs only
/// with `UMBRA_UI_TESTS=1`.
@MainActor
final class IDEExplorerRenderCostTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["UMBRA_UI_TESTS"] == "1",
            "set UMBRA_UI_TESTS=1 to run tests that need a window server"
        )
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("explorer-cost-\(UUID().uuidString)", isDirectory: true)
        for folder in 0..<40 {
            let sub = directory.appendingPathComponent("package\(folder)", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            for file in 0..<50 {
                try Data().write(to: sub.appendingPathComponent("SomeReasonablyNamedClass\(file).java"))
            }
        }
    }

    override func tearDown() async throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func milliseconds(_ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func summary(_ times: [Double]) -> String {
        let sorted = times.sorted()
        return String(format: "median=%.2fms p90=%.2fms max=%.2fms",
                      sorted[sorted.count / 2], sorted[sorted.count * 9 / 10], sorted.last ?? 0)
    }

    func testSelectionAndWidthCostOnALargeExpandedTree() async throws {
        let project = IDEProjectModel()
        project.setRoot(directory)
        for _ in 0..<200 where project.allDirectoryPaths().count < 41 {
            try await Task.sleep(for: .milliseconds(20))
        }
        project.expandAll()
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 300, height: 800),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.contentView = nil; window.close() }
        window.contentView = NSHostingView(rootView: IDEFileTreeView(
            project: project, onOpenFile: { _ in }, collapsedWhileFiltering: .constant([])
        ))
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(300))

        let rows = (0..<20).map { directory.appendingPathComponent("package0/SomeReasonablyNamedClass\($0).java").path }
        var selection: [Double] = []
        for row in rows {
            selection.append(milliseconds {
                project.selectedPath = row
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            })
            await Task.yield()
        }
        var width: [Double] = []
        let origin = window.frame.origin
        for tick in 0..<20 {
            width.append(milliseconds {
                window.setFrame(NSRect(x: origin.x, y: origin.y, width: 300 + Double(tick) * 4, height: 800), display: true)
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            })
            await Task.yield()
        }
        print("EXPLORERCOST rows=2040 selection " + Self.summary(selection))
        print("EXPLORERCOST rows=2040 width " + Self.summary(width))
    }
}
