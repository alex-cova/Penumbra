import AppKit
import Foundation
import Observation
import Penumbra
import XCTest
@testable import Umbra

/// Reproduction for "opened a PNG, no toolbar or edit UI visible": opening an image through the
/// real `openDocument(from:)` path must leave the pane in a state where the toolbar gate passes,
/// the viewer covers the editor, and edit mode can engage.
@MainActor
final class IDEPhotoTabTests: XCTestCase {
    private var directory: URL!
    private var workspace: IDEWorkspace!

    override func setUp() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-tab-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.bootstrap()
    }

    override func tearDown() async throws {
        workspace?.teardown()
        IDEWorkspace.isSessionPersistenceEnabled = true
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func writePNG(named name: String, size: NSSize = NSSize(width: 64, height: 48)) throws -> URL {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "IDEPhotoTabTests", code: 1)
        }
        let url = directory.appendingPathComponent(name)
        try png.write(to: url)
        return url
    }

    /// The toolbar gate from `IDEEditorPaneView`, factored so the test and the view agree.
    private func toolbarShouldShow(paneID: UUID) -> Bool {
        guard let document = workspace.selectedTabDocument(in: paneID),
              document.contentKind == .image,
              !workspace.isPhotoEditing(document.id) else {
            return false
        }
        return true
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    private func waitForCounter(_ counter: Counter, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<100 {
            if counter.value > 0 { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("observation did not fire", file: file, line: line)
    }

    func testOpeningPNGShowsViewerAndPassesToolbarGate() async throws {
        let url = try writePNG(named: "sample.png")
        await workspace.openDocument(from: url)
        // The gate the pane view reads: image selected, not editing.
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        XCTAssertEqual(document.contentKind, .image)
        XCTAssertTrue(toolbarShouldShow(paneID: workspace.workbench.activePaneID))

        // The viewer covers the editor with the file showing.
        let host = workspace.host(for: workspace.workbench.activePaneID)
        XCTAssertTrue(host.imageViewerController.isShowing(url: url))
        XCTAssertFalse(host.textView.isSelectable, "covered editor must be locked")
    }

    func testGateFollowsTabSwitchesBetweenImageAndText() async throws {
        let png = try writePNG(named: "gated.png")
        let txtURL = directory.appendingPathComponent("gated.txt")
        try "hello".write(to: txtURL, atomically: true, encoding: .utf8)
        await workspace.openDocument(from: png)
        await workspace.openDocument(from: txtURL)
        let paneID = workspace.workbench.activePaneID
        let pngDoc = try XCTUnwrap(workspace.workbench.allDocuments().first { $0.url == png })
        let txtDoc = try XCTUnwrap(workspace.workbench.allDocuments().first { $0.url == txtURL })

        workspace.selectTab(pngDoc.id, in: paneID)
        XCTAssertEqual(workspace.selectedTabDocument(in: paneID)?.id, pngDoc.id)
        XCTAssertTrue(toolbarShouldShow(paneID: paneID))

        workspace.selectTab(txtDoc.id, in: paneID)
        XCTAssertEqual(workspace.selectedTabDocument(in: paneID)?.id, txtDoc.id)
        XCTAssertFalse(toolbarShouldShow(paneID: paneID))
    }

    func testGateObservationFiresOnTabSwitch() async throws {
        let png = try writePNG(named: "observed.png")
        let txtURL = directory.appendingPathComponent("observed.txt")
        try "hello".write(to: txtURL, atomically: true, encoding: .utf8)
        await workspace.openDocument(from: png)
        await workspace.openDocument(from: txtURL)
        let paneID = workspace.workbench.activePaneID
        let pngDoc = try XCTUnwrap(workspace.workbench.allDocuments().first { $0.url == png })

        // Reading the helper subscribes to tab switches: the pane body re-runs when this fires.
        // (Before the fix the gate read only the unobserved workbench tree, so the toolbar never
        // appeared after a switch even though the viewer and tab bar moved on.)
        let counter = Counter()
        withObservationTracking {
            _ = workspace.selectedTabDocument(in: paneID)
        } onChange: {
            counter.increment()
        }
        workspace.selectTab(pngDoc.id, in: paneID)
        await waitForCounter(counter)
    }

    func testEditModeEngagesAndExits() async throws {
        let url = try writePNG(named: "edit.png")
        await workspace.openDocument(from: url)
        let document = try XCTUnwrap(workspace.workbench.activePane.selectedDocument)
        XCTAssertFalse(workspace.isPhotoEditing(document.id))

        workspace.setPhotoEditing(true, document: document)
        XCTAssertTrue(workspace.isPhotoEditing(document.id))
        XCTAssertFalse(toolbarShouldShow(paneID: workspace.workbench.activePaneID))
        let session = try XCTUnwrap(workspace.photoSessionStore.session(for: document.id))
        XCTAssertTrue(session.hasImage)

        workspace.setPhotoEditing(false, document: document)
        XCTAssertFalse(workspace.isPhotoEditing(document.id))
        XCTAssertTrue(toolbarShouldShow(paneID: workspace.workbench.activePaneID))
        // Leaving edit mode re-shows the (possibly re-saved) file in the viewer.
        let host = workspace.host(for: workspace.workbench.activePaneID)
        XCTAssertTrue(host.imageViewerController.isShowing(url: url))
    }
}
