import XCTest
@testable import JavaIntelligence
@testable import LanguageSyntax

final class JavaParseMemoTests: XCTestCase {
    private let source = "class A { void a() {} void b() {} }"

    func testTheSameTextIsParsedOnce() throws {
        let memo = JavaParseMemo()

        let first = try XCTUnwrap(memo.tree(for: source))
        let second = try XCTUnwrap(memo.tree(for: source))

        XCTAssertTrue(first === second, "the same text must be the same tree")
        XCTAssertEqual(memo.parseCount, 1)
    }

    func testDifferentTextIsParsedAgain() throws {
        let memo = JavaParseMemo()

        let first = try XCTUnwrap(memo.tree(for: source))
        let second = try XCTUnwrap(memo.tree(for: source + " // changed"))

        XCTAssertFalse(first === second)
        XCTAssertEqual(memo.parseCount, 2)
    }

    /// Everything that wants a tree of the buffer once typing pauses asks at about the same time,
    /// from different threads: one of them parses and the others wait for it.
    func testConcurrentRequestsForOneTextShareASingleParse() async throws {
        let memo = JavaParseMemo()
        let large = (0..<4_000).map { "class C\($0) { int f() { return \($0); } }" }.joined(separator: "\n")

        let trees = await withTaskGroup(of: JavaSyntaxTree?.self) { group in
            for _ in 0..<8 {
                group.addTask { memo.tree(for: large) }
            }
            var all: [JavaSyntaxTree?] = []
            for await tree in group { all.append(tree) }
            return all
        }

        XCTAssertEqual(memo.parseCount, 1, "eight concurrent requests parsed the same text more than once")
        let first = try XCTUnwrap(trees.first ?? nil)
        XCTAssertTrue(trees.allSatisfy { $0 === first })
    }

    /// Several features read one shared tree at the same moment, from different threads: the walks
    /// that make a tree's per-tree caches (declarations, scopes) as well as plain traversals. They
    /// must agree, and the thread sanitizer must see no race.
    func testManyThreadsReadingOneSharedTreeAtOnce() async throws {
        let source = (0..<1_500).map { "class C\($0) { int f(int a) { int b = a + \($0); return b; } String s = \"x\"; }" }
            .joined(separator: "\n")
        let memo = JavaParseMemo()
        let tree = try XCTUnwrap(memo.tree(for: source))

        let counts = await withTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var visited = 0
                    func walk(_ node: LanguageSyntax.SyntaxNode) {
                        visited += 1
                        _ = node.type
                        for child in node.namedChildren { walk(child) }
                    }
                    walk(tree.rootNode)
                    return visited
                }
            }
            var all: [Int] = []
            for await count in group { all.append(count) }
            return all
        }

        XCTAssertEqual(Set(counts).count, 1, "threads saw different trees: \(counts)")
        XCTAssertGreaterThan(counts.first ?? 0, 1_000)
    }

    func testConcurrentSemanticPassesOverOneSharedTreeAgree() async throws {
        let source = (0..<400).map {
            "class C\($0) { int f(int a) { int b = a + \($0); return b; } int g() { return f(1) + f(2); } }"
        }.joined(separator: "\n")

        let results = await withTaskGroup(of: Int?.self) { group in
            for _ in 0..<6 {
                group.addTask { await JavaSemanticTokenProvider().tokens(for: source)?.count }
            }
            var all: [Int?] = []
            for await count in group { all.append(count) }
            return all
        }

        XCTAssertEqual(Set(results.map { $0 ?? -1 }).count, 1, "passes over one tree disagreed: \(results)")
        XCTAssertGreaterThan(results.first.flatMap { $0 } ?? 0, 0)
    }

    func testStubsAreKeptPerPathAlongsideTheTree() throws {
        let memo = JavaParseMemo()
        let url = URL(fileURLWithPath: "/proj/A.java")

        let first = try XCTUnwrap(memo.parsed(source: source, url: url))
        let second = try XCTUnwrap(memo.parsed(source: source, url: url))

        XCTAssertTrue(first.tree === second.tree)
        XCTAssertEqual(first.stubs.classes.map(\.qualifiedName), second.stubs.classes.map(\.qualifiedName))
        XCTAssertEqual(memo.parseCount, 1)
    }

    func testATreeAskedForByTextIsTheOneNavigationFinds() throws {
        let memo = JavaParseMemo()

        let tree = try XCTUnwrap(memo.tree(for: source))
        let parsed = try XCTUnwrap(memo.parsed(source: source, url: nil))

        XCTAssertTrue(tree === parsed.tree)
        XCTAssertEqual(memo.parseCount, 1)
    }

    func testTheOldestEntriesGoFirst() throws {
        let memo = JavaParseMemo(maximumEntries: 2)

        _ = memo.tree(for: "class A {}")
        _ = memo.tree(for: "class B {}")
        _ = memo.tree(for: "class C {}")
        XCTAssertEqual(memo.entryCount, 2)

        let parsesBefore = memo.parseCount
        _ = memo.tree(for: "class A {}")
        XCTAssertEqual(memo.parseCount, parsesBefore + 1, "the oldest text was still kept")
    }
}
