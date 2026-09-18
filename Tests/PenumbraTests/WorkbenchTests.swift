import XCTest
import EditorIntelligence
@testable import Penumbra

final class WorkbenchTests: XCTestCase {
    func testEditorPaneOpensAndSelects() {
        let pane = EditorPane()
        let doc = WorkbenchDocument(displayName: "a.swift", text: "let a = 1")
        pane.openDocument(doc)
        XCTAssertEqual(pane.selectedDocument?.id, doc.id)
        XCTAssertEqual(pane.documents.count, 1)
    }

    func testTemporaryTabReusesCleanSlot() {
        let pane = EditorPane()
        let first = WorkbenchDocument(displayName: "a.txt", text: "a")
        let second = WorkbenchDocument(displayName: "b.txt", text: "b")
        pane.openDocument(first, asTemporary: true)
        pane.openDocument(second, asTemporary: true)
        XCTAssertEqual(pane.documents.count, 1)
        XCTAssertEqual(pane.selectedDocument?.displayName, "b.txt")
        XCTAssertTrue(pane.isTemporary(pane.documents[0]))
    }

    func testTemporaryTabDoesNotReuseADirtySlot() {
        let pane = EditorPane()
        let first = WorkbenchDocument(displayName: "a.txt", text: "a")
        first.isDirty = true
        let second = WorkbenchDocument(displayName: "b.txt", text: "b")
        pane.openDocument(first, asTemporary: true)
        pane.openDocument(second, asTemporary: true)
        XCTAssertEqual(pane.documents.count, 2)
        XCTAssertEqual(pane.documents[0].displayName, "a.txt")
        XCTAssertEqual(pane.selectedDocument?.displayName, "b.txt")
    }

    func testTemporaryTabReuseCopiesFileBackedState() async throws {
        let firstURL = FileManager.default.temporaryDirectory.appendingPathComponent("first-\(UUID().uuidString).txt")
        let secondURL = FileManager.default.temporaryDirectory.appendingPathComponent("second-\(UUID().uuidString).txt")
        try "first body\n".write(to: firstURL, atomically: true, encoding: .utf8)
        try "second body\n".write(to: secondURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let first = try await WorkbenchDocument.load(contentsOf: firstURL)
        let second = try await WorkbenchDocument.load(contentsOf: secondURL)
        let pane = EditorPane()
        pane.openDocument(first, asTemporary: true)
        let reused = pane.openDocument(second, asTemporary: true)
        XCTAssertEqual(pane.documents.count, 1)
        XCTAssertEqual(reused.displayName, secondURL.lastPathComponent)
        XCTAssertTrue(reused.isFileBacked)
        XCTAssertNotNil(reused.pendingState)
        XCTAssertNotNil(reused.rangeReader)
    }

    func testTabListEngineSelectionAfterClose() {
        XCTAssertEqual(TabListEngine.selectionIndexAfterClose(closing: 1, selected: 1, count: 3), 1)
    }

    func testDisambiguatedTitlesAppendsParentDirectoryOnCollision() {
        let urls = [
            URL(fileURLWithPath: "/project/utils/index.ts"),
            URL(fileURLWithPath: "/project/models/index.ts")
        ]
        let titles = TabListEngine.disambiguatedTitles(fileNames: ["index.ts", "index.ts"], urls: urls)
        XCTAssertEqual(titles, ["index.ts — utils", "index.ts — models"])
    }

    func testDisambiguatedTitlesLeavesUniqueNamesUnchanged() {
        let urls = [URL(fileURLWithPath: "/project/a.swift"), URL(fileURLWithPath: "/project/b.swift")]
        let titles = TabListEngine.disambiguatedTitles(fileNames: ["a.swift", "b.swift"], urls: urls)
        XCTAssertEqual(titles, ["a.swift", "b.swift"])
    }

    func testDisambiguatedTitlesLeavesUntitledBuffersUnchangedEvenOnCollision() {
        let titles = TabListEngine.disambiguatedTitles(fileNames: ["untitled", "untitled"], urls: [nil, nil])
        XCTAssertEqual(titles, ["untitled", "untitled"])
    }

    func testWorkbenchAggregatesDocuments() {
        let bench = EditorWorkbench()
        let doc = WorkbenchDocument(displayName: "one", text: "1")
        bench.openDocument(doc)
        XCTAssertEqual(bench.allDocuments().count, 1)
    }

    func testWorkbenchDocumentLoadReusesPendingState() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "line one\nline two\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try await WorkbenchDocument.load(contentsOf: url)
        XCTAssertEqual(document.displayName, url.lastPathComponent)
        XCTAssertTrue(document.isFileBacked)
        XCTAssertEqual(document.text, "")
        XCTAssertEqual(document.pendingState?.stringView.string as String?, "line one\nline two\n")
        XCTAssertEqual(document.url, url)
        XCTAssertNotNil(document.pendingState)
        XCTAssertEqual(document.pendingState?.parsePolicy, .viewport)
        XCTAssertGreaterThan(document.pendingState?.lineManager.lineCount ?? 0, 1)
    }

    func testWorkbenchAdapterReportsOpenDocuments() {
        let bench = EditorWorkbench()
        let doc = WorkbenchDocument(displayName: "one", text: "hello")
        bench.openDocument(doc)
        let adapter = PenumbraWorkbenchEditorAdapter(workbench: bench)
        XCTAssertEqual(adapter.openDocuments.count, 1)
        XCTAssertEqual(adapter.currentDocument?.displayName, "one")
    }

    func testSplitActivePaneAddsSecondPane() {
        let bench = EditorWorkbench()
        let originalPaneID = bench.activePaneID
        let newPane = bench.splitActivePane(edge: .trailing)
        XCTAssertEqual(bench.panes.count, 2)
        XCTAssertEqual(bench.activePaneID, newPane.id)
        XCTAssertNotEqual(bench.activePaneID, originalPaneID)
    }

    func testClosePaneFallsBackToRemainingPane() {
        let bench = EditorWorkbench()
        let firstPaneID = bench.activePaneID
        let secondPane = bench.splitActivePane(edge: .trailing)
        bench.closePane(secondPane.id)
        XCTAssertEqual(bench.panes.count, 1)
        XCTAssertEqual(bench.activePaneID, firstPaneID)
    }

    /// A workbench closed back down to a single pane: `closePane`'s `flatten()` collapses the
    /// single-child container `EditorWorkbench.init` wraps a lone pane in down to a bare `.pane`
    /// case, which is the root shape `EditorLayout.splitPane`'s root-pane branch handles — a fresh
    /// `EditorWorkbench` never exercises that branch on its very first split, since its initial
    /// layout is already a one-child container.
    private func makeBareRootBench() -> EditorWorkbench {
        let bench = EditorWorkbench()
        let second = bench.splitActivePane(edge: .trailing)
        bench.closePane(second.id)
        return bench
    }

    private func paneID(of layout: EditorLayout) -> UUID? {
        if case .pane(let pane) = layout { return pane.id }
        return nil
    }

    func testSplitFromBareRootProducesCorrectAxisForAllEdges() {
        // .leading/.trailing on a bare-pane root must produce a `.horizontal` container (children
        // side by side); .top/.bottom must produce `.vertical` (children stacked). All four edges
        // collapsing to the same `.horizontal` container regardless was the bug.
        do {
            let bench = makeBareRootBench()
            let original = bench.panes[0]
            let newPane = bench.splitActivePane(edge: .leading)
            guard case .horizontal(let data) = bench.layout else {
                return XCTFail("expected a .horizontal container for a .leading split")
            }
            XCTAssertEqual(data.axis, .horizontal)
            XCTAssertEqual(data.children.compactMap(paneID(of:)), [newPane.id, original.id])
        }
        do {
            let bench = makeBareRootBench()
            let original = bench.panes[0]
            let newPane = bench.splitActivePane(edge: .trailing)
            guard case .horizontal(let data) = bench.layout else {
                return XCTFail("expected a .horizontal container for a .trailing split")
            }
            XCTAssertEqual(data.axis, .horizontal)
            XCTAssertEqual(data.children.compactMap(paneID(of:)), [original.id, newPane.id])
        }
        do {
            let bench = makeBareRootBench()
            let original = bench.panes[0]
            let newPane = bench.splitActivePane(edge: .top)
            guard case .vertical(let data) = bench.layout else {
                return XCTFail("expected a .vertical container for a .top split")
            }
            XCTAssertEqual(data.axis, .vertical)
            XCTAssertEqual(data.children.compactMap(paneID(of:)), [newPane.id, original.id])
        }
        do {
            let bench = makeBareRootBench()
            let original = bench.panes[0]
            let newPane = bench.splitActivePane(edge: .bottom)
            guard case .vertical(let data) = bench.layout else {
                return XCTFail("expected a .vertical container for a .bottom split")
            }
            XCTAssertEqual(data.axis, .vertical)
            XCTAssertEqual(data.children.compactMap(paneID(of:)), [original.id, newPane.id])
        }
    }

    func testSplitFromContainerRootHandlesSiblingAndOrthogonalCases() {
        // Same-axis edge: a plain sibling insert into the existing container.
        do {
            let bench = EditorWorkbench()
            let paneA = bench.activePane
            let paneB = bench.splitActivePane(edge: .trailing) // root: .horizontal([A, B]), active = B
            let paneC = bench.splitActivePane(edge: .trailing)
            guard case .horizontal(let data) = bench.layout else {
                return XCTFail("expected a .horizontal root")
            }
            XCTAssertEqual(data.children.compactMap(paneID(of:)), [paneA.id, paneB.id, paneC.id])
        }
        do {
            let bench = EditorWorkbench()
            let paneA = bench.activePane
            let paneB = bench.splitActivePane(edge: .trailing)
            let paneC = bench.splitActivePane(edge: .leading)
            guard case .horizontal(let data) = bench.layout else {
                return XCTFail("expected a .horizontal root")
            }
            XCTAssertEqual(data.children.compactMap(paneID(of:)), [paneA.id, paneC.id, paneB.id])
        }
        // Orthogonal edge: wraps the target child in a new container of the other axis instead of
        // inserting a sibling into the existing one.
        do {
            let bench = EditorWorkbench()
            let paneA = bench.activePane
            let paneB = bench.splitActivePane(edge: .trailing)
            let paneC = bench.splitActivePane(edge: .bottom)
            guard case .horizontal(let outer) = bench.layout else {
                return XCTFail("expected a .horizontal root")
            }
            XCTAssertEqual(outer.children.count, 2)
            XCTAssertEqual(paneID(of: outer.children[0]), paneA.id)
            guard case .vertical(let inner) = outer.children[1] else {
                return XCTFail("expected a nested .vertical container for a .bottom split")
            }
            XCTAssertEqual(inner.children.compactMap(paneID(of:)), [paneB.id, paneC.id])
        }
        do {
            let bench = EditorWorkbench()
            let paneA = bench.activePane
            let paneB = bench.splitActivePane(edge: .trailing)
            let paneC = bench.splitActivePane(edge: .top)
            guard case .horizontal(let outer) = bench.layout else {
                return XCTFail("expected a .horizontal root")
            }
            XCTAssertEqual(outer.children.count, 2)
            XCTAssertEqual(paneID(of: outer.children[0]), paneA.id)
            guard case .vertical(let inner) = outer.children[1] else {
                return XCTFail("expected a nested .vertical container for a .top split")
            }
            XCTAssertEqual(inner.children.compactMap(paneID(of:)), [paneC.id, paneB.id])
        }
    }

    func testNestedSplitWritesBackThroughRecursion() {
        let bench = EditorWorkbench()
        let paneA = bench.activePane
        let paneB = bench.splitActivePane(edge: .trailing) // root: .horizontal([A, B])
        let paneC = bench.splitActivePane(edge: .bottom)   // root: .horizontal([A, .vertical([B, C])])
        // Split C again along the nested container's own axis, two levels deep — exercises the
        // recursive write-back in `EditorLayout.splitPane`'s container branch
        // (`child.splitPane(...); data.children[index] = child`).
        let paneD = bench.splitActivePane(edge: .bottom)
        guard case .horizontal(let outer) = bench.layout else {
            return XCTFail("expected the outer .horizontal container to survive the nested split")
        }
        XCTAssertEqual(outer.children.count, 2)
        XCTAssertEqual(paneID(of: outer.children[0]), paneA.id)
        guard case .vertical(let inner) = outer.children[1] else {
            return XCTFail("expected the nested .vertical container to survive the nested split")
        }
        XCTAssertEqual(inner.children.compactMap(paneID(of:)), [paneB.id, paneC.id, paneD.id])
        XCTAssertEqual(bench.panes.count, 4)
    }

    func testRestorationRoundTripPreservesTabsAndSelection() throws {
        let bench = EditorWorkbench()
        let docA = WorkbenchDocument(displayName: "a.txt", text: "alpha")
        let docB = WorkbenchDocument(displayName: "b.txt", text: "beta")
        bench.openDocument(docA)
        bench.openDocument(docB)
        bench.activePane.selectDocument(docA.id)

        let encoded = try JSONEncoder().encode(bench.makeRestorationState())
        let decoded = try JSONDecoder().decode(EditorRestorationState.self, from: encoded)

        let restored = EditorWorkbench()
        restored.restore(from: decoded)
        XCTAssertEqual(restored.panes.count, 1)
        XCTAssertEqual(restored.activePane.documents.count, 2)
        XCTAssertEqual(restored.activePane.selectedDocument?.displayName, "a.txt")
        XCTAssertEqual(restored.activePane.documents.map(\.displayName), ["a.txt", "b.txt"])
    }

    func testSnapshotEncodesIsFileBacked() throws {
        let document = WorkbenchDocument(displayName: "mmap.txt", text: "")
        document.isFileBacked = true
        document.url = URL(fileURLWithPath: "/tmp/mmap.txt")
        let snapshot = WorkbenchDocumentSnapshot(document: document)
        XCTAssertTrue(snapshot.isFileBacked)
        XCTAssertEqual(snapshot.text, "")
        let encoded = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(WorkbenchDocumentSnapshot.self, from: encoded)
        XCTAssertTrue(decoded.isFileBacked)
        XCTAssertEqual(decoded.text, "")

        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object.removeValue(forKey: "isFileBacked")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(WorkbenchDocumentSnapshot.self, from: stripped)
        XCTAssertFalse(legacy.isFileBacked)
    }

    func testRestoreThenReloadFileBackedDocumentsReloadsMmapContent() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "mmap body\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try await WorkbenchDocument.load(contentsOf: url)
        document.selectedRange = NSRange(location: 2, length: 3)
        document.isDirty = true
        let originalID = document.id
        let originalDocumentID = document.documentID
        let bench = EditorWorkbench()
        bench.openDocument(document)

        let encoded = try JSONEncoder().encode(bench.makeRestorationState())
        let decoded = try JSONDecoder().decode(EditorRestorationState.self, from: encoded)

        let restored = EditorWorkbench()
        restored.restore(from: decoded)
        let restoredDoc = restored.activePane.selectedDocument
        XCTAssertEqual(restoredDoc?.id, originalID)
        XCTAssertEqual(restoredDoc?.documentID, originalDocumentID)
        XCTAssertEqual(restoredDoc?.text, "")
        XCTAssertTrue(restoredDoc?.isFileBacked ?? false)
        XCTAssertNil(restoredDoc?.pendingState)
        XCTAssertEqual(restoredDoc?.isDirty, true)

        try await restored.reloadFileBackedDocuments()
        let reloaded = restored.activePane.selectedDocument
        XCTAssertEqual(reloaded?.id, originalID)
        XCTAssertEqual(reloaded?.documentID, originalDocumentID)
        XCTAssertEqual(reloaded?.text, "")
        XCTAssertTrue(reloaded?.isFileBacked ?? false)
        XCTAssertEqual(
            reloaded?.pendingState?.stringView.substring(in: NSRange(location: 0, length: 10)),
            "mmap body\n"
        )
        XCTAssertEqual(reloaded?.pendingState?.stringView.materializeCount, 0)
        XCTAssertEqual(reloaded?.selectedRange, NSRange(location: 2, length: 3))
        XCTAssertEqual(reloaded?.isDirty, true)
        XCTAssertNotNil(reloaded?.rangeReader)
    }

    func testRestorationPreservesSplitLayout() throws {
        let bench = EditorWorkbench()
        bench.openDocument(WorkbenchDocument(displayName: "left", text: "L"))
        let rightPane = bench.splitActivePane(edge: .trailing)
        bench.openDocument(WorkbenchDocument(displayName: "right", text: "R"), in: rightPane)

        let encoded = try JSONEncoder().encode(bench.makeRestorationState())
        let decoded = try JSONDecoder().decode(EditorRestorationState.self, from: encoded)

        let restored = EditorWorkbench()
        restored.restore(from: decoded)
        XCTAssertEqual(restored.panes.count, 2)
        XCTAssertEqual(restored.activePane.selectedDocument?.displayName, "right")
        let leftPane = restored.panes.first { $0.id != restored.activePaneID }
        XCTAssertEqual(leftPane?.selectedDocument?.displayName, "left")
    }

    func testRestorationPreservesSplitAxis() throws {
        // A fresh `EditorWorkbench` always wraps its lone pane in a one-child `.horizontal`
        // container, so its very first split never reaches a top-level `.vertical` case
        // regardless of edge. Split from a bare-pane root (see `makeBareRootBench`) so `.bottom`
        // actually produces a top-level `.vertical` container worth round-tripping.
        let bench = makeBareRootBench()
        bench.openDocument(WorkbenchDocument(displayName: "top", text: "T"))
        let bottomPane = bench.splitActivePane(edge: .bottom)
        bench.openDocument(WorkbenchDocument(displayName: "bottom", text: "B"), in: bottomPane)
        guard case .vertical(let data) = bench.layout else {
            return XCTFail("expected a top-level .vertical split for a .bottom edge from a bare-pane root")
        }
        XCTAssertEqual(data.axis, .vertical)

        let encoded = try JSONEncoder().encode(bench.makeRestorationState())
        let decoded = try JSONDecoder().decode(EditorRestorationState.self, from: encoded)

        let restored = EditorWorkbench()
        restored.restore(from: decoded)
        guard case .vertical(let restoredData) = restored.layout else {
            return XCTFail("expected the restored layout to still be a top-level .vertical split")
        }
        XCTAssertEqual(restoredData.axis, .vertical)
        XCTAssertEqual(restored.panes.count, 2)
    }

    func testConcurrentPaneSyncDoesNotRaceVersions() async {
        let bridge = PenumbraWorkbenchWorkspaceBridge()
        let bench = EditorWorkbench()
        bench.openDocument(WorkbenchDocument(displayName: "a.swift", text: "a"))
        bench.openDocument(WorkbenchDocument(displayName: "b.swift", text: "b"))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<40 {
                group.addTask {
                    await bridge.syncPane(bench.activePane)
                }
                group.addTask {
                    await bridge.syncWorkbench(bench)
                }
            }
        }
        let open = await bridge.workspace.allOpenDocuments()
        XCTAssertEqual(Set(open.map(\.displayName)), ["a.swift", "b.swift"])
    }
}
