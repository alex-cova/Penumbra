import XCTest
import EditorIntelligence
@testable import JavaIntelligence

final class JavaOverlayServiceTests: XCTestCase {
    private func makeDocument(text: String, version: Int = 0, url: URL? = nil, language: String? = "java") -> Document {
        let snapshot = TextSnapshot(version: version, text: text)
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            id: DocumentID(),
            url: url ?? URL(fileURLWithPath: "/tmp/Test\(UUID().uuidString).java"),
            displayName: "Test.java",
            contentSnapshot: snapshot,
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: language
        )
    }

    private func waitBriefly() async throws {
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    func testOpeningJavaDocumentPublishesOverlayImmediately() async throws {
        let index = JavaIndex()
        let service = JavaOverlayService(index: index)
        let workspace = Workspace()
        let task = await service.connect(to: workspace)
        defer { task.cancel() }

        let document = makeDocument(text: "package com.example;\nclass Foo { int x; }")
        await workspace.openDocument(document)
        try await waitBriefly()

        let stub = await index.classStub(qualifiedName: "com.example.Foo")
        XCTAssertNotNil(stub)
    }

    func testNonJavaDocumentIsIgnored() async throws {
        let index = JavaIndex()
        let service = JavaOverlayService(index: index)
        let workspace = Workspace()
        let task = await service.connect(to: workspace)
        defer { task.cancel() }

        let document = makeDocument(text: "class Foo {}", language: "swift")
        await workspace.openDocument(document)
        try await waitBriefly()

        let stub = await index.classStub(qualifiedName: "Foo")
        XCTAssertNil(stub)
    }

    func testEditedDocumentUpdatesOverlayAfterDebounce() async throws {
        let index = JavaIndex()
        let service = JavaOverlayService(index: index, debounceMilliseconds: 50)
        let workspace = Workspace()
        let task = await service.connect(to: workspace)
        defer { task.cancel() }

        let opened = makeDocument(text: "class Foo { int a; }", version: 0)
        await workspace.openDocument(opened)
        try await waitBriefly()

        let edited = Document(
            id: opened.id, url: opened.url, displayName: opened.displayName,
            contentSnapshot: TextSnapshot(version: 1, text: "class Foo { int a; int b; }"),
            selection: opened.selection, cursor: opened.cursor, viewport: opened.viewport,
            languageIdentifier: "java"
        )
        await workspace.updateDocument(edited)
        try await Task.sleep(nanoseconds: 250_000_000)

        let stub = await index.classStub(qualifiedName: "Foo")
        XCTAssertEqual(stub?.fields.count, 2)
    }

    func testClosingDocumentRemovesItFromOverlayWithoutAffectingOthers() async throws {
        let index = JavaIndex()
        let service = JavaOverlayService(index: index)
        let workspace = Workspace()
        let task = await service.connect(to: workspace)
        defer { task.cancel() }

        let first = makeDocument(text: "class Foo {}")
        let second = makeDocument(text: "class Bar {}")
        await workspace.openDocument(first)
        await workspace.openDocument(second)
        try await waitBriefly()

        var foo = await index.classStub(qualifiedName: "Foo")
        var bar = await index.classStub(qualifiedName: "Bar")
        XCTAssertNotNil(foo)
        XCTAssertNotNil(bar)

        await workspace.closeDocument(first.id)
        try await waitBriefly()

        foo = await index.classStub(qualifiedName: "Foo")
        bar = await index.classStub(qualifiedName: "Bar")
        XCTAssertNil(foo, "closed document's overlay entries should be removed")
        XCTAssertNotNil(bar, "other open documents' overlay entries should be unaffected")
    }

    func testClosingOneOfTwoDocumentsDefiningSameClassKeepsTheOther() async throws {
        let index = JavaIndex()
        let service = JavaOverlayService(index: index)
        let workspace = Workspace()
        let task = await service.connect(to: workspace)
        defer { task.cancel() }

        let first = makeDocument(text: "package p;\nclass Dup { int a; }")
        let second = makeDocument(text: "package p;\nclass Dup { int a; int b; }")
        await workspace.openDocument(first)
        await workspace.openDocument(second)
        try await waitBriefly()

        await workspace.closeDocument(second.id)
        try await waitBriefly()
        let afterSecondClosed = await index.classStub(qualifiedName: "p.Dup")
        XCTAssertEqual(afterSecondClosed?.fields.count, 1, "the still-open document's definition should remain")

        await workspace.closeDocument(first.id)
        try await waitBriefly()
        let afterBothClosed = await index.classStub(qualifiedName: "p.Dup")
        XCTAssertNil(afterBothClosed)
    }

    func testEditThatRenamesClassRemovesOldName() async throws {
        let index = JavaIndex()
        let service = JavaOverlayService(index: index, debounceMilliseconds: 50)
        let workspace = Workspace()
        let task = await service.connect(to: workspace)
        defer { task.cancel() }

        let opened = makeDocument(text: "class OldName {}", version: 0)
        await workspace.openDocument(opened)
        try await waitBriefly()

        let edited = Document(
            id: opened.id, url: opened.url, displayName: opened.displayName,
            contentSnapshot: TextSnapshot(version: 1, text: "class NewName {}"),
            selection: opened.selection, cursor: opened.cursor, viewport: opened.viewport,
            languageIdentifier: "java"
        )
        await workspace.updateDocument(edited)
        try await Task.sleep(nanoseconds: 250_000_000)

        let oldStub = await index.classStub(qualifiedName: "OldName")
        let newStub = await index.classStub(qualifiedName: "NewName")
        XCTAssertNil(oldStub)
        XCTAssertNotNil(newStub)
    }

    func testFileStubsQueryReturnsPackageAndImports() async throws {
        let index = JavaIndex()
        let service = JavaOverlayService(index: index)
        let workspace = Workspace()
        let task = await service.connect(to: workspace)
        defer { task.cancel() }

        let document = makeDocument(text: "package com.example;\nimport java.util.List;\nclass Foo {}")
        await workspace.openDocument(document)
        try await waitBriefly()

        let fileStubs = await service.fileStubs(for: document.id)
        XCTAssertEqual(fileStubs?.packageName, "com.example")
        XCTAssertEqual(fileStubs?.imports.map(\.qualifiedName), ["java.util.List"])
    }

    func testOverlayShadowsSourceRootDefinitionOfSameClass() async throws {
        let jdkStub = JavaClassStub(
            binaryName: "com.example.Foo", qualifiedName: "com.example.Foo", simpleName: "Foo", packageName: "com.example",
            kind: .classKind, modifiers: [.publicFlag], origin: .jdkModule("test")
        )
        let shardURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).idx")
        defer { try? FileManager.default.removeItem(at: shardURL) }
        try JavaIndexShardWriter().write([jdkStub], stamp: JavaStamp(size: 0, modificationDate: 0), to: shardURL)
        let reader = try JavaIndexShardReader(url: shardURL)

        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: reader)])
        let service = JavaOverlayService(index: index)
        let workspace = Workspace()
        let task = await service.connect(to: workspace)
        defer { task.cancel() }

        let document = makeDocument(text: "package com.example;\nclass Foo { int liveEdit; }")
        await workspace.openDocument(document)
        try await Task.sleep(nanoseconds: 200_000_000)

        let stub = await index.classStub(qualifiedName: "com.example.Foo")
        XCTAssertTrue(stub?.fields.contains { $0.name == "liveEdit" } == true, "the live overlay should shadow the on-disk shard")
    }
}
