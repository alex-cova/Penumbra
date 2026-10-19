import XCTest
@testable import Penumbra

/// Coverage for `{{TOC}}` expansion (`MarkdownPreviewTableOfContents`): marker detection,
/// heading scanning (all six ATX levels, fence/code exclusion) and the generated link list,
/// including end-to-end that `MarkdownPreviewDocument.parse` turns the marker into a list of
/// real `#slug` links — which is what both the on-screen preview and PDF export render.
final class MarkdownPreviewTableOfContentsTests: XCTestCase {
    // MARK: - Expansion

    func testSourceWithoutMarkerIsUnchanged() {
        let source = "# Title\n\nSome text with {{TOC}} inline, not on its own line.\n"
        XCTAssertEqual(MarkdownPreviewTableOfContents.expanded(source), source)
    }

    func testMarkerExpandsToNestedLinkList() {
        let source = "{{TOC}}\n\n# Alpha\n\n## Beta\n\n### Gamma\n"
        XCTAssertEqual(
            MarkdownPreviewTableOfContents.expanded(source),
            "- [Alpha](#alpha)\n  - [Beta](#beta)\n    - [Gamma](#gamma)\n\n# Alpha\n\n## Beta\n\n### Gamma\n"
        )
    }

    func testIndentationNormalizesToShallowestHeading() {
        let source = "{{TOC}}\n\n## Alpha\n\n#### Beta\n"
        XCTAssertEqual(
            MarkdownPreviewTableOfContents.expanded(source),
            "- [Alpha](#alpha)\n    - [Beta](#beta)\n\n## Alpha\n\n#### Beta\n"
        )
    }

    func testAllSixLevelsProduceEntries() {
        let source = "{{TOC}}\n\n# One\n## Two\n### Three\n#### Four\n##### Five\n###### Six\n"
        let expanded = MarkdownPreviewTableOfContents.expanded(source)
        for slug in ["one", "two", "three", "four", "five", "six"] {
            XCTAssertTrue(expanded.contains("](#\(slug))"), "Missing entry for #\(slug)")
        }
    }

    func testDuplicateHeadingsGainNumberedSlugs() {
        let source = "{{TOC}}\n\n# Repeat\n\n# Repeat\n\n# Repeat\n"
        let expanded = MarkdownPreviewTableOfContents.expanded(source)
        XCTAssertTrue(expanded.contains("- [Repeat](#repeat)\n"))
        XCTAssertTrue(expanded.contains("- [Repeat](#repeat-1)\n"))
        XCTAssertTrue(expanded.contains("- [Repeat](#repeat-2)\n"))
    }

    func testSlugDropsPunctuationAndKeepsUnicode() {
        let source = "{{TOC}}\n\n# Hello, World!\n\n# C# Guide\n\n# Über uns\n"
        let expanded = MarkdownPreviewTableOfContents.expanded(source)
        XCTAssertTrue(expanded.contains("- [Hello, World!](#hello-world)\n"))
        XCTAssertTrue(expanded.contains("- [C# Guide](#c-guide)\n"))
        XCTAssertTrue(expanded.contains("- [Über uns](#über-uns)\n"))
    }

    func testInlineFormattingIsStrippedFromTitles() {
        let source = "{{TOC}}\n\n# Hello **bold** and [link](https://example.com)\n"
        XCTAssertTrue(
            MarkdownPreviewTableOfContents.expanded(source).contains("- [Hello bold and link](#hello-bold-and-link)\n")
        )
    }

    func testClosingHashesAreStripped() {
        let source = "{{TOC}}\n\n## Title ##\n"
        XCTAssertTrue(MarkdownPreviewTableOfContents.expanded(source).contains("- [Title](#title)\n"))
    }

    func testHashtagAndSevenHashesAreNotHeadings() {
        let source = "{{TOC}}\n\n#hashtag\n\n####### Not a heading\n\n# Real\n"
        let expanded = MarkdownPreviewTableOfContents.expanded(source)
        XCTAssertFalse(expanded.contains("[#hashtag]"))
        XCTAssertFalse(expanded.contains("[Not a heading]"))
        XCTAssertTrue(expanded.contains("- [Real](#real)\n"))
    }

    func testQuotedHeadingIsIncluded() {
        let source = "{{TOC}}\n\n> # Quoted\n"
        XCTAssertTrue(MarkdownPreviewTableOfContents.expanded(source).contains("- [Quoted](#quoted)\n"))
    }

    func testFencedHeadingsAreExcludedAndFencedMarkerUntouched() {
        let source = "{{TOC}}\n\n# Real\n\n```\n# Fake\n{{TOC}}\n```\n\n~~~\n## Also fake\n~~~\n"
        let expanded = MarkdownPreviewTableOfContents.expanded(source)
        XCTAssertTrue(expanded.hasPrefix("- [Real](#real)\n"))
        XCTAssertFalse(expanded.contains("[Fake]"))
        XCTAssertFalse(expanded.contains("[Also fake]"))
        // The marker inside the fence survives (only the top-level one expanded).
        XCTAssertTrue(expanded.contains("{{TOC}}"))
    }

    func testIndentedMarkerIsCodeAndUntouched() {
        let source = "    {{TOC}}\n\n# Real\n"
        XCTAssertEqual(MarkdownPreviewTableOfContents.expanded(source), source)
    }

    func testMarkerWithNoHeadingsIsRemoved() {
        XCTAssertEqual(MarkdownPreviewTableOfContents.expanded("Before\n\n{{TOC}}\n\nAfter\n"), "Before\n\n\n\nAfter\n")
    }

    func testMultipleMarkersEachExpand() {
        let source = "{{TOC}}\n\n# Real\n\n{{TOC}}\n"
        let expanded = MarkdownPreviewTableOfContents.expanded(source)
        XCTAssertEqual(expanded.components(separatedBy: "- [Real](#real)").count, 3)
        XCTAssertFalse(expanded.contains("{{TOC}}"))
    }

    // MARK: - End to end through parse (preview + PDF export input)

    private func tocListItems(in source: String) -> [MarkdownPreviewList.Item] {
        let document = MarkdownPreviewDocument.parse(source)
        for block in document.blocks {
            if case .list(let list) = block.kind, !list.items.isEmpty {
                // The TOC list is the only list whose every item links to a `#` fragment.
                let links = list.items.flatMap { item in item.text.runs.compactMap(\.link) }
                if links.count == list.items.count, links.allSatisfy({ $0.absoluteString.hasPrefix("#") }) {
                    return list.items
                }
            }
        }
        return []
    }

    func testParseTurnsMarkerIntoLinkedList() {
        let items = tocListItems(in: "{{TOC}}\n\n# Alpha\n\n## Beta\n")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(String(items[0].text.characters), "Alpha")
        XCTAssertEqual(String(items[1].text.characters), "Beta")
        XCTAssertEqual(items[0].level, 0)
        XCTAssertEqual(items[1].level, 1)
        let links = items.map { $0.text.runs.compactMap(\.link).first?.absoluteString }
        XCTAssertEqual(links, ["#alpha", "#beta"])
    }

    func testParseLeavesMarkerLineOutOfBlocks() {
        let document = MarkdownPreviewDocument.parse("{{TOC}}\n\n# Alpha\n")
        for block in document.blocks {
            if case .paragraph(let text) = block.kind {
                XCTAssertFalse(String(text.characters).contains("{{TOC}}"))
            }
        }
    }

    func testParseWithoutMarkerIsUnaffected() {
        let source = "# Alpha\n\nSome text.\n"
        let document = MarkdownPreviewDocument.parse(source)
        XCTAssertFalse(document.blocks.contains {
            if case .list = $0.kind { return true }
            return false
        })
    }
}
