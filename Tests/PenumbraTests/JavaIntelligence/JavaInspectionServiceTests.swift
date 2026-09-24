import EditorIntelligence
import XCTest
@testable import JavaIntelligence

final class JavaInspectionServiceTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("java-inspections-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func makeIndex(stubs: [JavaClassStub] = []) async throws -> JavaIndex {
        let shard = scratch.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: shard))])
        return index
    }

    private func document(_ source: String, url: URL = URL(fileURLWithPath: "/proj/T.java")) -> Document {
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            url: url, displayName: url.lastPathComponent,
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
    }

    func testUnusedImportInspectionFlagsRemovableImports() {
        let source = """
        import java.util.List;
        import java.util.Map;

        class T { List<String> names; }
        """
        let inspections = JavaUnusedImportInspection.inspect(source: source)
        XCTAssertEqual(inspections.map(\.id), ["unused-import"])
        XCTAssertEqual(inspections.first?.message, "Unused import 'java.util.Map'")
    }

    func testMissingOverrideInspectionFlagsOverridingMethodsWithoutAnnotation() async throws {
        let baseURL = scratch.appendingPathComponent("Base.java")
        try "class Base { void run() { } }".write(to: baseURL, atomically: true, encoding: .utf8)
        let childURL = scratch.appendingPathComponent("Child.java")
        let source = "class Child extends Base { void run() { } }"
        try source.write(to: childURL, atomically: true, encoding: .utf8)
        var stubs: [JavaClassStub] = []
        stubs.append(contentsOf: JavaSourceStubBuilder.build(source: try String(contentsOf: baseURL), url: baseURL).classes)
        stubs.append(contentsOf: JavaSourceStubBuilder.build(source: source, url: childURL).classes)
        let index = try await makeIndex(stubs: stubs)
        let inspections = await JavaMissingOverrideInspection.inspect(source: source, url: childURL, index: index)
        XCTAssertEqual(inspections.map(\.id), ["missing-override"])
        XCTAssertEqual(inspections.first?.fixTitle, "Add @Override")
    }

    func testUnresolvedTypeInspectionWarnsWhenNoCandidateExists() async throws {
        let index = try await makeIndex()
        let source = "class T { UnknownType value; }"
        let tree = try XCTUnwrap(JavaSyntaxParser().parse(source))
        let walker = JavaSemanticWalker(tree: tree, source: source)
        let inspections = await JavaUnresolvedTypeInspection.inspect(
            source: source,
            url: scratch.appendingPathComponent("T.java"),
            index: index,
            walker: walker
        )
        XCTAssertEqual(inspections.map(\.id), ["unresolved-type"])
        XCTAssertEqual(inspections.first?.message, "Cannot resolve type 'UnknownType'")
    }

    func testInspectionServiceAnalyzeNowPublishesDiagnostics() async throws {
        let index = try await makeIndex()
        let service = JavaInspectionService(index: index, idleDelay: .milliseconds(10))
        let url = scratch.appendingPathComponent("T.java")
        let source = """
        import java.util.Map;

        class T { int x; }
        """
        let box = ResultBox()
        await service.setResultHandler { url, diagnostics in box.append(url, diagnostics) }
        await service.analyzeNow(document(source, url: url), force: true)
        let diagnostics = box.results.last?.1 ?? []
        XCTAssertEqual(diagnostics.map(\.code), ["unused-import"])
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(URL, [Diagnostic])] = []
    func append(_ url: URL, _ diagnostics: [Diagnostic]) { lock.lock(); stored.append((url, diagnostics)); lock.unlock() }
    var results: [(URL, [Diagnostic])] { lock.lock(); defer { lock.unlock() }; return stored }
}
