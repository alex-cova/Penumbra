import XCTest
@testable import Umbra

@MainActor
final class IDEExplorerPresentationTests: XCTestCase {
    private func file(_ name: String) -> IDEFileNode {
        IDEFileNode(url: URL(fileURLWithPath: "/p/\(name)"), isDirectory: false)
    }

    private func folder(_ name: String, children: [IDEFileNode] = [], excluded: Bool = false) -> IDEFileNode {
        IDEFileNode(url: URL(fileURLWithPath: "/p/\(name)"), isDirectory: true, children: children, isExcluded: excluded)
    }

    private func names(_ nodes: [IDEFileNode]) -> [String] { nodes.map(\.name) }

    func testSortByNameKeepsFoldersOnTop() {
        let nodes = [file("b.txt"), folder("z"), file("A.java"), folder("a")]
        let ordered = IDEExplorerPresentation.ordered(nodes, options: .init())
        XCTAssertEqual(names(ordered), ["a", "z", "A.java", "b.txt"])
    }

    func testFoldersNotOnTopMixesEntries() {
        let nodes = [file("b.txt"), folder("z"), file("A.java"), folder("a")]
        var options = IDEExplorerPresentation.Options()
        options.foldersOnTop = false
        XCTAssertEqual(names(IDEExplorerPresentation.ordered(nodes, options: options)), ["a", "A.java", "b.txt", "z"])
    }

    func testSortByTypeGroupsByExtensionAndKeepsFoldersByName() {
        let nodes = [file("b.kt"), file("a.xml"), file("c.java"), folder("y"), folder("x"), file("d.java")]
        var options = IDEExplorerPresentation.Options()
        options.sortOrder = .type
        XCTAssertEqual(
            names(IDEExplorerPresentation.ordered(nodes, options: options)),
            ["x", "y", "c.java", "d.java", "b.kt", "a.xml"]
        )
    }

    func testHidingExcludedDropsOnlyExcluded() {
        let nodes = [folder("build", excluded: true), folder("src"), file("a.txt")]
        var options = IDEExplorerPresentation.Options()
        options.showExcluded = false
        XCTAssertEqual(names(IDEExplorerPresentation.ordered(nodes, options: options)), ["src", "a.txt"])
        options.showExcluded = true
        XCTAssertEqual(names(IDEExplorerPresentation.ordered(nodes, options: options)), ["build", "src", "a.txt"])
    }

    func testCompactingMergesSingleChildChain() {
        let leaf = folder("com/example/app", children: [file("com/example/app/Main.java")])
        let middle = folder("com/example", children: [leaf])
        let top = folder("com", children: [middle])
        let result = IDEExplorerPresentation.compacted(top) { $0.children ?? [] }
        XCTAssertEqual(result.id, leaf.id)
        XCTAssertEqual(result.displayName, "com.example.app")
    }

    func testCompactingStopsAtBranchesAndFiles() {
        let branching = folder("com", children: [folder("com/a"), folder("com/b")])
        XCTAssertNil(IDEExplorerPresentation.compacted(branching) { $0.children ?? [] }.displayName)
        let withFile = folder("com", children: [folder("com/a"), file("com/X.java")])
        XCTAssertNil(IDEExplorerPresentation.compacted(withFile) { $0.children ?? [] }.displayName)
    }

    func testBuildOutputIsExcludedOnlyNextToABuildFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".gradle"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertFalse(IDEProjectModel.isExcludedDirectory(name: "build", parentPath: root.path))
        FileManager.default.createFile(atPath: root.appendingPathComponent("build.gradle").path, contents: Data())
        XCTAssertTrue(IDEProjectModel.isExcludedDirectory(name: "build", parentPath: root.path))
        XCTAssertFalse(IDEProjectModel.isExcludedDirectory(name: "src", parentPath: root.path))

        let entries = try XCTUnwrap(IDEProjectModel.visibleEntries(of: root, includingExcluded: true))
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.url.lastPathComponent, $0.isExcluded) })
        XCTAssertEqual(byName["build"], true)
        XCTAssertEqual(byName[".gradle"], true)
        XCTAssertNil(byName[".hidden"])
        let hidden = try XCTUnwrap(IDEProjectModel.visibleEntries(of: root))
        XCTAssertFalse(hidden.contains { $0.url.lastPathComponent == "build" })
    }
}
