import XCTest
@testable import Penumbra

/// Tests for `MarkdownPreviewParseCache`: prose split at headings parses to exactly the blocks of
/// an unsplit parse, and an edit re-parses only its own chunk.
final class MarkdownPreviewParseCacheTests: XCTestCase {
    /// The blocks the preview produced before chunking: each prose segment parsed whole.
    private func unchunkedBlocks(_ source: String) -> [MarkdownPreviewBlock] {
        let (stripped, definitions) = MarkdownPreviewFootnotes.extract(from: source)
        let links = MarkdownPreviewIntentWalker.linkReferenceDefinitions(in: stripped)
        var blocks: [MarkdownPreviewBlock] = []
        for segment in MermaidFenceExtractor.segments(in: stripped) {
            switch segment {
            case .prose(let prose):
                blocks += MarkdownPreviewIntentWalker.blocks(in: prose, linkDefinitions: links)
            case .fencedCode(let language, let body):
                blocks.append(MarkdownPreviewBlock(kind: MermaidFenceExtractor.isMermaidFence(language)
                    ? .mermaid(source: body) : .codeBlock(language: language, source: body)))
            }
        }
        var numbered = MarkdownPreviewFootnotes.numberReferences(in: blocks, definitions: definitions)
        if !numbered.footnotes.isEmpty {
            numbered.blocks.append(MarkdownPreviewBlock(kind: .thematicBreak))
            numbered.blocks.append(MarkdownPreviewBlock(kind: .footnotes(numbered.footnotes)))
        }
        return numbered.blocks
    }

    private let samples = [
        "# One\n\nPara\n\n## Two\n\n- a\n- b\n\n### Three\n\n1. x\n2. y\n",
        "Intro\n\n# Heading\ntext right under\n\n#NotAHeading\n\n####### seven hashes\n\n# Last",
        "> quote\n\n# Heading after quote\n\n> another\n>> nested\n\n# End",
        "- item\n\n  continued\n\n# Heading after list\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n# After table",
        "See [ref] and[^1].\n\n# Section\n\nMore [ref].\n\n[ref]: https://example.com\n[^1]: A footnote.",
        "Para\n\n\n\n# After several blank lines\n\n    indented code\n\n# Next",
        "<!-- comment\n\n# inside the comment\n-->\n\n# Real heading",
        "Text\n\n```swift\nlet x = 1\n```\n\n# After fence\n\n```mermaid\ngraph TD\nA-->B\n```\n\n# Tail",
    ]

    func testChunkedParseMatchesUnchunkedParse() {
        for source in samples {
            let document = MarkdownPreviewDocument.parse(source)
            XCTAssertEqual(document.blocks, unchunkedBlocks(source), "Mismatch for:\n\(source)")
        }
    }

    func testChunksConcatenateBackToTheProse() {
        for source in samples {
            XCTAssertEqual(MarkdownPreviewParseCache.chunks(of: source).joined(), source)
        }
        XCTAssertEqual(MarkdownPreviewParseCache.chunks(of: "a\n\n# b\n\n## c").count, 3)
        XCTAssertEqual(MarkdownPreviewParseCache.chunks(of: "a\n# b").count, 1, "A heading without a blank line above isn't split off")
    }

    func testProseWithBlankLineSpanningHTMLIsNotSplit() {
        XCTAssertEqual(MarkdownPreviewParseCache.chunks(of: "<!-- x\n\n# y\n-->\n\n# z").count, 1)
        XCTAssertEqual(MarkdownPreviewParseCache.chunks(of: "<PRE>\n\n# y\n</PRE>").count, 1)
        XCTAssertEqual(MarkdownPreviewParseCache.chunks(of: "a < b\n\n# y").count, 2)
    }

    func testEditReparsesOnlyTheChangedChunk() {
        let cache = MarkdownPreviewParseCache()
        let sections = (0 ..< 20).map { "# Section \($0)\n\nBody \($0)." }
        _ = MarkdownPreviewDocument.parse(sections.joined(separator: "\n\n"), cache: cache)
        XCTAssertEqual(cache.lastParsedChunkCount, 20)

        var edited = sections
        edited[7] = "# Section 7\n\nBody 7, edited."
        let document = MarkdownPreviewDocument.parse(edited.joined(separator: "\n\n"), cache: cache)
        XCTAssertEqual(cache.lastParsedChunkCount, 1)
        XCTAssertEqual(document, MarkdownPreviewDocument.parse(edited.joined(separator: "\n\n")))
    }

    func testParsedBlocksCarryContentHashes() {
        let document = MarkdownPreviewDocument.parse("# A\n\nText[^1]\n\n```swift\nx\n```\n\n[^1]: Note")
        XCTAssertTrue(document.blocks.allSatisfy { $0.contentHash == $0.kind.hashValue })
    }

    func testChangingKindClearsTheContentHash() {
        var block = MarkdownPreviewDocument.parse("Text").blocks[0]
        XCTAssertNotNil(block.contentHash)
        block.kind = .thematicBreak
        XCTAssertNil(block.contentHash)
        XCTAssertEqual(block, MarkdownPreviewBlock(kind: .thematicBreak))
    }
}
