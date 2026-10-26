import XCTest
@testable import Umbra

@MainActor
final class IDEJavaPackagesTests: XCTestCase {
    func testCollectsPrefixPackagesDefaultPackageAndDistinctSourceSets() {
        let project = "/proj"
        let main = IDEJavaPackageIndex.SourceRoot(path: "/proj/src/main/java", module: "app.main", isTest: false)
        let tests = IDEJavaPackageIndex.SourceRoot(path: "/proj/src/test/java", module: "app.test", isTest: true)
        XCTAssertNil(IDEJavaPackageIndex.packageEntry(directoryPath: main.path, projectRoot: project, sourceRoot: main))

        let entries = [
            IDEJavaPackageIndex.packageEntry(directoryPath: "/proj/src/main/java/com", projectRoot: project, sourceRoot: main),
            IDEJavaPackageIndex.packageEntry(directoryPath: "/proj/src/main/java/com/example", projectRoot: project, sourceRoot: main),
            IDEJavaPackageIndex.packageEntry(directoryPath: "/proj/src/main/java/com/example/app", projectRoot: project, sourceRoot: main),
            IDEJavaPackageIndex.packageEntry(directoryPath: "/proj/src/test/java/com/example", projectRoot: project, sourceRoot: tests),
            IDEJavaPackageIndex.defaultPackage(sourceRoot: main, projectRoot: project)
        ].compactMap { $0 }

        XCTAssertEqual(entries.map(\.name), ["com", "com.example", "com.example.app", "com.example", ""])
        let sameName = entries.filter { $0.name == "com.example" }
        XCTAssertEqual(sameName.map(\.isTest), [false, true])
        XCTAssertEqual(sameName.map(\.module), ["app.main", "app.test"])
        XCTAssertNotEqual(sameName[0].url, sameName[1].url)
        XCTAssertEqual(entries[4].title, "(default package)")
        XCTAssertEqual(entries[4].relativePath, "src/main/java")

        let index = IDEJavaPackageIndex(entries: entries)
        XCTAssertEqual(index.matching("cea", limit: 10).map(\.entry.name), ["com.example.app"])
        XCTAssertEqual(index.matching("example.app", limit: 10).map(\.entry.name), ["com.example.app"])
        XCTAssertEqual(index.matching("default", limit: 10).map(\.entry.title), ["(default package)"])
        XCTAssertEqual(index.matching("", limit: 2).count, 2)
    }

    func testConventionFindsJavaAndKotlinRootsButNotResources() {
        let main = IDEJavaPackageIndex.conventionalSourceRoot(path: "/proj/src/main/java/com/example", projectRoot: "/proj")
        XCTAssertEqual(main?.path, "/proj/src/main/java")
        XCTAssertEqual(main?.isTest, false)
        XCTAssertEqual(main?.module, "main")

        let tests = IDEJavaPackageIndex.conventionalSourceRoot(path: "/proj/src/test/kotlin", projectRoot: "/proj")
        XCTAssertEqual(tests?.path, "/proj/src/test/kotlin")
        XCTAssertEqual(tests?.isTest, true)

        XCTAssertNil(IDEJavaPackageIndex.conventionalSourceRoot(path: "/proj/src/main/resources/com", projectRoot: "/proj"))
        XCTAssertNil(IDEJavaPackageIndex.conventionalSourceRoot(path: "/proj/README.md", projectRoot: "/proj"))
    }

    func testIndexerRecordsPackagesFromTheSourceLayout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("umbra-packages-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("src/main/java/com/example/app", isDirectory: true)
        let tests = root.appendingPathComponent("src/test/java/com/example", isDirectory: true)
        let resources = root.appendingPathComponent("src/main/resources/com/example", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data().write(to: app.appendingPathComponent("Main.java"))
        try Data().write(to: tests.appendingPathComponent("ExampleTest.java"))
        try Data().write(to: root.appendingPathComponent("src/main/java/Foo.java"))
        try Data().write(to: resources.appendingPathComponent("note.txt"))

        let indexer = IDEPaletteFileIndexer()
        indexer.setRoot(root)
        let deadline = Date().addingTimeInterval(5)
        while indexer.packageIndex.entries.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let names = Set(indexer.packageIndex.entries.map(\.name))
        XCTAssertTrue(names.contains("com"), "a directory with no file of its own is still a package")
        XCTAssertTrue(names.contains("com.example"))
        XCTAssertTrue(names.contains("com.example.app"))
        XCTAssertTrue(names.contains(""))
        let example = indexer.packageIndex.entries.filter { $0.name == "com.example" }
        XCTAssertEqual(Set(example.map(\.isTest)), [true, false])
        XCTAssertFalse(indexer.packageIndex.entries.contains { $0.relativePath.contains("resources") })
    }

    func testBranchedPackageCrumbsCollapseOnlyEmptyMiddleDirectories() {
        let root = URL(fileURLWithPath: "/proj")
        let tree = projectTree(root: "/proj", files: [
            "src/main/java/com/example/app/Main.java",
            "src/main/java/com/example/util/Strings.java"
        ])
        let file = root.appendingPathComponent("src/main/java/com/example/app/Main.java")
        let items = IDEJavaPackages.pathItems(file: file, projectRoot: root, knownSourceRoots: [], tree: tree)
        XCTAssertEqual(items.map(\.title), ["proj", "src", "main", "java", "com.example", "app", "Main.java"])
        XCTAssertEqual(items.map(kind), ["folder", "folder", "folder", "folder", "package", "package", "file"])
    }

    func testSingleChildChainCollapsesToOnePackageCrumb() {
        let root = URL(fileURLWithPath: "/proj")
        let tree = projectTree(root: "/proj", files: [
            "src/main/java/com/example/app/Main.java"
        ])
        let file = root.appendingPathComponent("src/main/java/com/example/app/Main.java")
        let items = IDEJavaPackages.pathItems(file: file, projectRoot: root, knownSourceRoots: [], tree: tree)
        XCTAssertEqual(items.map(\.title), ["proj", "src", "main", "java", "com.example.app", "Main.java"])
        XCTAssertEqual(items.map(kind), ["folder", "folder", "folder", "folder", "package", "file"])
    }

    func testFileOutsideASourceRootKeepsFolderCrumbs() {
        let root = URL(fileURLWithPath: "/proj")
        let tree = projectTree(root: "/proj", files: [
            "src/main/resources/config.txt"
        ])
        let file = root.appendingPathComponent("src/main/resources/config.txt")
        let items = IDEJavaPackages.pathItems(file: file, projectRoot: root, knownSourceRoots: [], tree: tree)
        XCTAssertEqual(items.map(\.title), ["proj", "src", "main", "resources", "config.txt"])
        XCTAssertEqual(items.map(kind), ["folder", "folder", "folder", "folder", "file"])
    }

    private func kind(_ item: IDEBreadcrumbItem) -> String {
        switch item.target {
        case .folder: "folder"
        case .package: "package"
        case .file: "file"
        case .symbol: "symbol"
        }
    }

    private func projectTree(root: String, files: [String]) -> IDEFileNode {
        var children: [IDEFileNode] = []
        for file in files {
            insert(file.split(separator: "/").map(String.init)[...], into: &children, base: root)
        }
        return IDEFileNode(url: URL(fileURLWithPath: root), isDirectory: true, children: children)
    }

    private func insert(_ components: ArraySlice<String>, into children: inout [IDEFileNode], base: String) {
        guard let name = components.first else { return }
        let path = base + "/" + name
        let rest = components.dropFirst()
        if rest.isEmpty {
            children.append(IDEFileNode(url: URL(fileURLWithPath: path), isDirectory: false))
            return
        }
        if let index = children.firstIndex(where: { $0.name == name }) {
            var nested = children[index].children ?? []
            insert(rest, into: &nested, base: path)
            children[index].children = nested
        } else {
            var nested: [IDEFileNode] = []
            insert(rest, into: &nested, base: path)
            children.append(IDEFileNode(url: URL(fileURLWithPath: path), isDirectory: true, children: nested))
        }
    }
}
