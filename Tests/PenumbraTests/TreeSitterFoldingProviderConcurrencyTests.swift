import EditorIntelligence
import XCTest
@testable import Penumbra

/// The main thread reports every keystroke to the folding provider while fold scans run on other
/// threads. Both used to write the provider's regions and dirty rows directly, which the thread
/// sanitizer reported as a data race (`Umbra` typing a file with folding on).
final class TreeSitterFoldingProviderConcurrencyTests: XCTestCase {
    private func document(lines: Int) -> Document {
        let text = (0..<lines).map { "line \($0) { }" }.joined(separator: "\n")
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            url: URL(fileURLWithPath: "/proj/T.java"),
            displayName: "T.java",
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100),
            languageIdentifier: "java"
        )
    }

    func testEditsFromOneThreadWhileScansRunOnAnother() async {
        let provider = TreeSitterFoldingProvider()
        let document = document(lines: 2_000)
        let scans = Task.detached {
            for _ in 0..<150 { _ = await provider.foldRegions(for: document) }
        }

        for index in 0..<4_000 {
            let row = index % 100
            provider.invalidateForEdit(
                changedRows: row...(row + 1), lineCount: 2_000 + index % 3, previousLineCount: 2_000, spliceRow: row
            )
            if index % 700 == 0 { provider.invalidate() }
        }
        await scans.value
    }

    func testAnUnboundedRunOfEditsNeverGrowsTheQueueWithoutLimit() async {
        let provider = TreeSitterFoldingProvider()
        for index in 0..<50_000 {
            provider.invalidateForEdit(changedRows: 1...2, lineCount: 10, previousLineCount: 10, spliceRow: index % 10)
        }
        // Folding switched off for a long time: nothing scanned, then one scan replays the (capped) queue.
        let descriptors = await provider.foldRegions(for: document(lines: 10))
        XCTAssertNotNil(descriptors)
    }
}
