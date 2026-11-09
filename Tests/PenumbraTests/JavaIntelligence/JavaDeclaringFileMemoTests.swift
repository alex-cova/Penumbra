import XCTest
@testable import JavaIntelligence

/// Member lookup reads the file a source class is declared in (its package and imports) to resolve the
/// names in its signatures, and resolving a simple name can walk the supertypes of the class around it. That
/// read goes through the shared `JavaParseMemo` instead of parsing the file again for every name. These tests
/// hold the memo to being invisible: the same members as a fresh parse, changed text never answered from an
/// older parse, and a bounded number of parses however many names are resolved.
final class JavaDeclaringFileMemoTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("declaring-memo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        JavaParseMemo.shared.removeAll()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
        JavaParseMemo.shared.removeAll()
    }

    private func write(_ name: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func baseSource(listImport: String = "java.util.List", extra: String = "") -> String {
        """
        package p;
        import \(listImport);
        public class Base {
            public static class Entry { public int weight() { return 1; } }
            public List<Entry> entries() { return null; }
            public Entry first() { return null; }
            public Entry second(Entry other) { return null; }
            \(extra)
        }
        """
    }

    private let subSource = """
    package p;
    public class Sub extends Base {
        public Entry mine() { return null; }
    }
    """

    private func makeIndex(_ files: [URL]) async throws -> JavaIndex {
        var stubs: [JavaClassStub] = [
            JavaClassStub(
                binaryName: "java.lang.Object", qualifiedName: "java.lang.Object", simpleName: "Object", packageName: "java.lang",
                kind: .classKind, modifiers: [.publicFlag], origin: .jdkModule("test")
            )
        ]
        for name in ["java.util.List", "java.awt.List"] {
            let simple = String(name.split(separator: ".").last!)
            let package = String(name.dropLast(simple.count + 1))
            stubs.append(JavaClassStub(
                binaryName: name, qualifiedName: name, simpleName: simple, packageName: package,
                kind: .interfaceKind, modifiers: [.publicFlag], origin: .jdkModule("test")
            ))
        }
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            stubs += JavaSourceStubBuilder.build(source: text, url: url).classes
        }
        let shard = directory.appendingPathComponent("\(UUID().uuidString).idx")
        try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: shard)
        let index = JavaIndex()
        await index.setSources([.init(precedence: 3, reader: try JavaIndexShardReader(url: shard))])
        return index
    }

    private func signature(_ members: [JavaResolvedMember]) -> [String] {
        members.map { member in
            switch member {
            case .field(let field, let owner): return "field \(owner).\(field.name): \(field.type)"
            case .method(let method, let owner):
                return "method \(owner).\(method.name)(\(method.parameters.map { "\($0.type)" }.joined(separator: ","))): \(method.returnType)"
            }
        }
    }

    private func members(of type: String, in index: JavaIndex) async -> [String] {
        let context = JavaResolutionContext(packageName: "p", imports: [], enclosingTypeQualifiedNames: [type])
        let result = await JavaMemberLookup.members(
            of: .classType(qualifiedName: type, arguments: [], outer: nil), mode: .instance, context: context, index: index
        )
        return signature(result)
    }

    /// The oracle: what lookup answers with the memo empty (every file parsed fresh) is what it answers
    /// with the memo already holding those files.
    func testMembersAreTheSameWithAnEmptyAndAWarmMemo() async throws {
        let base = try write("Base.java", baseSource())
        let sub = try write("Sub.java", subSource)
        let index = try await makeIndex([base, sub])

        JavaParseMemo.shared.removeAll()
        let fresh = await members(of: "p.Sub", in: index)
        XCTAssertTrue(fresh.contains { $0.contains("method p.Sub.mine") && $0.contains("p.Base.Entry") }, "\(fresh)")
        XCTAssertTrue(fresh.contains { $0.contains("method p.Base.entries") && $0.contains("java.util.List") && $0.contains("p.Base.Entry") }, "\(fresh)")

        await index.replaceOverlay(removing: [], adding: [])   // drops the shared member sets, so the walk runs again
        XCTAssertGreaterThan(JavaParseMemo.shared.entryCount, 0, "the first walk should have left the files in the memo")
        let warm = await members(of: "p.Sub", in: index)
        XCTAssertEqual(warm, fresh)
    }

    /// Several names to resolve in a class and its subclass must not parse the declaring file once per name.
    func testParsesAreBoundedByFilesNotByNames() async throws {
        let base = try write("Base.java", baseSource())
        let sub = try write("Sub.java", subSource)
        let index = try await makeIndex([base, sub])
        JavaParseMemo.shared.removeAll()
        let before = JavaParseMemo.shared.parseCount

        _ = await members(of: "p.Sub", in: index)

        let parses = JavaParseMemo.shared.parseCount - before
        XCTAssertGreaterThan(parses, 0, "the declaring files go through the shared memo")
        XCTAssertLessThanOrEqual(parses, 2, "Base.java and Sub.java, once each (\(parses) parses)")
    }

    /// A file that changed is different bytes, so it is a different entry: lookup must see the new import.
    func testChangedFileTextIsNeverAnsweredFromAnOlderParse() async throws {
        let base = try write("Base.java", baseSource(listImport: "java.util.List"))
        let sub = try write("Sub.java", subSource)
        let index = try await makeIndex([base, sub])
        let before = await members(of: "p.Sub", in: index)
        XCTAssertTrue(before.contains { $0.contains("method p.Base.entries") && $0.contains("java.util.List") }, "\(before)")

        _ = try write("Base.java", baseSource(listImport: "java.awt.List"))
        await index.replaceOverlay(removing: [], adding: [])
        let after = await members(of: "p.Sub", in: index)
        XCTAssertTrue(after.contains { $0.contains("method p.Base.entries") && $0.contains("java.awt.List") }, "\(after)")
        XCTAssertFalse(after.contains { $0.contains("method p.Base.entries") && $0.contains("java.util.List") }, "\(after)")
    }

    /// Evicting everything between two lookups changes nothing but the cost.
    func testEvictionBetweenLookupsDoesNotChangeTheAnswer() async throws {
        let base = try write("Base.java", baseSource())
        let sub = try write("Sub.java", subSource)
        let index = try await makeIndex([base, sub])
        let first = await members(of: "p.Sub", in: index)
        for _ in 0..<3 {
            JavaParseMemo.shared.removeAll()
            await index.replaceOverlay(removing: [], adding: [])
            let again = await members(of: "p.Sub", in: index)
            XCTAssertEqual(again, first)
        }
    }

    /// A file that is gone or empty keeps the old fallback: the class's own package, no imports.
    func testMissingDeclaringFileFallsBackToThePackage() async throws {
        let base = try write("Base.java", baseSource())
        let sub = try write("Sub.java", subSource)
        let index = try await makeIndex([base, sub])
        try FileManager.default.removeItem(at: base)
        let result = await members(of: "p.Sub", in: index)
        XCTAssertTrue(result.contains { $0.contains("method p.Sub.mine") }, "\(result)")
    }

    /// The memo is keyed by bytes: text that Swift calls equal (NFC and NFD) but that is different UTF-8 is two entries.
    func testCanonicallyEquivalentButByteDifferentTextIsKeptApart() throws {
        let memo = JavaParseMemo()
        let composed = "class A { String \u{00E9} = \"x\"; }"
        let decomposed = "class A { String e\u{0301} = \"x\"; }"
        XCTAssertEqual(composed, decomposed, "Swift treats them as equal")
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        let first = try XCTUnwrap(memo.tree(for: composed))
        let second = try XCTUnwrap(memo.tree(for: decomposed))
        XCTAssertFalse(first === second)
        XCTAssertEqual(memo.parseCount, 2)
    }
}
