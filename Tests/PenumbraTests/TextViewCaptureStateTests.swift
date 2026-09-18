import XCTest
@testable import Penumbra

@MainActor
final class TextViewCaptureStateTests: XCTestCase {
    func testCapturedStateRestoresTextAfterOverwritingTheView() {
        let textView = makeFocusedTextView(text: "hello from the file")
        let captured = textView.makeCapturedState()
        textView.setState(TextViewState(text: "", theme: DefaultTheme()))
        XCTAssertEqual(textView.text, "")
        textView.setState(captured)
        XCTAssertEqual(textView.text, "hello from the file")
    }

    func testCapturedStateDoesNotMaterializeAFileBackedBuffer() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        let body = "mmap body for capture\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try await WorkbenchDocument.load(contentsOf: url)
        let pending = try XCTUnwrap(document.pendingState)
        let textView = makeFocusedTextView(text: "")
        textView.setState(pending)
        document.pendingState = nil

        XCTAssertTrue(textView.isFileBacked)
        let materializeBefore = textView.makeCapturedState().stringView.materializeCount

        let captured = textView.makeCapturedState()
        textView.setState(TextViewState(text: "", theme: DefaultTheme()))
        XCTAssertEqual(textView.text, "")
        XCTAssertFalse(textView.isFileBacked)

        textView.setState(captured)
        XCTAssertEqual(
            captured.stringView.substring(in: NSRange(location: 0, length: body.utf16.count)),
            body
        )
        XCTAssertTrue(textView.isFileBacked)
        XCTAssertEqual(
            captured.stringView.materializeCount,
            materializeBefore,
            "makeCapturedState must alias the live piece tree, not bridge UTF-16"
        )
    }

    func testSwitchingAwayFromAFileBackedDocumentKeepsARestorablePendingState() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        let body = "keep this around\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try await WorkbenchDocument.load(contentsOf: url)
        let textView = makeFocusedTextView(text: "")
        textView.setState(try XCTUnwrap(document.pendingState))
        document.pendingState = nil
        XCTAssertEqual(document.text, "", "file-backed documents must not copy text onto the model")

        // ⌘N overwrites the TextView. The document has to retain a captured buffer or the
        // original tab rebuilds from empty `text` and both the file and the untitled tab look blank.
        document.pendingState = textView.makeCapturedState()
        textView.setState(TextViewState(text: "", theme: DefaultTheme()))
        XCTAssertEqual(textView.text, "")

        textView.setState(try XCTUnwrap(document.pendingState))
        XCTAssertEqual(
            document.pendingState?.stringView.substring(in: NSRange(location: 0, length: body.utf16.count)),
            body
        )
    }
}
