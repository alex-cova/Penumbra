import XCTest
import EditorIntelligence
@testable import JavaIntelligence

final class JavaHoverProviderTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("java-hover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private let list = """
    /**
     * A list of things.
     * @param <T> the element type
     */
    public class Things<T> {
        /** How many things there are. */
        public int count;

        /**
         * Adds {@code item} to the list.
         * @param item what to add
         * @return {@code true} if added
         */
        public boolean add(String item) { return true; }

        public void undocumented() {}
    }
    """

    // MARK: - Project sources

    func testHoverOnAMethodCallShowsSignatureAndJavadoc() async throws {
        let things = try write("Things.java", list)
        let result = try await hover("class T { boolean m(Things<String> t) { return t.€add(\"x\"); } }", indexing: [things])
        let contents = try XCTUnwrap(result).contents
        XCTAssertTrue(contents.contains("```java\npublic boolean add(String item)\n```"), contents)
        XCTAssertTrue(contents.contains("*Things*"), contents)
        XCTAssertTrue(contents.contains("Adds `item` to the list."), contents)
        XCTAssertTrue(contents.contains("- `item` — what to add"), contents)
        XCTAssertTrue(contents.contains("**Returns** `true` if added"), contents)
    }

    func testHoverOnATypeAndAFieldShowsTheirDocs() async throws {
        let things = try write("Things.java", list)
        let type = try await hover("class T { €Things<String> t; }", indexing: [things])
        XCTAssertTrue(try XCTUnwrap(type).contents.contains("public class Things<T>"))
        XCTAssertTrue(try XCTUnwrap(type).contents.contains("A list of things."))

        let field = try await hover("class T { int m(Things<String> t) { return t.€count; } }", indexing: [things])
        XCTAssertTrue(try XCTUnwrap(field).contents.contains("public int count"))
        XCTAssertTrue(try XCTUnwrap(field).contents.contains("How many things there are."))
    }

    func testHoverOnADeclarationShowsItsOwnDocs() async throws {
        let things = try write("Things.java", list)
        let result = try await hover(list.replacingOccurrences(of: "boolean add", with: "boolean €add"), url: things.url, indexing: [things])
        XCTAssertTrue(try XCTUnwrap(result).contents.contains("Adds `item` to the list."))
    }

    func testHoverRangeCoversTheIdentifier() async throws {
        let things = try write("Things.java", list)
        let source = "class T { boolean m(Things<String> t) { return t.add(\"x\"); } }"
        let result = try await hover(source.replacingOccurrences(of: "t.add", with: "t.€add"), indexing: [things])
        let range = try XCTUnwrap(try XCTUnwrap(result).range)
        let ns = source as NSString
        XCTAssertEqual(ns.substring(with: NSRange(location: range.start.utf16Offset, length: range.end.utf16Offset - range.start.utf16Offset)), "add")
    }

    // MARK: - Idle versus manual

    func testIdleHoverStaysQuietWithoutDocumentationButManualShowsTheSignature() async throws {
        let things = try write("Things.java", list)
        let marked = "class T { void m(Things<String> t) { t.€undocumented(); } }"
        let idle = try await hover(marked, indexing: [things], trigger: .idle)
        XCTAssertNil(idle)
        let manual = try await hover(marked, indexing: [things], trigger: .manual)
        XCTAssertTrue(try XCTUnwrap(manual).contents.contains("public void undocumented()"))
    }

    func testIdleHoverShowsWhenThereIsDocumentation() async throws {
        let things = try write("Things.java", list)
        let idle = try await hover("class T { void m(Things<String> t) { t.€add(null); } }", indexing: [things], trigger: .idle)
        XCTAssertNotNil(idle)
    }

    func testNothingUnderTheCaretOrANonJavaFileGivesNoHover() async throws {
        let things = try write("Things.java", list)
        let blank = try await hover("class T {€ }", indexing: [things])
        XCTAssertNil(blank)
        let other = try await hover("class T { Things<String> t; €}", indexing: [things], language: "swift")
        XCTAssertNil(other)
    }

    func testLocalVariableShowsItsDeclarationOnAManualRequest() async throws {
        let things = try write("Things.java", list)
        let result = try await hover("class T { void m() { Things<String> mine = null; mi€ne.toString(); } }", indexing: [things], trigger: .manual)
        XCTAssertTrue(try XCTUnwrap(result).contents.contains("Things<String> mine = null;"))
    }

    // MARK: - Attached sources

    func testJDKMethodGetsItsJavadocFromSrcZip() async throws {
        let jdk = scratch.appendingPathComponent("jdk", isDirectory: true)
        let sourceDir = jdk.appendingPathComponent("java.base/java/lang", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let source = """
        package java.lang;
        /** Character strings. */
        public final class String {
            /**
             * Returns the length of this string.
             * @return the number of {@code char}s
             */
            public int length() { return 0; }
        }
        """
        try source.write(to: sourceDir.appendingPathComponent("String.java"), atomically: true, encoding: .utf8)
        let srcZip = jdk.appendingPathComponent("lib/src.zip")
        try FileManager.default.createDirectory(at: srcZip.deletingLastPathComponent(), withIntermediateDirectories: true)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = jdk
        zip.arguments = ["-qr", srcZip.path, "java.base"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)

        // The indexed stub comes from a class file: no Javadoc on it.
        let stringStub = JavaClassStub(
            binaryName: "java.lang.String", qualifiedName: "java.lang.String", simpleName: "String", packageName: "java.lang",
            kind: .classKind, modifiers: [.publicFlag, .finalFlag],
            methods: [JavaMethodStub(name: "length", parameters: [], returnType: .primitive(.int), modifiers: [.publicFlag])],
            origin: .jdkModule("java.base")
        )
        let provider = try await makeProvider(stubs: [stringStub])
        await provider.setJDKHome(jdk)

        let result = try await hover("class T { void m(String s) { int n = s.€length(); } }", provider: provider, trigger: .idle)
        let contents = try XCTUnwrap(result).contents
        XCTAssertTrue(contents.contains("public int length()"), contents)
        XCTAssertTrue(contents.contains("Returns the length of this string."), contents)
        XCTAssertTrue(contents.contains("**Returns** the number of `char`s"), contents)
    }

    func testJarWithoutSourcesShowsTheSignatureAndNeverDecompiles() async throws {
        let jar = scratch.appendingPathComponent("lib.jar")
        FileManager.default.createFile(atPath: jar.path, contents: Data())
        let stub = JavaClassStub(
            binaryName: "Lib", qualifiedName: "Lib", simpleName: "Lib", packageName: "",
            kind: .classKind, modifiers: [.publicFlag],
            methods: [JavaMethodStub(name: "go", parameters: [], returnType: .void, modifiers: [.publicFlag])],
            origin: .jar(jar)
        )
        let provider = try await makeProvider(stubs: [stub])
        let manual = try await hover("class T { void m(Lib l) { l.€go(); } }", provider: provider, trigger: .manual)
        XCTAssertTrue(try XCTUnwrap(manual).contents.contains("public void go()"))
        let idle = try await hover("class T { void m(Lib l) { l.€go(); } }", provider: provider, trigger: .idle)
        XCTAssertNil(idle)
    }

    // MARK: - Helpers

    private struct Fixture {
        let url: URL
        let source: String
    }

    private func write(_ name: String, _ source: String) throws -> Fixture {
        let url = scratch.appendingPathComponent(name)
        try source.write(to: url, atomically: true, encoding: .utf8)
        return Fixture(url: url, source: source)
    }

    private func makeProvider(stubs: [JavaClassStub]) async throws -> JavaHoverProvider {
        let shard = scratch.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 1, reader: try JavaIndexShardReader(url: shard))])
        return JavaHoverProvider(index: index, indexPaths: JavaIndexPaths(root: scratch.appendingPathComponent("cache", isDirectory: true)))
    }

    private func hover(
        _ marked: String, url: URL? = nil, indexing files: [Fixture], language: String = "java", trigger: RequestTrigger = .manual
    ) async throws -> HoverResult? {
        let stubs = files.flatMap { JavaSourceStubBuilder.build(source: $0.source, url: $0.url).classes }
        let provider = try await makeProvider(stubs: stubs)
        return try await hover(marked, url: url, provider: provider, language: language, trigger: trigger)
    }

    private func hover(
        _ marked: String, url: URL? = nil, provider: JavaHoverProvider, language: String = "java", trigger: RequestTrigger
    ) async throws -> HoverResult? {
        let marker = try XCTUnwrap(marked.range(of: "€"))
        let source = marked.replacingOccurrences(of: "€", with: "")
        let utf16 = marked.utf16.distance(from: marked.utf16.startIndex, to: marker.lowerBound.samePosition(in: marked.utf16)!)
        let position = JavaNavigationText.position(utf16Offset: utf16, in: source)
        let fileURL = url ?? scratch.appendingPathComponent("T.java")
        let document = Document(
            url: fileURL, displayName: fileURL.lastPathComponent,
            contentSnapshot: TextSnapshot(version: 0, text: source),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: language
        )
        return await provider.provide(context: HoverContext(
            document: document, cursor: document.cursor, selection: document.selection, trigger: trigger
        ))
    }
}
