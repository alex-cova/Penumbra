import XCTest
import EditorIntelligence
@testable import JavaIntelligence

/// F18: what the project uses nudges the ranking. The tier still dominates; a count moves a class
/// only within a tier and a scope bucket, and without counts nothing changes.
final class JavaCompletionUsageStatisticsTests: XCTestCase {
    private struct FakeStatistics: JavaUsageStatisticsSource {
        let counts: [String: Int]
        func fileCounts(ofIdentifiers identifiers: [String]) async -> [String: Int] {
            counts.filter { identifiers.contains($0.key) }
        }
    }

    private let fileURL = URL(fileURLWithPath: "/tmp/penumbra-tests/Foo.java")

    private func ref(_ name: String) -> JavaTypeRef { .classType(qualifiedName: name, arguments: [], outer: nil) }

    private func stub(
        _ qualifiedName: String, kind: JavaTypeKind = .classKind, interfaces: [String] = [], superclass: String? = nil,
        modifiers: JavaModifiers = [.publicFlag], source: Bool = false
    ) -> JavaClassStub {
        let simple = String(qualifiedName.split(separator: ".").last!)
        let package = qualifiedName.split(separator: ".").dropLast().joined(separator: ".")
        return JavaClassStub(
            binaryName: qualifiedName, qualifiedName: qualifiedName, simpleName: simple, packageName: package, kind: kind,
            modifiers: modifiers, superclass: superclass.map(ref), interfaces: interfaces.map(ref),
            origin: source ? .source(fileURL, nameRange: 0..<0) : .jdkModule("test")
        )
    }

    private func makeIndex(jdk: [JavaClassStub], project: [JavaClassStub] = []) async throws -> JavaIndex {
        func shard(_ stubs: [JavaClassStub]) throws -> JavaIndexShardReader {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).idx")
            try JavaIndexShardWriter().write(stubs, stamp: JavaStamp(size: 0, modificationDate: 0), to: url)
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            return try JavaIndexShardReader(url: url)
        }
        let index = JavaIndex()
        var sources = [JavaIndex.Source(precedence: 3, reader: try shard(jdk))]
        if !project.isEmpty { sources.append(JavaIndex.Source(precedence: 1, reader: try shard(project))) }
        await index.setSources(sources)
        return index
    }

    private func context(_ source: String) -> CompletionContext {
        let marker = source.range(of: "€")!
        let text = source.replacingOccurrences(of: "€", with: "")
        let offset = source.utf16.distance(from: source.utf16.startIndex, to: marker.lowerBound.samePosition(in: source.utf16)!)
        let lines = String(text.utf16.prefix(offset))!.components(separatedBy: "\n")
        let position = TextPosition(line: lines.count - 1, column: (lines.last ?? "").utf16.count, utf16Offset: offset)
        let document = Document(
            id: DocumentID(), url: fileURL, displayName: "Foo.java", contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
        )
        return makeCompletionContext(document: document, trigger: .manual)
    }

    private func ranking(
        _ source: String, index: JavaIndex, counts: [String: Int]?, prefix: String = ""
    ) async -> [String] {
        let provider = JavaCompletionProvider(index: index)
        if let counts { await provider.setUsageStatistics(FakeStatistics(counts: counts)) }
        let items = await provider.provide(context: context(source))
        return DefaultRanker().rankSynchronously(items: items, prefix: prefix).map(\.item.label)
    }

    // MARK: - new

    private let listImplementations = [
        "java.util.List", "java.util.ArrayList", "java.util.LinkedList", "java.util.Vector",
    ]

    private func jdkLists() -> [JavaClassStub] {
        [stub("java.util.List", kind: .interfaceKind, modifiers: [.publicFlag, .abstractFlag])]
            + ["ArrayList", "LinkedList", "Vector"].map { stub("java.util.\($0)", interfaces: ["java.util.List"]) }
    }

    private let newList = "import java.util.*;\nclass Foo { void m() { List x = new €; } }"

    func testWithoutStatisticsTheConventionalImplementationLeads() async throws {
        let index = try await makeIndex(jdk: jdkLists())
        let order = await ranking(newList, index: index, counts: nil)
        XCTAssertEqual(order.first, "ArrayList", "\(order)")
    }

    func testTheProjectsMostUsedImplementationOutranksTheJDKDefault() async throws {
        let index = try await makeIndex(jdk: jdkLists())
        let order = await ranking(newList, index: index, counts: ["LinkedList": 12, "ArrayList": 3])
        XCTAssertEqual(order.first, "LinkedList", "\(order)")
    }

    func testTheDefaultStaysWhenTheProjectUsesItMore() async throws {
        let index = try await makeIndex(jdk: jdkLists())
        let order = await ranking(newList, index: index, counts: ["LinkedList": 3, "ArrayList": 12])
        XCTAssertEqual(order.first, "ArrayList", "\(order)")
    }

    /// One file mentioning `LinkedList` is not a habit.
    func testASingleMentionDoesNotUnseatTheDefault() async throws {
        let index = try await makeIndex(jdk: jdkLists())
        let order = await ranking(newList, index: index, counts: ["LinkedList": 1])
        XCTAssertEqual(order.first, "ArrayList", "\(order)")
    }

    func testStatisticsForOtherNamesChangeNothing() async throws {
        let index = try await makeIndex(jdk: jdkLists())
        let plain = await ranking(newList, index: index, counts: nil)
        let unrelated = await ranking(newList, index: index, counts: ["Banana": 500])
        XCTAssertEqual(plain, unrelated)
    }

    /// The project's own implementation of its own interface, with no JDK stand-in involved.
    func testAProjectInterfaceGetsItsMostUsedImplementation() async throws {
        let project = [
            stub("app.Repo", kind: .interfaceKind, modifiers: [.publicFlag, .abstractFlag], source: true),
            stub("app.MemoryRepo", interfaces: ["app.Repo"], source: true),
            stub("app.SqlRepo", interfaces: ["app.Repo"], source: true),
        ]
        let index = try await makeIndex(jdk: [], project: project)
        let source = "package app;\nclass Foo { void m() { Repo r = new €; } }"
        // `SqlRepo` is the shorter name and ranks first by default; the project uses `MemoryRepo`.
        let plain = await ranking(source, index: index, counts: nil)
        XCTAssertEqual(plain.first, "SqlRepo", "\(plain)")
        // Each class mentions itself once, which says nothing; five files use MemoryRepo.
        let used = await ranking(source, index: index, counts: ["MemoryRepo": 6, "SqlRepo": 1])
        XCTAssertEqual(used.first, "MemoryRepo", "\(used)")
    }

    /// The whole chain on disk: project files, the name index built over them, the provider using it.
    func testARealNameIndexOverProjectFilesDecidesTheLeadingImplementation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)").standardizedFileURL
        defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        // The project reaches for LinkedList (a work queue, in four files) and uses ArrayList once.
        for number in 0..<4 {
            try "import java.util.LinkedList; class Worker\(number) { LinkedList<String> queue = new LinkedList<>(); }"
                .write(to: src.appendingPathComponent("Worker\(number).java"), atomically: true, encoding: .utf8)
        }
        try "import java.util.ArrayList; class Report { ArrayList<String> rows; }"
            .write(to: src.appendingPathComponent("Report.java"), atomically: true, encoding: .utf8)

        let names = JavaNameIndex(paths: JavaIndexPaths(root: root.appendingPathComponent("cache")))
        for await _ in await names.build(roots: [src]) {}

        let index = try await makeIndex(jdk: jdkLists())
        let provider = JavaCompletionProvider(index: index)
        let before = DefaultRanker().rankSynchronously(items: await provider.provide(context: context(newList)), prefix: "").map(\.item.label)
        XCTAssertEqual(before.first, "ArrayList", "\(before)")
        await provider.setUsageStatistics(names)
        let after = DefaultRanker().rankSynchronously(items: await provider.provide(context: context(newList)), prefix: "").map(\.item.label)
        XCTAssertEqual(after.first, "LinkedList", "\(after)")
    }

    // MARK: - Class names

    func testWithinATierAMoreUsedClassLeads() async throws {
        let index = try await makeIndex(jdk: [stub("a.Linker"), stub("b.Lister")])
        let source = "class Foo { void m() { Li€ } }"
        let plain = await ranking(source, index: index, counts: nil, prefix: "Li")
        let used = await ranking(source, index: index, counts: ["Lister": 20], prefix: "Li")
        XCTAssertEqual(Set(plain.prefix(2)), ["Linker", "Lister"])
        XCTAssertEqual(used.first, "Lister", "\(used)")
    }

    /// The tier is worth 100 points; popularity is worth a few.
    func testPopularityNeverBeatsAMatchTier() async throws {
        let index = try await makeIndex(jdk: [stub("a.ListOfThings"), stub("b.GenericList")])
        let source = "class Foo { void m() { Lis€ } }"
        // `ListOfThings` is a prefix match, `GenericList` a later word start.
        let order = await ranking(source, index: index, counts: ["GenericList": 5000], prefix: "Lis")
        XCTAssertEqual(order.first, "ListOfThings", "\(order)")
    }

    /// A class in the file's own package beats an out-of-scope one even when the other is used
    /// everywhere: the nudge is smaller than the gap between the scope buckets.
    func testPopularityNeverBeatsTheScopeBucket() async throws {
        let index = try await makeIndex(
            jdk: [stub("lib.Widget")],
            project: [stub("app.WidgetMaker", source: true)]
        )
        let source = "package app;\nclass Foo { void m() { Widg€ } }"
        let order = await ranking(source, index: index, counts: ["Widget": 100_000], prefix: "Widg")
        XCTAssertEqual(order.first, "WidgetMaker", "\(order)")
    }

    func testTheBonusIsBoundedAndGrowsSlowly() {
        let widget = stub("lib.Widget")
        func bonus(_ count: Int) -> Double {
            JavaUsageProfile(fileCounts: ["Widget": count]).bonus(for: widget, cap: 0.4)
        }
        XCTAssertEqual(bonus(0), 0)
        XCTAssertLessThan(bonus(1), bonus(5))
        XCTAssertLessThan(bonus(5), bonus(50))
        XCTAssertEqual(bonus(1_000_000), 0.4, accuracy: 1e-9)
        XCTAssertLessThan(bonus(100) - bonus(50), bonus(5) - bonus(1), "the hundredth file matters less than the second")
    }

    func testAProjectClassDoesNotCountItsOwnFile() {
        let own = stub("app.Mine", source: true)
        XCTAssertEqual(JavaUsageProfile(fileCounts: ["Mine": 1]).usage(of: own), 0)
        XCTAssertEqual(JavaUsageProfile(fileCounts: ["Mine": 4]).usage(of: own), 3)
        XCTAssertEqual(JavaUsageProfile(fileCounts: ["Mine": 1]).usage(of: stub("lib.Mine")), 1, "a library class has no own file here")
    }
}
