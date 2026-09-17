import AppKit
import EditorIntelligence
import XCTest
@testable import Penumbra

@MainActor
final class PenumbraEditorAdapterMultiSelectionTests: XCTestCase {
    func testAdapterReportsAdditionalSelectionRanges() async throws {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.text = "foo bar foo"
        let adapter = PenumbraEditorAdapter(textView: textView, context: EditorContext())
        try await Task.sleep(nanoseconds: 100_000_000)
        textView.selectedRanges = [
            NSRange(location: 0, length: 3),
            NSRange(location: 8, length: 3)
        ]
        adapter.textViewDidChangeSelection(textView)
        try await Task.sleep(nanoseconds: 50_000_000)
        let selection = adapter.currentDocument?.selection
        XCTAssertEqual(selection?.allRanges.count, 2)
        XCTAssertEqual(selection?.range.start.utf16Offset, 0)
        XCTAssertEqual(selection?.range.end.utf16Offset, 3)
        XCTAssertEqual(selection?.additionalRanges.first?.start.utf16Offset, 8)
        XCTAssertEqual(selection?.additionalRanges.first?.end.utf16Offset, 11)
    }
}
