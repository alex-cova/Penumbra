import AppKit
import Foundation
import Penumbra
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

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0 ..< 200 where !condition() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
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
        try await waitUntil { session.chunks.count == 2 }
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
        try await waitUntil { session.chunks.count == 1 }
        XCTAssertTrue(viewer.rightTextView.isEditable)

        viewer.applyLeftToRight(chunk: 0, append: false)
        XCTAssertEqual(viewer.rightTextView.text, "one\ntwo\nthree\n")
        try await waitUntil { session.chunks.isEmpty }

        session.save()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "one\ntwo\nthree\n")
        XCTAssertFalse(session.isRightDirty)
        viewer.detach(session)
    }

    func testMappingLinesAcrossAChange() async throws {
        let session = IDEDiffSession(request: request("a\nb\nc\nd\n", "a\nx\ny\nz\nc\nd\n"), siblings: [])
        session.loadContent = { source in
            if case .text(let text) = source { return .text(text) }
            return .failed("")
        }
        session.reload()
        try await waitUntil { session.chunks.count == 1 }
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
            try await waitUntil { weakSession?.chunks.count == 1 }
            workspace.teardown()
        }
        for _ in 0 ..< 50 where weakWorkspace != nil || weakSession != nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(weakSession, "the diff session outlived its workspace")
        XCTAssertNil(weakWorkspace, "the workspace with a diff tab is still alive")
    }
}
