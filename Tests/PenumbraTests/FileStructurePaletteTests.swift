import AppKit
import EditorIntelligence
import XCTest
@testable import Penumbra

@MainActor
final class FileStructurePaletteTests: XCTestCase {
    private func symbol(_ name: String, _ kind: SymbolKind, at offset: Int, in document: DocumentID) -> EditorIntelligence.Symbol {
        let start = TextPosition(line: offset, column: 0, utf16Offset: offset)
        let end = TextPosition(line: offset, column: name.utf16.count, utf16Offset: offset + name.utf16.count)
        return EditorIntelligence.Symbol(name: name, kind: kind, documentID: document,
                                         range: TextRange(start: start, end: end))
    }

    private func makeIndex(current: DocumentID, other: DocumentID) async -> SymbolIndex {
        let index = SymbolIndex()
        // Indexed out of source order, with bare words and another document mixed in.
        await index.index([
            symbol("render", .function, at: 300, in: current),
            symbol("Widget", .type, at: 10, in: current),
            symbol("count", .property, at: 120, in: current),
            symbol("Widget", .word, at: 400, in: current),
            symbol("helper", .word, at: 500, in: current)
        ], for: current)
        await index.index([symbol("Elsewhere", .type, at: 5, in: other)], for: other)
        return index
    }

    func testListsTheFilesDeclarationsInSourceOrderWithNoQuery() async {
        let current = DocumentID(), other = DocumentID()
        let index = await makeIndex(current: current, other: other)
        let provider = FileSymbolsPaletteProvider(index: index, documentID: { current }, onSelect: { _ in })

        let items = await provider.items(matching: "", limit: 50)

        XCTAssertEqual(items.map(\.title), ["Widget", "count", "render"],
                       "Declarations only, in document order, none from another file")
        XCTAssertEqual(items.map(\.score), items.map(\.score).sorted(by: >), "Earlier rows rank higher")
    }

    func testTypingNarrowsTheListFuzzily() async {
        let current = DocumentID(), other = DocumentID()
        let index = await makeIndex(current: current, other: other)
        let provider = FileSymbolsPaletteProvider(index: index, documentID: { current }, onSelect: { _ in })

        let items = await provider.items(matching: "rnd", limit: 50)

        XCTAssertEqual(items.map(\.title), ["render"])
        XCTAssertFalse(items[0].matchedIndices.isEmpty)
    }

    func testAnotherDocumentsSymbolsAreNotOffered() async {
        let current = DocumentID(), other = DocumentID()
        let index = await makeIndex(current: current, other: other)
        let provider = FileSymbolsPaletteProvider(index: index, documentID: { other }, onSelect: { _ in })

        let items = await provider.items(matching: "", limit: 50)

        XCTAssertEqual(items.map(\.title), ["Elsewhere"])
    }

    func testNothingWithoutAnActiveDocument() async {
        let current = DocumentID(), other = DocumentID()
        let index = await makeIndex(current: current, other: other)
        let provider = FileSymbolsPaletteProvider(index: index, documentID: { nil }, onSelect: { _ in })

        let items = await provider.items(matching: "", limit: 50)
        XCTAssertTrue(items.isEmpty)
    }

    func testChoosingARowReportsItsSymbol() async throws {
        let current = DocumentID(), other = DocumentID()
        let index = await makeIndex(current: current, other: other)
        var chosen: String?
        let provider = FileSymbolsPaletteProvider(index: index, documentID: { current }) { chosen = $0.name }

        let items = await provider.items(matching: "", limit: 50)
        try XCTUnwrap(items.first { $0.title == "count" }).action()

        XCTAssertEqual(chosen, "count")
    }

    // MARK: Controller

    func testFileStructureIsNotHandledUntilTheHostWiresTheIndexAndDocument() {
        let textView = makeFocusedTextView(text: "x")
        let controller = CommandPaletteController(textView: textView)
        XCTAssertFalse(textView.perform(.goToFileSymbol), "Falls through instead of showing an empty popup")
        XCTAssertFalse(controller.isPresented)
    }

    func testFileStructureOpensTheListForTheActiveDocument() async throws {
        let current = DocumentID(), other = DocumentID()
        let textView = makeFocusedTextView(text: "x")
        let controller = CommandPaletteController(textView: textView)
        controller.symbolIndex = await makeIndex(current: current, other: other)
        controller.activeDocumentIDProvider = { current }

        XCTAssertTrue(textView.perform(.goToFileSymbol))
        XCTAssertTrue(controller.isPresented)
        XCTAssertEqual(controller.paletteModel.mode, .fileSymbols)

        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(controller.flatItems.map(\.title), ["Widget", "count", "render"])
    }

    func testGoToSymbolStillSearchesEveryDocument() async throws {
        let current = DocumentID(), other = DocumentID()
        let textView = makeFocusedTextView(text: "x")
        let controller = CommandPaletteController(textView: textView)
        controller.symbolIndex = await makeIndex(current: current, other: other)
        controller.activeDocumentIDProvider = { current }

        XCTAssertTrue(textView.perform(.goToSymbol))
        XCTAssertEqual(controller.paletteModel.mode, .symbols)
        controller.paletteView.query = "Elsewhere"
        controller.dismiss()
    }

    // MARK: Keys

    func testIntelliJBindsFileStructureAndWorkspaceSymbolsSeparately() {
        XCTAssertEqual(Keymap.intelliJ.action(for: KeyStroke(KeyChord(code: 0x6F, .command))), .goToFileSymbol)
        XCTAssertEqual(Keymap.intelliJ.action(for: KeyStroke(KeyChord("o", [.command, .option]))), .goToSymbol)
    }

    func testOtherPresetsKeepTheirSymbolKeys() {
        XCTAssertEqual(Keymap.sublime.action(for: KeyStroke(KeyChord("r", .command))), .goToSymbol)
        XCTAssertNil(Keymap.default_.action(for: KeyStroke(KeyChord("r", .command))))
    }

    func testEveryPresetBindsCommandF12ToFileStructure() {
        let commandF12 = KeyStroke(KeyChord(code: 0x6F, .command))
        for keymap in [Keymap.default_, Keymap.sublime, Keymap.intelliJ] {
            XCTAssertEqual(keymap.action(for: commandF12), .goToFileSymbol)
        }
    }

    func testTheActionHasATitleAndIsListedInFindAction() {
        XCTAssertEqual(EditorActionID.goToFileSymbol.title, "File Structure…")
        XCTAssertTrue(CommandRegistry.findActionIDs.contains(.goToFileSymbol))
    }
}
