import XCTest
import EditorIntelligence
import LanguageServerProtocol
@testable import EditorIntelligenceLSP

final class LSPDocumentSyncMapperTests: XCTestCase {
    func testIncrementalParamsIncludeRangeAndRangeLength() {
        let change = LSPDocumentSyncService.DocumentChange(
            documentID: DocumentID(),
            range: EditorIntelligence.LSPRange(
                start: LSPPosition(line: 1, character: 2),
                end: LSPPosition(line: 1, character: 5)
            ),
            text: "foo",
            version: 4,
            rangeLength: 3
        )
        let params = LSPDocumentSyncMapper.incrementalParams(uri: "file:///tmp/a.swift", changes: [change])
        XCTAssertEqual(params.textDocument.uri, "file:///tmp/a.swift")
        XCTAssertEqual(params.textDocument.version, 4)
        XCTAssertEqual(params.contentChanges.count, 1)
        XCTAssertEqual(params.contentChanges[0].text, "foo")
        XCTAssertEqual(params.contentChanges[0].rangeLength, 3)
        XCTAssertEqual(params.contentChanges[0].range?.start.line, 1)
        XCTAssertEqual(params.contentChanges[0].range?.start.character, 2)
        XCTAssertEqual(params.contentChanges[0].range?.end.character, 5)
    }

    func testFullChangeOmitsRange() {
        let params = LSPDocumentSyncMapper.fullChangeParams(uri: "file:///tmp/a.swift", version: 2, text: "all")
        XCTAssertEqual(params.contentChanges.count, 1)
        XCTAssertNil(params.contentChanges[0].range)
        XCTAssertNil(params.contentChanges[0].rangeLength)
        XCTAssertEqual(params.contentChanges[0].text, "all")
    }

    func testOpenAndCloseParams() {
        let open = LSPDocumentSyncMapper.openParams(
            uri: "file:///tmp/a.swift",
            languageID: "swift",
            version: 1,
            text: "let a = 1"
        )
        XCTAssertEqual(open.textDocument.uri, "file:///tmp/a.swift")
        XCTAssertEqual(open.textDocument.languageId, "swift")
        XCTAssertEqual(open.textDocument.version, 1)
        XCTAssertEqual(open.textDocument.text, "let a = 1")

        let close = LSPDocumentSyncMapper.closeParams(uri: "file:///tmp/a.swift")
        XCTAssertEqual(close.textDocument.uri, "file:///tmp/a.swift")
    }
}
