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

/// A file-backed tab's bridged snapshot (`makeEIPDocument`) after the tab was edited and switched
/// away from must read the captured buffer, not the text the file had when it was opened. Language
/// services (the Java overlay, inspections) read background tabs through this snapshot only.
@MainActor
final class WorkbenchDocumentSnapshotAfterCaptureTests: XCTestCase {
    func testTheBridgedSnapshotFollowsTheCapturedEdits() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).java")
        let disk = "class Widget { }\n"
        try disk.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try await WorkbenchDocument.load(contentsOf: url)
        let textView = makeFocusedTextView(text: "")
        textView.setState(try XCTUnwrap(document.pendingState))
        document.pendingState = nil
        textView.selectedRange = NSRange(location: (disk as NSString).length, length: 0)
        textView.insertText("class Gadget { }\n")
        let edited = disk + "class Gadget { }\n"

        // What a tab switch does (`IDEWorkspace`): keep the live buffer on the document.
        document.pendingState = textView.makeCapturedState()

        let bridged = document.makeEIPDocument(version: 7)
        let length = bridged.contentSnapshot.utf16Length
        XCTAssertEqual(length, (edited as NSString).length)
        XCTAssertEqual(bridged.substring(utf16Offset: 0, length: length), edited)
    }
}
