import AppKit
import Foundation
@testable import Penumbra
import XCTest
@testable import Umbra

/// Diff tabs in the workspace: opening, reusing, loading, hunk edits, closing and not leaking.
@MainActor
final class IDEDiffTabTests: XCTestCase {
    override func setUp() {
        super.setUp()
        IDEWorkspace.isSessionPersistenceEnabled = false
    }

    override func tearDown() {
        IDEWorkspace.isSessionPersistenceEnabled = true
        super.tearDown()
    }

    private func request(_ left: String, _ right: String, title: String = "a.txt (Test)") -> IDEDiffRequest {
        IDEDiffRequest(
            left: IDEDiffSide(source: .text(left), title: "Left"),
            right: IDEDiffSide(source: .text(right), title: "Right"),
            filePath: nil,
            title: title
        )
    }


    private func diffDocuments(_ workspace: IDEWorkspace) -> [WorkbenchDocument] {
        workspace.workbench.allDocuments().filter { $0.contentKind == .diff }
    }

    func testOpeningLoadsTheChunksAndReopeningSelectsTheSameTab() async throws {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        let diff = request("a\nb\nc\n", "a\nB\nc\nd\n")
        workspace.openDiff(diff)
        XCTAssertEqual(diffDocuments(workspace).count, 1)
        let document = try XCTUnwrap(diffDocuments(workspace).first)
        XCTAssertEqual(document.displayName, "a.txt (Test)")
        let session = try XCTUnwrap(workspace.diffSessions[document.id])
        await waitForCondition(timeout: 2) { session.chunks.count == 2 }
        XCTAssertEqual(session.chunks.map(\.kind), [.modified, .inserted])

        workspace.openDiff(diff)
        XCTAssertEqual(diffDocuments(workspace).count, 1)

        workspace.closeTab(document.id)
        XCTAssertTrue(diffDocuments(workspace).isEmpty)
        XCTAssertTrue(workspace.diffSessions.isEmpty)
    }

    func testDiffTabsAreNotRestored() {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        workspace.openDiff(request("x", "y"))
        let snapshot = EditorPaneSnapshot(pane: workspace.workbench.activePane)
        XCTAssertTrue(snapshot.documents.allSatisfy { $0.contentKind != .diff })
        XCTAssertNil(snapshot.selectedDocumentID.flatMap { id in snapshot.documents.first { $0.id == id }?.contentKind == .diff ? id : nil })
    }

    func testTheChevronRevertsAChangeInTheEditableSide() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diff-tab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.txt")
        try "one\nTWO\nthree\n".write(to: file, atomically: true, encoding: .utf8)

        let viewer = IDEDiffViewerView(frame: CGRect(x: 0, y: 0, width: 900, height: 500))
        let session = IDEDiffSession(
            request: IDEDiffRequest(
                left: IDEDiffSide(source: .text("one\ntwo\nthree\n"), title: "HEAD"),
                right: IDEDiffSide(source: .workingTree(path: file.path), title: "Your Version"),
                filePath: file.path,
                title: "a.txt"
            ),
            siblings: []
        )
        session.loadContent = { source in
            switch source {
            case .text(let text): return .text(text)
            case .workingTree(let path): return .text((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            case .revision: return .failed("no git")
            }
        }
        viewer.show(session, preferences: IDEPreferences.shared)
        await waitForCondition(timeout: 2) { session.chunks.count == 1 }
        XCTAssertTrue(viewer.rightTextView.isEditable)

        viewer.applyLeftToRight(chunk: 0, append: false)
        XCTAssertEqual(viewer.rightTextView.text, "one\ntwo\nthree\n")
        await waitForCondition(timeout: 2) { session.chunks.isEmpty }

        session.save()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "one\ntwo\nthree\n")
        XCTAssertFalse(session.isRightDirty)
        viewer.detach(session)
    }

    /// The editable side was loaded, then someone else rewrote the file: saving asks first.
    func testSavingTheEditableSideOverANewerFileAsks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("diff-tab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.txt")
        try "one\nTWO\nthree\n".write(to: file, atomically: true, encoding: .utf8)

        let viewer = IDEDiffViewerView(frame: CGRect(x: 0, y: 0, width: 900, height: 500))
        let session = IDEDiffSession(
            request: IDEDiffRequest(
                left: IDEDiffSide(source: .text("one\ntwo\nthree\n"), title: "HEAD"),
                right: IDEDiffSide(source: .workingTree(path: file.path), title: "Your Version"),
                filePath: file.path,
                title: "a.txt"
            ),
            siblings: []
        )
        session.loadContent = { source in
            switch source {
            case .text(let text): return .text(text)
            case .workingTree(let path): return .text((try? String(contentsOfFile: path, encoding: .utf8)) ?? "")
            case .revision: return .failed("no git")
            }
        }
        var asked = 0
        var answer = false
        session.confirmOverwrite = { _ in asked += 1; return answer }
        viewer.show(session, preferences: IDEPreferences.shared)
        defer { viewer.detach(session) }
        await waitForCondition(timeout: 2) { session.chunks.count == 1 }

        viewer.applyLeftToRight(chunk: 0, append: false)
        try "someone else\n".write(to: file, atomically: true, encoding: .utf8)
        session.save()
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "someone else\n", "Cancel wrote anyway")
        XCTAssertTrue(session.isRightDirty)

        answer = true
        session.save()
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "one\ntwo\nthree\n")
        XCTAssertFalse(session.isRightDirty)
    }

    func testMappingLinesAcrossAChange() async throws {
        let session = IDEDiffSession(request: request("a\nb\nc\nd\n", "a\nx\ny\nz\nc\nd\n"), siblings: [])
        session.loadContent = { source in
            if case .text(let text) = source { return .text(text) }
            return .failed("")
        }
        session.reload()
        await waitForCondition(timeout: 2) { session.chunks.count == 1 }
        // "b" (left line 1) became x, y, z (right lines 1-3); "c" moves from 2 to 4.
        XCTAssertEqual(session.mapLine(0, fromRight: false), 0)
        XCTAssertEqual(session.mapLine(1, fromRight: false), 1)
        XCTAssertEqual(session.mapLine(1.5, fromRight: false), 2.5)
        XCTAssertEqual(session.mapLine(2, fromRight: false), 4)
        XCTAssertEqual(session.mapLine(4, fromRight: true), 2)
    }

    func testAClosedWorkspaceWithADiffTabIsFreed() async throws {
        weak var weakWorkspace: IDEWorkspace?
        weak var weakSession: IDEDiffSession?
        do {
            let workspace = IDEWorkspace()
            workspace.bootstrap()
            weakWorkspace = workspace
            workspace.openDiff(request("a", "b"))
            let document = try XCTUnwrap(diffDocuments(workspace).first)
            weakSession = workspace.diffSessions[document.id]
            await waitForCondition(timeout: 2) { weakSession?.chunks.count == 1 }
            workspace.teardown()
        }
        // Five seconds, ending as soon as both are gone: a workspace that has just been torn down
        // can still have a main-thread stall ahead of it (see `minimumPollTimeout`).
        for _ in 0 ..< 250 where weakWorkspace != nil || weakSession != nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(weakSession, "the diff session outlived its workspace")
        XCTAssertNil(weakWorkspace, "the workspace with a diff tab is still alive")
    }

    // MARK: - Embedded viewer (History pane)

    func testAnEmbeddedViewerSwapsFilesRevealsTheFirstChangeAndReportsOnlyItsOwnMoves() async throws {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        // The default layout applies until one was picked; start without a stored pick.
        UserDefaults.standard.removeObject(forKey: IDEDiffSettings.embeddedPrefix + "layout")
        let first = request("a\nb\nc\nd\ne\n", "a\nb\nc\nd\nE\n", title: "first")
        let second = request("1\n2\n", "1\n2\n3\n", title: "second")
        var reported: [String] = []
        func view(_ request: IDEDiffRequest) -> IDEEmbeddedDiffView {
            IDEEmbeddedDiffView(
                workspace: workspace,
                request: request,
                siblings: [first, second],
                onRequestChanged: { reported.append($0.title) }
            )
        }

        let viewer = IDEDiffViewerView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        let coordinator = IDEEmbeddedDiffView.Coordinator()
        coordinator.viewer = viewer
        coordinator.update(view(first))
        let session = try XCTUnwrap(coordinator.session)
        XCTAssertEqual(session.settings.layout, .unified, "the History pane starts unified")
        await waitForCondition(timeout: 2) { session.chunks.count == 1 }
        XCTAssertEqual(session.currentChunkIndex, 0, "the first change is revealed")

        // The pane picking another file is not reported back.
        coordinator.update(view(second))
        XCTAssertEqual(session.request.title, "second")
        await waitForCondition(timeout: 2) { session.chunks.first?.kind == .inserted }
        XCTAssertEqual(session.currentChunkIndex, 0)
        XCTAssertTrue(reported.isEmpty, "\(reported)")

        // The viewer's own Previous File is.
        session.moveToFile(by: -1)
        XCTAssertEqual(reported, ["first"])

        coordinator.teardown()
        XCTAssertNil(coordinator.session)
    }

    func testAnEmbeddedSessionTakesTheSiblingsOfTheNextCommit() throws {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        let a = request("1", "2", title: "a")
        let b = request("3", "4", title: "b")
        let c = request("5", "6", title: "c")
        let session = workspace.makeEmbeddedDiffSession(a, siblings: [a, b])
        XCTAssertTrue(session.canMoveToFile(by: 1))
        session.show(request: c, siblings: [c])
        XCTAssertEqual(session.request.title, "c")
        XCTAssertFalse(session.canMoveToFile(by: 1))
        XCTAssertFalse(session.canMoveToFile(by: -1))
        session.cancel()
    }

    // MARK: - Collapse Unchanged Fragments

    func testCollapsingUnchangedFragmentsOnAndOffKeepsBothSidesScrollableAndPainted() async throws {
        let workspace = IDEWorkspace()
        workspace.bootstrap()
        defer { workspace.teardown() }
        let lines = (0 ..< 300).map { "let value\($0) = \($0)" }
        var changed = lines
        changed[150] = "let value150 = -1"
        let diff = request(lines.joined(separator: "\n") + "\n", changed.joined(separator: "\n") + "\n")
        let prefix = "umbra.test.diff.collapse."
        defer {
            for key in ["layout", "whitespace", "highlight", "collapse", "syncScroll"] {
                UserDefaults.standard.removeObject(forKey: prefix + key)
            }
        }
        let session = IDEDiffSession(request: diff, siblings: [], settings: IDEDiffSettings(), settingsPrefix: prefix)
        session.loadContent = { source in
            if case .text(let text) = source { return .text(text) }
            return .failed("no git")
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let viewer = IDEDiffViewerView(frame: CGRect(x: 0, y: 0, width: 900, height: 500))
        window.contentView = viewer
        viewer.show(session, preferences: IDEPreferences.shared)
        await waitForCondition(timeout: 3) { session.chunks.count == 1 }
        viewer.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        let fullHeight = viewer.rightTextView.contentSize.height
        XCTAssertGreaterThan(fullHeight, 3_000)

        session.settings.collapsesUnchanged = true
        for _ in 0 ..< 30 {
            viewer.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let foldedHeight = viewer.rightTextView.contentSize.height
        XCTAssertLessThan(foldedHeight, fullHeight / 2, "the unchanged runs are folded")

        session.settings.collapsesUnchanged = false
        for _ in 0 ..< 10 {
            viewer.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        for textView in [viewer.leftTextView, viewer.rightTextView] {
            XCTAssertEqual(textView.contentSize.height, fullHeight, accuracy: 1, "it scrolls to the end again")
        }

        session.settings.collapsesUnchanged = true
        for _ in 0 ..< 30 {
            viewer.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(viewer.rightTextView.contentSize.height, foldedHeight, accuracy: 1, "folded again without a click")
        XCTAssertEqual(viewer.leftTextView.contentSize.height, foldedHeight, accuracy: 1)
        session.cancel()
    }

    private func settle(_ viewer: IDEDiffViewerView, steps: Int = 30) async throws {
        for _ in 0 ..< steps {
            viewer.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func collapsedViewer(
        collapsed: Bool,
        prefix: String,
        lineCount: Int = 900,
        changedLines: [Int]? = nil,
        layout: IDEDiffLayout = .sideBySide,
        startsEmpty: Bool = false
    ) async throws -> (IDEDiffViewerView, IDEDiffSession) {
        // By default a change every 30 lines: folded, the text is still taller than the viewport.
        let lines = (0 ..< lineCount).map { "let value\($0) = \($0)" }
        var changed = lines
        let changes = changedLines ?? Array(stride(from: 40, to: 900, by: 30))
        for index in changes { changed[index] = "let value\(index) = -1" }
        let diff = request(lines.joined(separator: "\n") + "\n", changed.joined(separator: "\n") + "\n")
        var settings = IDEDiffSettings()
        settings.collapsesUnchanged = collapsed
        settings.layout = layout
        let session = IDEDiffSession(request: diff, siblings: [], settings: settings, settingsPrefix: prefix)
        session.loadContent = { source in
            if case .text(let text) = source { return .text(text) }
            return .failed("no git")
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        // SwiftUI creates a hosted viewer with no size and sizes it after the first update.
        let viewer = IDEDiffViewerView(frame: startsEmpty ? .zero : CGRect(x: 0, y: 0, width: 900, height: 500))
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 500))
        container.addSubview(viewer)
        window.contentView = container
        viewer.show(session, preferences: IDEPreferences.shared)
        await waitForCondition(timeout: 3) { session.chunks.count == changes.count }
        if startsEmpty {
            viewer.frame = container.bounds
            viewer.autoresizingMask = [.width, .height]
        }
        try await settle(viewer)
        objc_setAssociatedObject(viewer, "window", window, .OBJC_ASSOCIATION_RETAIN)
        return (viewer, session)
    }

    func testOpeningACollapsedDiffLeavesTheFirstChangeInView() async throws {
        let prefix = "umbra.test.diff.reveal."
        let (viewer, session) = try await collapsedViewer(collapsed: true, prefix: prefix)
        defer { session.cancel() }
        for textView in [viewer.leftTextView, viewer.rightTextView] {
            let top = textView.yPosition(ofLine: 41)
            XCTAssertGreaterThanOrEqual(top, textView.contentOffset.y, "the change is above the viewport")
            XCTAssertLessThanOrEqual(top, textView.contentOffset.y + textView.bounds.height, "the change is below the viewport")
        }
        XCTAssertGreaterThan(viewer.rightTextView.contentSize.height, viewer.rightTextView.bounds.height * 2, "the folded text still scrolls")
    }

    func testAnUnrelatedOptionDoesNotCollapseFoldsTheUserOpened() async throws {
        let prefix = "umbra.test.diff.keepopen."
        defer {
            for key in ["layout", "whitespace", "highlight", "collapse", "syncScroll"] {
                UserDefaults.standard.removeObject(forKey: prefix + key)
            }
        }
        let (viewer, session) = try await collapsedViewer(collapsed: true, prefix: prefix)
        defer { session.cancel() }
        let folded = viewer.rightTextView.contentSize.height
        XCTAssertTrue(viewer.rightTextView.perform(.expandAllRegions))
        try await settle(viewer, steps: 10)
        let expanded = viewer.rightTextView.contentSize.height
        XCTAssertGreaterThan(expanded, folded)

        session.settings.synchronizesScrolling.toggle()
        try await settle(viewer, steps: 20)
        XCTAssertEqual(viewer.rightTextView.contentSize.height, expanded, accuracy: 1,
                       "changing an unrelated option folded the text again")
    }

    func testReapplyingThePreferencesKeepsTheViewersOwnFoldingState() async throws {
        let prefix = "umbra.test.diff.prefs."
        let preferences = IDEPreferences.shared
        let saved = preferences.isLineFoldingEnabled
        defer { preferences.isLineFoldingEnabled = saved }
        preferences.isLineFoldingEnabled = true
        let (viewer, session) = try await collapsedViewer(collapsed: false, prefix: prefix)
        defer { session.cancel() }
        XCTAssertFalse(viewer.rightTextView.isLineFoldingEnabled, "no folds in a diff unless asked for")
        // The editor's folding switch is applied to every text view, the viewer's included.
        viewer.applyPreferences()
        XCTAssertFalse(viewer.rightTextView.isLineFoldingEnabled)
        XCTAssertFalse(viewer.leftTextView.isLineFoldingEnabled)

        session.settings.collapsesUnchanged = true
        preferences.isLineFoldingEnabled = false
        viewer.applyPreferences()
        XCTAssertTrue(viewer.rightTextView.isLineFoldingEnabled, "Collapse Unchanged wins over the editor's switch")
        XCTAssertTrue(viewer.leftTextView.isLineFoldingEnabled)
    }

    func testAFirstChangeNearTheEndOfABigFileIsInViewOnceTheFoldsLand() async throws {
        let prefix = "umbra.test.diff.late."
        let (viewer, session) = try await collapsedViewer(
            collapsed: true, prefix: prefix, lineCount: 2000, changedLines: [1853, 1856, 1900, 1960]
        )
        defer { session.cancel() }
        try await settle(viewer)
        for textView in [viewer.leftTextView, viewer.rightTextView] {
            let top = textView.yPosition(ofLine: 1854)
            XCTAssertGreaterThanOrEqual(top, textView.contentOffset.y, "the first change is above the viewport")
            XCTAssertLessThanOrEqual(top, textView.contentOffset.y + textView.bounds.height, "the first change is below the viewport")
        }
    }

    func testAFirstChangeNearTheEndOfABigFileIsInViewInTheUnifiedLayout() async throws {
        let prefix = "umbra.test.diff.lateunified."
        let (viewer, session) = try await collapsedViewer(
            collapsed: true, prefix: prefix, lineCount: 2000, changedLines: [1853, 1856, 1900, 1960], layout: .unified
        )
        defer { session.cancel() }
        try await settle(viewer)
        let textView = viewer.unifiedTextView
        // The unified text lists the old line, then the new one: the change starts at row 1853.
        let top = textView.yPosition(ofLine: 1854)
        XCTAssertGreaterThanOrEqual(top, textView.contentOffset.y)
        XCTAssertLessThanOrEqual(top, textView.contentOffset.y + textView.bounds.height)
    }

    func testAViewerSizedAfterItOpenedStillShowsTheFirstChangeOfABigFile() async throws {
        let prefix = "umbra.test.diff.sizedlater."
        let (viewer, session) = try await collapsedViewer(
            collapsed: true, prefix: prefix, lineCount: 2000, changedLines: [1853, 1856, 1900, 1960], startsEmpty: true
        )
        defer { session.cancel() }
        try await settle(viewer, steps: 40)
        for textView in [viewer.leftTextView, viewer.rightTextView] {
            XCTAssertGreaterThan(textView.bounds.height, 100)
            let top = textView.yPosition(ofLine: 1854)
            XCTAssertGreaterThanOrEqual(top, textView.contentOffset.y, "the first change is above the viewport")
            XCTAssertLessThanOrEqual(top, textView.contentOffset.y + textView.bounds.height, "the first change is below the viewport")
        }
    }

    func testTurningCollapseOffAndOnKeepsTheCurrentChangeInView() async throws {
        let prefix = "umbra.test.diff.toggle."
        defer {
            for key in ["layout", "whitespace", "highlight", "collapse", "syncScroll"] {
                UserDefaults.standard.removeObject(forKey: prefix + key)
            }
        }
        let (viewer, session) = try await collapsedViewer(
            collapsed: true, prefix: prefix, lineCount: 2000, changedLines: [1853, 1856, 1900, 1960], startsEmpty: true
        )
        defer { session.cancel() }
        func assertChangeInView(_ label: String, file: StaticString = #filePath, line: UInt = #line) {
            for textView in [viewer.leftTextView, viewer.rightTextView] {
                let top = textView.yPosition(ofLine: 1854)
                XCTAssertGreaterThanOrEqual(top, textView.contentOffset.y, "\(label): the change is above the viewport", file: file, line: line)
                XCTAssertLessThanOrEqual(top, textView.contentOffset.y + textView.bounds.height, "\(label): the change is below the viewport", file: file, line: line)
            }
        }
        try await settle(viewer, steps: 20)
        assertChangeInView("collapsed")

        session.settings.collapsesUnchanged = false
        try await settle(viewer, steps: 20)
        assertChangeInView("expanded again")

        session.settings.collapsesUnchanged = true
        try await settle(viewer, steps: 20)
        assertChangeInView("collapsed again")
    }
}
