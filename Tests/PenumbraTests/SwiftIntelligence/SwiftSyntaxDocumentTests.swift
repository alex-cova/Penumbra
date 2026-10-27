import Foundation
import SwiftIntelligence
import XCTest

final class SwiftSyntaxDocumentTests: XCTestCase {
    func testAParseKnowsItsLengthAndWhetherTheSourceHadErrors() {
        let valid = SwiftSyntaxDocument.parse("let a = 1\n")
        XCTAssertEqual(valid.utf8Length, 10)
        XCTAssertFalse(valid.hasSyntaxErrors)
        XCTAssertTrue(SwiftSyntaxDocument.parse("let = = (\n").hasSyntaxErrors, "the parser recovers and says it had to")
    }

    func testTheSameTextIsParsedOnce() {
        let cache = SwiftSyntaxParseCache()
        let first = cache.document(for: "let a = 1\n")
        let second = cache.document(for: "let a = 1\n")
        XCTAssertEqual(first.tree.id, second.tree.id, "the second call returned the first parse")
        XCTAssertNotEqual(first.tree.id, cache.document(for: "let b = 2\n").tree.id)
        XCTAssertEqual(cache.count, 2)
    }

    func testTheCacheKeepsTheMostRecentlyUsedParses() {
        let cache = SwiftSyntaxParseCache(capacity: 2)
        let a = cache.document(for: "let a = 1\n")
        _ = cache.document(for: "let b = 2\n")
        _ = cache.document(for: "let a = 1\n") // a is now the most recent
        _ = cache.document(for: "let c = 3\n") // evicts b, the least recent
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.document(for: "let a = 1\n").tree.id, a.tree.id, "a survived")
        XCTAssertEqual(cache.count, 2)
    }

    func testATextOverTheSizeLimitIsParsedButNotKept() {
        let cache = SwiftSyntaxParseCache(capacity: 4, maximumUTF8Length: 16)
        let big = "let aVeryLongName = 12345\n"
        XCTAssertGreaterThan(big.utf8.count, 16)
        let first = cache.document(for: big)
        XCTAssertEqual(cache.count, 0, "a tree is far larger than its source, so a large file does not stay")
        XCTAssertNotEqual(first.tree.id, cache.document(for: big).tree.id)
    }

    func testReferencesIgnoreMemberNamesAndImplicitMembers() {
        let document = SwiftSyntaxDocument.parse("let a = 1\nprint(a, b.c, .d)\n")
        let names = SwiftSyntaxScopes.references(in: document).map(\.name)
        XCTAssertEqual(names, ["print", "a", "b"], "`c` follows a dot and `.d` has no base")
    }

    /// Offsets are UTF-8 bytes, the unit `SwiftFileModel` uses; a multi-byte character before the name
    /// moves the byte offset, not the character index.
    func testOffsetsAreUTF8BytesNotCharacters() {
        let text = "func f() {\n    let café = \"🙂\"\n    print(café)\n}\n"
        let bytes = Array(text.utf8)
        let references = SwiftSyntaxScopes.references(in: SwiftSyntaxDocument.parse(text))
        let use = references.first { $0.name == "café" }
        XCTAssertNotNil(use)
        XCTAssertEqual(use.map { String(decoding: bytes[$0.bytes], as: UTF8.self) }, "café")
        guard case .local(let declaration, _)? = use?.resolution else { return XCTFail("not resolved to the constant") }
        XCTAssertEqual(String(decoding: bytes[declaration], as: UTF8.self), "café")
        XCTAssertLessThan(declaration.lowerBound, use!.bytes.lowerBound)
    }
}
