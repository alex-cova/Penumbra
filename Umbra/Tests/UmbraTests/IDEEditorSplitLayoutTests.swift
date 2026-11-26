import AppKit
import SwiftUI
import XCTest
@testable import Umbra

/// Where the editor panes land when the editor is split. A split chain is drawn by `SplitPanes`
/// with a `PanePresence` transition on every pane; that modifier once drew every split a quarter of
/// the window too far right, so the second pane ran off the edge of the card.
///
/// Needs a window server: `UMBRA_UI_TESTS=1 swift test --filter IDEEditorSplitLayoutTests`
@MainActor
final class IDEEditorSplitLayoutTests: XCTestCase {
    private var workspace: IDEWorkspace!
    private var keeper: IDEWorkspace!
    private var window: NSWindow!

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["UMBRA_UI_TESTS"] == "1",
            "set UMBRA_UI_TESTS=1 to run tests that need a window server"
        )
        IDEWorkspace.isSessionPersistenceEnabled = false
        keeper = IDEWorkspace()
        IDEWindowRegistry.shared.register(keeper)
        workspace = IDEWorkspace()
        workspace.bootstrap()
        IDEWindowRegistry.shared.register(workspace)
        window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 1250, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: IDERootView().environment(workspace).frame(minWidth: 960, minHeight: 640))
        window.orderFront(nil)
        workspace.openUntitled(displayName: "Untitled", text: "```mermaid\nflowchart LR\n    id1{This is the text}\n```")
        await settle()
    }

    override func tearDown() async throws {
        if let workspace {
            workspace.windowWillClose()
            window?.contentView = nil
            window?.close()
            workspace.teardown()
            IDEWindowRegistry.shared.unregister(workspace)
        }
        if let keeper { IDEWindowRegistry.shared.unregister(keeper) }
        IDEWorkspace.isSessionPersistenceEnabled = true
    }

    private func settle(_ seconds: Double = 0.6) async {
        try? await Task.sleep(for: .seconds(seconds))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    /// The panes' frames in the editor area's space, in the order the layout lists them.
    private func paneFrames() -> [CGRect] {
        workspace.workbench.layout.flattenedPanes().compactMap { workspace.editorPaneFrames[$0.id] }
    }

    private func assertInsideEditorArea(_ frames: [CGRect], _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let area = CGRect(origin: .zero, size: workspace.editorAreaSize)
        for frame in frames {
            XCTAssertGreaterThanOrEqual(frame.minX, -1, "\(what): pane starts left of the editor area", file: file, line: line)
            XCTAssertGreaterThanOrEqual(frame.minY, -1, "\(what): pane starts above the editor area", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, area.maxX + 1, "\(what): pane runs past the right edge", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxY, area.maxY + 1, "\(what): pane runs past the bottom edge", file: file, line: line)
        }
    }

    /// The editor views themselves, not only the frames SwiftUI reports for them.
    private func hostedEditorFrames() -> [CGRect] {
        var frames: [CGRect] = []
        func walk(_ view: NSView) {
            if String(describing: type(of: view)).contains("EditorHostContainer") {
                frames.append(view.convert(view.bounds, to: nil))
            }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        return frames
    }

    func testSplitRightSharesTheAreaEvenly() async throws {
        workspace.splitRight()
        await settle()

        let frames = paneFrames()
        XCTAssertEqual(frames.count, 2, "every pane reports its frame, including the one that was already open")
        guard frames.count == 2 else { return }
        let gap = IDEAppearance.Spacing.panelGap
        let area = workspace.editorAreaSize
        XCTAssertEqual(frames[0].minX, 0, accuracy: 1.5)
        XCTAssertEqual(frames[1].minX, frames[0].maxX + gap, accuracy: 1.5)
        XCTAssertEqual(frames[1].maxX, area.width, accuracy: 1.5)
        XCTAssertEqual(frames[0].width, frames[1].width, accuracy: 1.5)
        assertInsideEditorArea(frames, "split right")

        let views = hostedEditorFrames().sorted { $0.minX < $1.minX }
        let windowBounds = try XCTUnwrap(window.contentView).bounds
        XCTAssertEqual(views.count, 2)
        for view in views {
            XCTAssertLessThanOrEqual(view.maxX, windowBounds.maxX + 1, "an editor view runs off the window")
        }
    }

    func testSplittingAgainSharesTheAreaInThree() async throws {
        workspace.splitRight()
        await settle()
        workspace.splitRight()
        await settle()

        let frames = paneFrames()
        XCTAssertEqual(frames.count, 3)
        guard frames.count == 3 else { return }
        assertInsideEditorArea(frames, "three panes")
        XCTAssertEqual(frames[0].minX, 0, accuracy: 1.5)
        XCTAssertEqual(frames[2].maxX, workspace.editorAreaSize.width, accuracy: 1.5)
        for pair in zip(frames, frames.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.0.maxX, pair.1.minX + 1, "panes overlap")
        }
    }

    func testSplitDownSharesTheAreaEvenly() async throws {
        workspace.splitDown()
        await settle()

        let frames = paneFrames()
        XCTAssertEqual(frames.count, 2)
        guard frames.count == 2 else { return }
        assertInsideEditorArea(frames, "split down")
        XCTAssertEqual(frames[0].minY, 0, accuracy: 1.5)
        XCTAssertEqual(frames[1].maxY, workspace.editorAreaSize.height, accuracy: 1.5)
        XCTAssertEqual(frames[0].minX, 0, accuracy: 1.5)
        XCTAssertEqual(frames[1].minX, 0, accuracy: 1.5)
        XCTAssertEqual(frames[0].width, workspace.editorAreaSize.width, accuracy: 1.5)
    }

    func testClosingTheSecondPaneGivesTheAreaBack() async throws {
        workspace.splitRight()
        await settle()
        workspace.closeActivePane()
        await settle()

        let frames = paneFrames()
        XCTAssertEqual(frames.count, 1, "the closed pane's frame is dropped")
        guard let frame = frames.first else { return }
        XCTAssertEqual(frame.minX, 0, accuracy: 1.5)
        XCTAssertEqual(frame.width, workspace.editorAreaSize.width, accuracy: 1.5)
    }

    // MARK: Animation

    /// Widths of the widest editor view, sampled every frame or so while the layout settles.
    private func sampleWidestEditor(for seconds: Double) async -> [CGFloat] {
        var samples: [CGFloat] = []
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            window.contentView?.layoutSubtreeIfNeeded()
            if let widest = hostedEditorFrames().map(\.width).max() { samples.append(widest) }
            try? await Task.sleep(for: .milliseconds(12))
        }
        return samples
    }

    /// Panes open and close with the pane animation: the widest editor passes through widths between
    /// where it started and where it ends, instead of jumping.
    func testSplitRightAnimatesTheExistingPane() async throws {
        try XCTSkipIf(IDEAppearance.Motion.reduceMotion, "Reduce Motion is on")
        let start = hostedEditorFrames().map(\.width).max() ?? 0
        workspace.splitRight()
        let samples = await sampleWidestEditor(for: 0.8)
        let end = try XCTUnwrap(samples.last)
        XCTAssertLessThan(end, start - 100, "the pane shrank to its share")
        let between = samples.filter { $0 > end + 40 && $0 < start - 40 }
        XCTAssertGreaterThanOrEqual(between.count, 3, "the pane jumped from \(start) to \(end): \(samples)")
        XCTAssertEqual(samples, samples.sorted(by: >), "the pane only ever shrinks while opening")
    }

    func testClosingAPaneAnimatesTheSurvivor() async throws {
        try XCTSkipIf(IDEAppearance.Motion.reduceMotion, "Reduce Motion is on")
        workspace.splitRight()
        await settle()
        let start = hostedEditorFrames().map(\.width).max() ?? 0
        workspace.closeActivePane()
        let samples = await sampleWidestEditor(for: 0.8)
        let end = try XCTUnwrap(samples.last)
        XCTAssertGreaterThan(end, start + 100, "the survivor took the area back")
        let between = samples.filter { $0 > start + 40 && $0 < end - 40 }
        XCTAssertGreaterThanOrEqual(between.count, 3, "the pane jumped from \(start) to \(end): \(samples)")
    }
}
