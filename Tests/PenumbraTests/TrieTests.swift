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
}
