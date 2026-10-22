import Foundation
import XCTest

@testable import Umbra

@MainActor
final class IDEAgentRichBlocksTests: XCTestCase {
    func testMermaidIsRecognisedByFenceLanguage() {
        XCTAssertTrue(IDEAgentRichBlocks.isMermaid("mermaid"))
        XCTAssertTrue(IDEAgentRichBlocks.isMermaid(" Mermaid "))
        XCTAssertFalse(IDEAgentRichBlocks.isMermaid("swift"))
        XCTAssertFalse(IDEAgentRichBlocks.isMermaid(nil))
    }

    func testAFenceWithAGrammarComesBackColoured() async throws {
        let highlighted = await IDEAgentRichBlocks.highlight("let answer = 42\n", language: "swift")
        let text = try XCTUnwrap(highlighted)
        XCTAssertEqual(String(text.characters), "let answer = 42\n")
        let colours = Set(text.runs.compactMap { $0.appKit.foregroundColor })
        XCTAssertGreaterThan(colours.count, 1, "keywords and numbers should not share one colour")
        XCTAssertTrue(text.runs.allSatisfy { $0.appKit.font == nil }, "the font is left to the view")
    }

    func testAFenceWithoutAGrammarOrLanguageStaysPlain() async {
        let unknown = await IDEAgentRichBlocks.highlight("a b c", language: "no-such-language")
        let unlabelled = await IDEAgentRichBlocks.highlight("a b c", language: nil)
        XCTAssertNil(unknown)
        XCTAssertNil(unlabelled)
    }

    func testAnOversizedFenceIsNotHighlighted() async {
        let huge = String(repeating: "x = 1\n", count: IDEAgentRichBlocks.maxHighlightedCharacters)
        let highlighted = await IDEAgentRichBlocks.highlight(huge, language: "swift")
        XCTAssertNil(highlighted)
    }

    func testAFlowchartIsDrawn() async {
        let diagram = await IDEAgentRichBlocks.diagram("graph TD\n  A[Start] --> B[End]\n")
        guard case .image(let image, let size) = diagram else {
            return XCTFail("expected a drawn diagram, got \(diagram)")
        }
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    func testABrokenDiagramReportsWhyInsteadOfDrawing() async {
        let diagram = await IDEAgentRichBlocks.diagram("this is not mermaid at all {{{")
        guard case .failed(let message) = diagram else {
            return XCTFail("expected a failure, got \(diagram)")
        }
        XCTAssertFalse(message.isEmpty)
    }
}
