import XCTest
import EditorIntelligence
@testable import JavaIntelligence

/// End-to-end Java completion against the real JDK (skipped without a JDK that has `ct.sym`):
/// stream chains with method references, collectors, `var`, and lambda parameters, with the
/// project's own classes declared in another file on disk.
final class JavaCompletionProviderRealJDKTests: XCTestCase {
    private static let support = """
    package com.acme;
    import java.util.List;
    import java.util.UUID;
    class StockSet { UUID getUuid() { return null; } }
    class StockBatchSet { List<StockSet> getOperations() { return null; } }
    class ProductMap { }
    """

    private static let head = """
    package com.acme;

    import java.util.Set;
    import java.util.UUID;
    import java.util.stream.Collectors;

    interface Checker {
        default void checkProductExists(StockBatchSet batch, ProductMap productMap) {
            if (productMap == null) return;

            var products = batch.getOperations()
                    .stream()
                    .map(StockSet::getUuid)
                    .collect(Collectors.toSet());

    """

    private static let tail = """

            checkProductExists(products, productMap);
        }
        void checkProductExists(Set<UUID> ids, ProductMap productMap);
    }
    """

    private func makeIndex(support: String = JavaCompletionProviderRealJDKTests.support) async throws -> JavaIndex {
        guard let found = TestJDK.discovered, let installation = ReleaseFileParser.parse(found.home), installation.hasCtSym else {
            throw XCTSkip("No JDK with ct.sym found on this machine")
        }
        let shard = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(try JDKCtSymRoot(installation: installation).readStubs(), stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: try JavaIndexShardReader(url: shard))])

        // Declared in another file, as in a real project: its member types must resolve against
        // that file's imports (`List`), not the completing file's.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("acme-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let supportURL = directory.appendingPathComponent("Support.java")
        try support.write(to: supportURL, atomically: true, encoding: .utf8)
        let stubs = JavaSourceStubBuilder.build(source: support, url: supportURL).classes
        await index.setOverlay(Dictionary(uniqueKeysWithValues: stubs.map { ($0.qualifiedName, $0) }))
        return index
    }

    private func complete(line: String, index: JavaIndex) async -> [CompletionItem] {
        await complete(before: Self.head + "        " + line, after: Self.tail, index: index)
    }

    private func complete(before: String, after: String, index: JavaIndex) async -> [CompletionItem] {
        let text = before + after
        let lines = before.components(separatedBy: "\n")
        let position = TextPosition(line: lines.count - 1, column: (lines.last ?? "").utf16.count, utf16Offset: (before as NSString).length)
        let document = Document(
            id: DocumentID(), url: URL(fileURLWithPath: "/tmp/acme/Checker.java"), displayName: "Checker.java",
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
        )
        return await JavaCompletionProvider(index: index).provide(context: makeCompletionContext(document: document, trigger: .keystroke(".")))
    }

    func testVarFromStreamCollectOffersSetMembersWithElementType() async throws {
        let index = try await makeIndex()
        let items = await complete(line: "products.", index: index)
        let names = Set(items.map(\.label))
        XCTAssertTrue(names.isSuperset(of: ["size", "contains", "stream", "iterator"]))
        // `Collectors.toSet()` is typed from `collect`'s parameter, so the element type is UUID.
        XCTAssertEqual(items.first { $0.label == "iterator" }?.detail, "Iterator<UUID>")
    }

    /// The shapes of a real project: interfaces inheriting the getter from a super-interface, a
    /// wildcard `List<? extends StockSet>`, several methods before the caret, completion typed on
    /// a blank line before the next statement.
    func testInterfaceHierarchyAndWildcardInMultiMethodFile() async throws {
        let index = try await makeIndex(support: """
        package com.acme.domain;
        import java.util.List;
        interface Identity { String getUuid(); }
        public interface StockOperation extends Identity { }
        public interface StockSet extends StockOperation,
                Comparable<StockSet> { }
        public interface StockBatchSet { List<? extends StockSet> getOperations(); }
        public class ProductMap { }
        """)
        let before = """
        package com.acme.app;

        import com.acme.domain.ProductMap;
        import com.acme.domain.StockBatchSet;
        import com.acme.domain.StockSet;
        import java.util.Set;
        import java.util.stream.Collectors;

        public interface Helper {
            default ProductMap load(StockBatchSet bulk) {
                var uuids = bulk.getOperations().stream().map(StockSet::getUuid).collect(Collectors.toSet());
                try {
                    return null;
                } catch (Exception ex) {
                    return null;
                }
            }

            default void check(StockBatchSet batch, ProductMap productMap) {
                var products = batch.getOperations()
                        .stream()
                        .map(StockSet::getUuid)
                        .collect(Collectors.toSet());

                products.
        """
        let after = """

                check(products, productMap);
            }

            default void check(Set<String> ids, ProductMap productMap) { }
        }
        """
        let items = await complete(before: before, after: after, index: index)
        XCTAssertTrue(items.contains { $0.label == "contains" })
        XCTAssertEqual(items.first { $0.label == "iterator" }?.detail, "Iterator<String>")
    }

    func testImplicitLambdaParameterIsTypedFromTheCall() async throws {
        let index = try await makeIndex()
        let items = await complete(line: "batch.getOperations().forEach(op -> op.", index: index)
        XCTAssertTrue(items.contains { $0.label == "getUuid" })
    }

    func testMethodReferenceBindsStreamElementType() async throws {
        let index = try await makeIndex()
        let items = await complete(line: "batch.getOperations().stream().map(StockSet::getUuid).findFirst().get().", index: index)
        XCTAssertTrue(items.contains { $0.label == "getMostSignificantBits" }, "UUID members")
    }
}
