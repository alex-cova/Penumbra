import EditorIntelligence
import XCTest
@testable import JavaIntelligence

/// Java's structure and semantic-token providers speaking the generic protocols.
final class JavaLanguageFeaturesTests: XCTestCase {
    private func text(_ range: Range<Int>, in source: String) -> String {
        (source as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
    }

    private func flatten(_ nodes: [StructureNode]) -> [StructureNode] {
        nodes.flatMap { [$0] + flatten($0.children) }
    }

    // MARK: - Structure

    func testStructureRangesAreUTF16OffsetsOfTheNames() async throws {
        let source = "package demo;\n\npublic class Outer {\n    int count;\n    void run(int x) {}\n    class Inner { void deep() {} }\n}\n"
        let provider: any StructureProviding = JavaStructureProvider()
        let rootsOptional = await provider.allStructure(forSource: source)
        let roots = try XCTUnwrap(rootsOptional)
        let names = flatten(roots).map { text($0.nameRange, in: source) }
        XCTAssertEqual(names, ["Outer", "count", "run", "Inner", "deep"])
        XCTAssertEqual(flatten(roots).map(\.kind), [.type, .field, .method, .type, .method])
    }

    func testStructureRangesStayRightAfterMultiByteText() async throws {
        // Characters before the declarations take more UTF-8 bytes than UTF-16 units; a byte offset
        // used as a UTF-16 one would land several characters late.
        let source = "// héllo — ünïcode €uro 🎉\nclass Ünï {\n    String naïve;\n    void größe() {}\n}\n"
        let provider: any StructureProviding = JavaStructureProvider()
        let rootsOptional = await provider.allStructure(forSource: source)
        let roots = try XCTUnwrap(rootsOptional)
        XCTAssertEqual(flatten(roots).map { text($0.nameRange, in: source) }, ["Ünï", "naïve", "größe"])
        let root = try XCTUnwrap(roots.first)
        XCTAssertTrue(text(root.bodyRange, in: source).hasPrefix("class Ünï"))
        XCTAssertTrue(text(root.bodyRange, in: source).hasSuffix("}"))
    }

    func testStructureAtTheCaretPicksTheInnermostType() async throws {
        let source = "class A {\n    class B {\n        void f() {}\n    }\n    void g() {}\n}\n"
        let provider: any StructureProviding = JavaStructureProvider()
        let inB = (source as NSString).range(of: "void f").location
        let rootOptional = await provider.structure(forSource: source, atUTF16Offset: inB)
        let root = try XCTUnwrap(rootOptional)
        XCTAssertEqual(root.title, "B")
        XCTAssertEqual(root.deepestNode(containing: inB).kind, .method)
        XCTAssertEqual(root.deepestNode(containing: inB).title, "f()")
        let outsideOptional = await provider.structure(forSource: source, atUTF16Offset: 0)
        let outside = try XCTUnwrap(outsideOptional)
        XCTAssertEqual(outside.title, "A")
    }

    func testStructureOfAFileThatDoesNotParseIsNil() async {
        let provider: any StructureProviding = JavaStructureProvider()
        let roots = await provider.allStructure(forSource: "")
        XCTAssertEqual(roots?.count ?? 0, 0)
    }

    func testPathToANameWalksFromTheRootDown() async throws {
        let source = "class A {\n    class B {\n        void f() {}\n    }\n}\n"
        let provider: any StructureProviding = JavaStructureProvider()
        let rootsOptional = await provider.allStructure(forSource: source)
        let roots = try XCTUnwrap(rootsOptional)
        let nameOffset = (source as NSString).range(of: "f()").location
        let path = try XCTUnwrap(StructureNode.path(toNameAt: nameOffset, in: roots))
        XCTAssertEqual(path.map(\.title), ["A", "B", "f()"])
        XCTAssertNil(StructureNode.path(toNameAt: 3, in: roots))
    }

    // MARK: - Semantic highlighting

    func testSemanticHighlightsAreTheTokensWithTheirThemeNames() async throws {
        let source = "class Box<T> {\n    private final int size = 1;\n    int get() { return size; }\n}\n"
        let provider = JavaSemanticTokenProvider()
        let tokensOptional = await provider.tokens(for: source)
        let tokens = try XCTUnwrap(tokensOptional)
        let generic: any SemanticTokenProviding = provider
        let highlightsOptional = await generic.semanticHighlights(forSource: source)
        let highlights = try XCTUnwrap(highlightsOptional)
        XCTAssertFalse(highlights.isEmpty)
        XCTAssertEqual(highlights.map(\.range), tokens.map(\.range))
        XCTAssertEqual(highlights.map(\.highlightName), tokens.map(\.highlightName))
        XCTAssertTrue(highlights.contains { text($0.range, in: source) == "Box" && $0.highlightName == "type.class" })
    }
}
