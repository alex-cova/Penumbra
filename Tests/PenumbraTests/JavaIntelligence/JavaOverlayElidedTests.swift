import XCTest
import EditorIntelligence
@testable import JavaIntelligence

/// Umbra's bridge hands every file-backed buffer to the workspace with an elided snapshot (no
/// `text`, a range reader). The overlay must index those, opened and edited, or an unsaved
/// declaration in a tab never reaches the other open files.
final class JavaOverlayElidedTests: XCTestCase {
    private func elided(_ text: String, id: DocumentID, version: Int, url: URL) -> Document {
        let length = (text as NSString).length
        let reader = TextRangeReader(utf16Length: length) { offset, count in
            (text as NSString).substring(with: NSRange(location: offset, length: count))
        }
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        return Document(
            id: id, url: url, displayName: url.lastPathComponent,
            contentSnapshot: TextSnapshot(version: version, utf16Length: length, text: nil, rangeReader: reader),
            selection: Selection(range: TextRange(start: position, end: position)), cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 100, height: 100), languageIdentifier: "java"
        )
    }

    /// Polls for a condition the overlay must reach, bounded; not a timing assumption.
    private func until(_ condition: () async -> Bool) async -> Bool {
        for _ in 0..<400 {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }

    func testElidedBuffersReachTheOverlayWhenOpenedAndEdited() async throws {
        let index = JavaIndex()
        let service = JavaOverlayService(index: index, debounceMilliseconds: 10)
        let workspace = Workspace()
        let task = await service.connect(to: workspace)
        defer { task.cancel() }
        let url = URL(fileURLWithPath: "/tmp/app/Widget-\(UUID().uuidString).java")
        let id = DocumentID()

        await workspace.openDocument(elided("package app;\nclass Widget { }", id: id, version: 1, url: url))
        let opened = await until { await index.classStub(qualifiedName: "app.Widget") != nil }
        XCTAssertTrue(opened, "an opened file-backed buffer is indexed")

        await workspace.updateDocument(elided("package app;\nclass Widget { }\nclass Gadget { }", id: id, version: 2, url: url))
        let edited = await until { await index.classStub(qualifiedName: "app.Gadget") != nil }
        XCTAssertTrue(edited, "an unsaved declaration typed into it is indexed")
        let version = await index.overlayDeclarationsVersion
        XCTAssertGreaterThanOrEqual(version, 2)
    }
}
