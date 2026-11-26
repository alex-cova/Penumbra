import XCTest
@testable import Umbra

/// Flatten Packages shows `com.balatro` and `com.balatro.api` as sibling rows under the
/// source root. Opening a file under `api` must not expand the `com.balatro` row.
@MainActor
final class IDEFlattenedRevealTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("flattened-reveal-\(UUID().uuidString)")
            .standardizedFileURL
        let balatro = created.appendingPathComponent("src/main/java/com/balatro")
        let api = balatro.appendingPathComponent("api")
        try FileManager.default.createDirectory(at: api, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: balatro.appendingPathComponent("Game.java").path, contents: Data())
        FileManager.default.createFile(atPath: api.appendingPathComponent("Api.java").path, contents: Data())
        try Data().write(to: created.appendingPathComponent("README.md"))
        root = created
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func path(_ components: String...) -> String {
        components.reduce(root) { $0.appendingPathComponent($1) }.standardizedFileURL.path
    }

    private func expanded(_ model: IDEProjectModel) -> Set<String> {
        Set(model.expandedPaths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    }

    private func makeModel() -> IDEProjectModel {
        let model = IDEProjectModel()
        model.setRoot(root)
        model.collapseAll()
        return model
    }

    /// The reported scenario uses Flatten Packages, where both packages are top-level rows.
    func testFlattenedTreeListsBothPackagesAsSiblings() {
        let model = makeModel()
        guard let rootNode = model.rootNode else { return XCTFail("no root node") }
        let flattened = IDEFlattenedPackages.flatten(rootNode, sourceRootPaths: [])
        // Walk by name: on-disk spellings (/var vs /private/var) vary, names do not.
        func find(_ node: IDEFileNode, names: [String]) -> IDEFileNode? {
            guard let first = names.first else { return node }
            guard let child = node.children?.first(where: { $0.name == first }) else { return nil }
            return find(child, names: Array(names.dropFirst()))
        }
        guard let flatSource = find(flattened, names: ["src", "main", "java"]) else {
            return XCTFail("no flattened source root")
        }
        let names = Set((flatSource.children ?? []).compactMap(\.displayName))
        XCTAssertTrue(names.contains("com.balatro"), "expected com.balatro in \(names.sorted())")
        XCTAssertTrue(names.contains("com.balatro.api"), "expected com.balatro.api in \(names.sorted())")
    }

    /// Opening a file under `com.balatro.api` expands that package only, not `com.balatro`.
    func testRevealApiFileFlattenedDoesNotExpandParentPackage() {
        let model = makeModel()
        model.reveal(
            url: root.appendingPathComponent("src/main/java/com/balatro/api/Api.java"),
            flattenPackages: true, sourceRootPaths: []
        )
        let paths = expanded(model)
        XCTAssertTrue(paths.contains(path("src", "main", "java")))
        XCTAssertTrue(paths.contains(path("src", "main", "java", "com", "balatro", "api")))
        XCTAssertFalse(
            paths.contains(path("src", "main", "java", "com", "balatro")),
            "flattened sibling package com.balatro must stay closed"
        )
        XCTAssertFalse(
            paths.contains(path("src", "main", "java", "com")),
            "elided intermediate directory com must stay closed"
        )
    }

    /// Same scenario through an explicitly synced source root rather than the convention fallback.
    func testRevealApiFileFlattenedWithExplicitSourceRoot() {
        let model = makeModel()
        model.reveal(
            url: root.appendingPathComponent("src/main/java/com/balatro/api/Api.java"),
            flattenPackages: true, sourceRootPaths: [path("src", "main", "java")]
        )
        let paths = expanded(model)
        XCTAssertTrue(paths.contains(path("src", "main", "java", "com", "balatro", "api")))
        XCTAssertFalse(paths.contains(path("src", "main", "java", "com", "balatro")))
    }

    /// Without flattening the parent package is a real ancestor and must expand.
    func testRevealApiFileHierarchicalExpandsAncestors() {
        let model = makeModel()
        model.reveal(url: root.appendingPathComponent("src/main/java/com/balatro/api/Api.java"))
        let paths = expanded(model)
        XCTAssertTrue(paths.contains(path("src", "main", "java", "com", "balatro")))
        XCTAssertTrue(paths.contains(path("src", "main", "java", "com", "balatro", "api")))
    }

    /// A file directly in `com.balatro` still opens its own package row; the child stays shut.
    func testRevealFileInParentPackageFlattenedExpandsOwnPackageOnly() {
        let model = makeModel()
        model.reveal(
            url: root.appendingPathComponent("src/main/java/com/balatro/Game.java"),
            flattenPackages: true, sourceRootPaths: []
        )
        let paths = expanded(model)
        XCTAssertTrue(paths.contains(path("src", "main", "java", "com", "balatro")))
        XCTAssertFalse(paths.contains(path("src", "main", "java", "com", "balatro", "api")))
    }

    /// Outside any source root there is no flattening, so the full chain expands as before.
    func testRevealFileOutsideSourceRootFlattenedExpandsFullChain() {
        let model = makeModel()
        model.reveal(url: root.appendingPathComponent("README.md"), flattenPackages: true, sourceRootPaths: [])
        XCTAssertTrue(expanded(model).contains(root.path))
    }

    /// Revealing a package directory (Go to Package) opens that row, not its parent package.
    func testRevealPackageDirectoryFlattenedDoesNotExpandParentPackage() {
        let model = makeModel()
        // Use the tree's own URLs: `reveal` looks the target up in the tree, so the
        // on-disk spelling must match (production roots have no symlinks; TMPDIR does).
        func find(_ node: IDEFileNode, names: [String]) -> IDEFileNode? {
            guard let first = names.first else { return node }
            guard let child = node.children?.first(where: { $0.name == first }) else { return nil }
            return find(child, names: Array(names.dropFirst()))
        }
        guard let rootNode = model.rootNode,
              let api = find(rootNode, names: ["src", "main", "java", "com", "balatro", "api"]),
              let balatro = find(rootNode, names: ["src", "main", "java", "com", "balatro"]) else {
            return XCTFail("missing package nodes")
        }
        model.revealAndSelect(url: api.url, centered: true, flattenPackages: true, sourceRootPaths: [])
        let paths = expanded(model)
        XCTAssertTrue(paths.contains(api.url.standardizedFileURL.path))
        XCTAssertFalse(
            paths.contains(balatro.url.standardizedFileURL.path),
            "flattened sibling package com.balatro must stay closed"
        )
        XCTAssertEqual(model.selectedPath, api.url.standardizedFileURL.path)
        XCTAssertNotNil(model.revealRequest)
    }
}
