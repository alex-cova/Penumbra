import XCTest
@testable import JavaIntelligence

final class SourceRootTests: XCTestCase {
    private func tempProject() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ contents: String, to relativePath: String, under root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func testReadsAllJavaFilesUnderDirectory() throws {
        let root = tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("package com.example;\nclass Foo {}", to: "src/main/java/com/example/Foo.java", under: root)
        try write("package com.example;\nclass Bar {}", to: "src/main/java/com/example/Bar.java", under: root)
        try write("not java", to: "src/main/java/com/example/notes.txt", under: root)

        let sourceRoot = SourceRoot(directory: root)
        let stubs = try sourceRoot.readStubs()
        XCTAssertEqual(Set(stubs.map(\.qualifiedName)), ["com.example.Foo", "com.example.Bar"])
    }

    func testSkipsIgnoredDirectories() throws {
        let root = tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("class Real {}", to: "src/Real.java", under: root)
        try write("class Ignored {}", to: "build/Ignored.java", under: root)
        try write("class AlsoIgnored {}", to: ".git/AlsoIgnored.java", under: root)
        try write("class NodeModule {}", to: "node_modules/NodeModule.java", under: root)

        let sourceRoot = SourceRoot(directory: root)
        let stubs = try sourceRoot.readStubs()
        XCTAssertEqual(stubs.map(\.simpleName), ["Real"])
    }

    func testReadSourceFilesPreservesPerFilePackageAndImports() throws {
        let root = tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("package com.example;\nimport java.util.List;\nclass Foo { List<String> items; }", to: "Foo.java", under: root)

        let sourceRoot = SourceRoot(directory: root)
        let files = sourceRoot.readSourceFiles()
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].packageName, "com.example")
        XCTAssertEqual(files[0].imports.map(\.qualifiedName), ["java.util.List"])
    }

    func testEmptyDirectoryProducesNoStubs() throws {
        let root = tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = SourceRoot(directory: root)
        XCTAssertEqual(try sourceRoot.readStubs(), [])
    }

    func testMultipleTopLevelTypesInOneFile() throws {
        let root = tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("class Public {} class PackagePrivate {}", to: "Public.java", under: root)
        let sourceRoot = SourceRoot(directory: root)
        let stubs = try sourceRoot.readStubs()
        XCTAssertEqual(Set(stubs.map(\.simpleName)), ["Public", "PackagePrivate"])
    }

    func testStampReflectsDirectoryModificationDate() throws {
        // A directory's mtime updates when an entry is added/removed, but the OS may batch that
        // update rather than reflecting it within the same instant a fast unit test can observe,
        // so this checks the stamp matches the directory's real attributes rather than asserting
        // it changes within one test run (the FSEvents watcher, not this coarse stamp, is what
        // actually detects same-second changes in practice -- see the `stamp` doc comment).
        let root = tempProject()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceRoot = SourceRoot(directory: root)
        let expected = try XCTUnwrap((try? root.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
        XCTAssertEqual(sourceRoot.stamp.modificationDate, expected.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertGreaterThan(sourceRoot.stamp.modificationDate, 0)
    }

    func testIDIsDerivedFromDirectoryPath() {
        let root = tempProject()
        let sourceRoot = SourceRoot(directory: root)
        XCTAssertTrue(sourceRoot.id.contains(root.path))
    }
}
