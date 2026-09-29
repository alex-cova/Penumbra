import AppKit
import EditorIntelligence
import XCTest
@testable import Penumbra

/// The Symbols section with a host's extra rows (project-wide Java members) and the documents it
/// lists itself.
@MainActor
final class SymbolsPaletteMembersTests: XCTestCase {
    private func symbol(_ name: String, in document: DocumentID) -> EditorIntelligence.Symbol {
        let start = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let end = TextPosition(line: 0, column: name.utf16.count, utf16Offset: name.utf16.count)
        return EditorIntelligence.Symbol(name: name, kind: .function, documentID: document, range: TextRange(start: start, end: end))
    }

    private func makeIndex(java: DocumentID, other: DocumentID) async -> SymbolIndex {
        let index = SymbolIndex()
        await index.index([symbol("getName", in: java)], for: java)
        await index.index([symbol("getNumber", in: other)], for: other)
        return index
    }

    func testExtraRowsComeFirstInTheSameSection() async {
        let java = DocumentID(), other = DocumentID()
        let index = await makeIndex(java: java, other: other)
        let provider = SymbolsPaletteProvider(
            index: index,
            additionalItems: { _, _ in [PaletteItem(id: "member:1", title: "getNickname", sectionTitle: "Symbols", score: 50, action: {})] },
            onSelect: { _ in }
        )

        let items = await provider.items(matching: "getN", limit: 10)

        XCTAssertEqual(items.map(\.id).first, "member:1")
        XCTAssertEqual(Set(items.map(\.sectionTitle)), ["Symbols"], "One section, not a second one under the same heading")
        XCTAssertTrue(items.contains { $0.title == "getNumber" })
    }

    func testExcludedDocumentsSymbolsAreLeftOut() async {
        let java = DocumentID(), other = DocumentID()
        let index = await makeIndex(java: java, other: other)
        let provider = SymbolsPaletteProvider(
            index: index,
            additionalItems: { _, _ in [PaletteItem(id: "member:1", title: "getName", sectionTitle: "Symbols", score: 50, action: {})] },
            excludedDocuments: { [java] in [java] },
            onSelect: { _ in }
        )

        let items = await provider.items(matching: "getN", limit: 10)

        XCTAssertEqual(items.filter { $0.title == "getName" }.count, 1, "The open Java file's symbol is listed once, as the member")
        XCTAssertTrue(items.contains { $0.title == "getNumber" }, "Other documents keep their symbols")
    }

    func testWithoutExtrasNothingChanges() async {
        let java = DocumentID(), other = DocumentID()
        let index = await makeIndex(java: java, other: other)
        let provider = SymbolsPaletteProvider(index: index, onSelect: { _ in })

        let items = await provider.items(matching: "getN", limit: 10)

        XCTAssertEqual(Set(items.map(\.title)), ["getName", "getNumber"])
    }

    func testAnEmptyQueryListsNothing() async {
        let index = await makeIndex(java: DocumentID(), other: DocumentID())
        let provider = SymbolsPaletteProvider(index: index, additionalItems: { _, _ in [PaletteItem(id: "x", title: "x", sectionTitle: "Symbols", score: 10, action: {})] }, onSelect: { _ in })
        let items = await provider.items(matching: "", limit: 10)
        XCTAssertTrue(items.isEmpty)
    }
}
