import AppKit
import XCTest
import EditorIntelligence
@testable import Penumbra

@MainActor
final class PenumbraEditorAdapterTests: XCTestCase {
    func testAdapterCreatesInitialDocument() async throws {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.text = "hello world"
        let adapter = PenumbraEditorAdapter(textView: textView, context: EditorContext(rootProjectURL: URL(fileURLWithPath: "/tmp")))
        // Wait for the initial document capture task on the main actor.
        try await Task.sleep(nanoseconds: 100_000_000)
        let document = adapter.currentDocument
        XCTAssertNotNil(document)
        XCTAssertEqual(document?.text, "hello world")
        XCTAssertEqual(document?.displayName, "tmp")
    }

    func testTextChangeEmitsDocumentChangedEvent() async throws {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.text = "hello"
        let adapter = PenumbraEditorAdapter(textView: textView, context: EditorContext())
        let events = adapter.events
        let task = Task.detached {
            var capturedEvents: [EditorEvent] = []
            for await event in events {
                capturedEvents.append(event)
                if capturedEvents.count >= 2 {
                    break
                }
            }
            return capturedEvents
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        textView.text = "hello world"
        adapter.textViewDidChange(textView)
        let capturedEvents = await task.value
        XCTAssertEqual(capturedEvents.count, 2)
        if case .documentChanged = capturedEvents.last {
            // expected
        } else {
            XCTFail("Expected documentChanged event, got \(String(describing: capturedEvents.last))")
        }
    }

    func testReplaceEmitsDocumentEditedWithRange() async throws {
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.text = "hello"
        let adapter = PenumbraEditorAdapter(textView: textView, context: EditorContext())
        let events = adapter.events
        let task = Task.detached {
            var capturedEvents: [EditorEvent] = []
            for await event in events {
                capturedEvents.append(event)
                if capturedEvents.contains(where: {
                    if case .documentEdited = $0 { return true }
                    return false
                }) {
                    break
                }
            }
            return capturedEvents
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        textView.replace(NSRange(location: 5, length: 0), withText: " world")
        let capturedEvents = await task.value
        guard let edited = capturedEvents.last, case .documentEdited(_, let edits, newSnapshot: let snapshot) = edited else {
            return XCTFail("Expected documentEdited, got \(String(describing: capturedEvents.last))")
        }
        XCTAssertEqual(snapshot.text, "hello world")
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits[0].replacement, " world")
        XCTAssertEqual(edits[0].range.start.utf16Offset, 5)
        XCTAssertEqual(edits[0].range.end.utf16Offset, 5)
    }

    func testFileBackedLoadDoesNotMaterializeSnapshotText() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try "file backed body\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let state = try await TextViewState.load(contentsOf: url)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.setState(state)
        let adapter = PenumbraEditorAdapter(textView: textView, context: EditorContext())
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(textView.isFileBacked)
        XCTAssertTrue(adapter.currentDocument?.contentSnapshot.isElided ?? false)
        XCTAssertNil(adapter.currentDocument?.contentSnapshot.text)
        XCTAssertEqual(adapter.currentDocument?.substring(utf16Offset: 0, length: 4), "file")
        let cursorWord = adapter.currentDocument?.word(atUTF16Offset: 5, window: 32)
        XCTAssertEqual(cursorWord, "backed")
    }

    func testUntitledPieceTreeDoesNotMaterializeSnapshotText() async throws {
        let body = String(repeating: "untitled ", count: StringView.pieceTreeUntitledThreshold / 9 + 1)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.text = body
        XCTAssertFalse(textView.isFileBacked)
        XCTAssertNotNil(textView.pieceTreeContentSnapshot())
        let adapter = PenumbraEditorAdapter(textView: textView, context: EditorContext())
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(adapter.currentDocument?.contentSnapshot.isElided ?? false)
        XCTAssertNil(adapter.currentDocument?.contentSnapshot.text)
        XCTAssertEqual(adapter.currentDocument?.substring(utf16Offset: 0, length: 8), "untitled")
    }
}
