import XCTest
@testable import EditorIntelligence

final class TrieTests: XCTestCase {
    func testInsertAndPrefixSearch() {
        let trie = Trie<String>()
        trie.insert("hello", value: "world")
        trie.insert("help", value: "me")
        trie.insert("foo", value: "bar")
        let results = trie.search(prefix: "hel")
        XCTAssertEqual(results.sorted(), ["me", "world"])
    }

    func testRemoveValue() {
        let trie = Trie<String>()
        trie.insert("hello", value: "world")
        trie.insert("hello", value: "again")
        trie.remove("hello", value: "world")
        let results = trie.search(prefix: "hello")
        XCTAssertEqual(results, ["again"])
    }

    func testRemoveKeyCleansUpNodes() {
        let trie = Trie<String>()
        trie.insert("hello", value: "world")
        trie.remove("hello", value: "world")
        XCTAssertTrue(trie.search(prefix: "h").isEmpty)
    }

    /// A recursive walk overflowed the 544 KB stack of a cooperative-pool thread on a ~1,150-character key.
    func testPrefixSearchOnVeryLongKeyDoesNotOverflowSmallStack() {
        let trie = Trie<String>()
        let key = String(repeating: "a", count: 5_000)
        trie.insert(key, value: "long")
        trie.insert("ab", value: "short")

        var results: [String] = []
        let done = expectation(description: "search finished")
        let thread = Thread {
            results = trie.search(prefix: "a")
            done.fulfill()
        }
        thread.stackSize = 544 * 1024
        thread.start()
        wait(for: [done], timeout: 10)

        XCTAssertEqual(results.sorted(), ["long", "short"])
    }

    func testExactSearchExcludesLongerKeysAndPrefixes() {
        let trie = Trie<String>()
        trie.insert("get", value: "a")
        trie.insert("getName", value: "b")
        trie.insert("ge", value: "c")
        XCTAssertEqual(trie.search(exact: "get"), ["a"])
        XCTAssertTrue(trie.search(exact: "g").isEmpty)
        XCTAssertTrue(trie.search(exact: "missing").isEmpty)
    }

    func testLimitedPrefixSearchReturnsShortestKeysFirst() {
        let trie = Trie<String>()
        trie.insert("abcdef", value: "long")
        trie.insert("ab", value: "short")
        trie.insert("abcd", value: "medium")
        XCTAssertEqual(trie.search(prefix: "a", limit: 2), ["short", "medium"])
        XCTAssertEqual(trie.search(prefix: "a", limit: 0), [])
        XCTAssertEqual(trie.search(prefix: "a", limit: 10).count, 3)
    }

    func testPredicateIsAppliedBeforeLimit() {
        let trie = Trie<String>()
        trie.insert("a", value: "skip1")
        trie.insert("ab", value: "skip2")
        trie.insert("abc", value: "keep")
        XCTAssertEqual(trie.search(prefix: "a", limit: 1, where: { $0 == "keep" }), ["keep"])
    }

    /// Releasing a trie with a very deep chain must not recurse once per character.
    func testReleasingVeryDeepTrieDoesNotOverflowSmallStack() {
        let done = expectation(description: "released")
        let thread = Thread {
            let trie = Trie<String>()
            trie.insert(String(repeating: "a", count: 100_000), value: "deep")
            XCTAssertEqual(trie.search(prefix: "a").count, 1)
            done.fulfill()
        }
        thread.stackSize = 544 * 1024
        thread.start()
        wait(for: [done], timeout: 30)
    }
}
