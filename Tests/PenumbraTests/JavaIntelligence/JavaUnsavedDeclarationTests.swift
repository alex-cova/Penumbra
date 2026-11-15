import EditorIntelligence
import XCTest
@testable import JavaIntelligence

/// Declarations typed (unsaved) in one open buffer reach the overlay; another open file's result
/// that depended on them must not outlive the change. Body edits must not re-judge anything.
final class JavaUnsavedDeclarationTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("java-unsaved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func stubs(_ source: String, file: String) -> [JavaClassStub] {
        JavaSourceStubBuilder.build(source: source, url: scratch.appendingPathComponent(file)).classes
    }

    private func platformIndex() async throws -> JavaIndex {
        let url = scratch.appendingPathComponent("jdk.idx")
        let platform = stubs("package java.lang; public class Object { }", file: "Object.java")
            + stubs("package java.lang; public final class String { }", file: "String.java")
        try JavaIndexShardWriter().write(platform, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: try JavaIndexShardReader(url: url))])
        return index
    }

    private func document(_ text: String, _ name: String) -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let url = scratch.appendingPathComponent(name)
        return Document(
            url: url, displayName: name, contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
        )
    }

    private func messages(_ service: JavaInspectionService, _ doc: Document) async -> [String] {
        await service.diagnostics(for: doc).map(\.message).sorted()
    }

    /// `Widget` is typed into another open buffer, unsaved. `User.java`'s result must be re-judged:
    /// the type now exists. Closing that buffer without saving makes it missing again.
    func testAnUnsavedDeclarationInAnotherBufferRejudgesOpenFiles() async throws {
        let index = try await platformIndex()
        let service = JavaInspectionService(index: index, enabledRules: [.unresolvedType], idleDelay: .zero)
        let user = document("package app;\nclass User { Widget w; String s; }", "User.java")
        await service.analyzeNow(user)
        var found = await messages(service, user)
        XCTAssertEqual(found, ["Cannot resolve type 'Widget'"])

        let widget = stubs("package app;\npublic class Widget { }", file: "Widget.java")
        await index.replaceOverlay(removing: [], adding: widget)          // the other tab, unsaved
        let fresh = await service.isFresh(user)
        XCTAssertFalse(fresh, "a declaration appeared in an open buffer")
        await service.refreshAfterIndexChange([user])
        await service.settle()
        found = await messages(service, user)
        XCTAssertEqual(found, [])

        await index.replaceOverlay(removing: Set(widget.map(\.qualifiedName)), adding: [])   // closed, never saved
        await service.refreshAfterIndexChange([user])
        await service.settle()
        found = await messages(service, user)
        XCTAssertEqual(found, ["Cannot resolve type 'Widget'"])
    }

    /// Typing inside a method body rebuilds the buffer's overlay with the same declarations: no
    /// other open file is re-judged.
    func testABodyEditDoesNotRejudgeOtherFiles() async throws {
        let index = try await platformIndex()
        let service = JavaInspectionService(index: index, enabledRules: [.unresolvedType], idleDelay: .zero)
        let widgetV1 = stubs("package app;\npublic class Widget { void run() { int a = 1; } }", file: "Widget.java")
        await index.replaceOverlay(removing: [], adding: widgetV1)
        let user = document("package app;\nclass User { Widget w; }", "User.java")
        await service.analyzeNow(user)
        let before = await service.completedPasses
        let widgetV2 = stubs("package app;\n\npublic class Widget { void run() { int a = 1; int b = a * 2; } }", file: "Widget.java")
        await index.replaceOverlay(removing: [], adding: widgetV2)
        let fresh = await service.isFresh(user)
        XCTAssertTrue(fresh, "only the body (and a range) moved")
        await service.refreshAfterIndexChange([user])
        await service.settle()
        let after = await service.completedPasses
        XCTAssertEqual(after, before)
    }

    /// Saving: the disk shard now has `Widget` too, the overlay still has it. One class, not two.
    func testSavingDoesNotDuplicateTheSymbol() async throws {
        let index = try await platformIndex()
        let widget = stubs("package app;\npublic class Widget { }", file: "Widget.java")
        await index.replaceOverlay(removing: [], adding: widget)
        let url = scratch.appendingPathComponent("project.idx")
        try JavaIndexShardWriter().write(widget, stamp: JavaStamp(size: 1, modificationDate: 1), to: url)
        let platform = scratch.appendingPathComponent("jdk.idx")
        await index.setSources([
            .init(precedence: 3, reader: try JavaIndexShardReader(url: platform)),
            .init(precedence: 1, reader: try JavaIndexShardReader(url: url)),
        ])
        let found = await index.classes(simpleName: "Widget")
        XCTAssertEqual(found.map(\.qualifiedName), ["app.Widget"])
    }
}
