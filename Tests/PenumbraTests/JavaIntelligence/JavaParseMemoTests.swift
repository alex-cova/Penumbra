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
