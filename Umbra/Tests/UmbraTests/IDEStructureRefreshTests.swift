import Foundation
import Penumbra
import XCTest
@testable import Umbra

/// The Structure tree is rebuilt only while the Structure tab shows, once typing pauses, and a
/// caret move inside unchanged text reselects a node without building the tree again.
@MainActor
final class IDEStructureRefreshTests: XCTestCase {
    private var directory: URL!
    private var workspace: IDEWorkspace!
    private let source = """
    class Alpha {
        void one() {}
        void two() {}
    }
    """

    override func setUp() async throws {
        IDEWorkspace.isSessionPersistenceEnabled = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("structure-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        workspace = IDEWorkspace()
        workspace.bootstrap()
    }

    override func tearDown() async throws {
        workspace?.windowWillClose()
        workspace = nil
        IDEWorkspace.isSessionPersistenceEnabled = true
        try? FileManager.default.removeItem(at: directory)
    }

    private func eventually(_ message: String, seconds: Double = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail(message)
    }

    private func openJavaFile() async throws -> TextView {
        let url = directory.appendingPathComponent("Alpha.java")
        try source.write(to: url, atomically: true, encoding: .utf8)
        await workspace.openDocument(from: url)
        return workspace.host(for: workspace.workbench.activePaneID).textView
    }

    func testAnEditBuildsNothingWhileTheStructureTabIsHidden() async throws {
        let textView = try await openJavaFile()
        workspace.isSidebarVisible = false
        XCTAssertFalse(workspace.showsStructureSidebar)

        textView.replace(NSRange(location: textView.documentLength, length: 0), withText: "\n// edit")
        workspace.noteStructureEdited()
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertNil(workspace.structureStore.root, "a hidden Structure tab must cost no parse")
    }

    func testShowingTheStructureTabBuildsTheTree() async throws {
        _ = try await openJavaFile()

        workspace.showSidebarTab(.structure)

        await eventually("the Structure tree never appeared") { workspace.structureStore.root != nil }
        XCTAssertEqual(workspace.structureStore.root?.title.contains("Alpha"), true)
    }

    func testACaretMoveInsideUnchangedTextReselectsWithoutRebuilding() async throws {
        let textView = try await openJavaFile()
        workspace.showSidebarTab(.structure)
        await eventually("the Structure tree never appeared") { workspace.structureStore.root != nil }
        let rootBefore = workspace.structureStore.root
        let twoOffset = (source as NSString).range(of: "two").location

        textView.selectedRange = NSRange(location: twoOffset + 1, length: 0)
        workspace.noteStructureCaretMoved(in: textView)

        let selected = workspace.structureStore.selectedID.flatMap { workspace.structureStore.node(withID: $0) }
        XCTAssertEqual(selected?.title.contains("two"), true, "selected \(String(describing: selected?.title))")
        XCTAssertEqual(workspace.structureStore.root?.id, rootBefore?.id)
    }

    func testAnEditRebuildsTheTreeAfterThePause() async throws {
        let textView = try await openJavaFile()
        workspace.showSidebarTab(.structure)
        await eventually("the Structure tree never appeared") { workspace.structureStore.root != nil }

        textView.replace(NSRange(location: (source as NSString).range(of: "}\n}").location + 2, length: 0),
                         withText: "    void three() {}\n")
        workspace.noteStructureEdited()

        await eventually("the new member never showed up", seconds: 8) {
            workspace.structureStore.root?.children.contains { $0.title.contains("three") } == true
        }
    }
}
