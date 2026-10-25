import AppKit
import XCTest
@testable import Penumbra
import EditorIntelligence

/// The accept path end to end: trigger completion on a file-backed buffer, accept the offered
/// completion, save, reload from disk, and confirm the accepted text round-tripped. The popup,
/// the edit application, and the save/reload path are covered separately elsewhere; this pins
/// them together so a break in the handoff (stale snapshot, unflushed buffer, encoding change)
/// fails here.
@MainActor
final class CompletionAcceptSaveReparseTests: XCTestCase {
    func testAcceptedCompletionSurvivesSaveAndReload() async throws {
        let url = try writeTempFile("hel + 1\n")
        let document = try await WorkbenchDocument.load(contentsOf: url)
        let prepared = try makePreparedView(from: document)
        let textView = prepared.textView
        textView.selectedRange = NSRange(location: 3, length: 0)

        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [AcceptSaveStubProvider()], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: [])
        )
        // Matches the completion-test harness: the default adapter captures its first snapshot
        // asynchronously after creation.
        try await Task.sleep(nanoseconds: 50_000_000)

        controller.triggerCompletion()
        await waitForCondition("completion popup to show") { controller.isShowingCompletion }
        guard let selected = controller.selectedCompletionItem else {
            XCTFail("Popup is showing but has no selected item")
            return
        }
        controller.acceptSelectedCompletion()
        let accepted = selected.insertText + " + 1\n"
        XCTAssertEqual(textView.text, accepted)

        let result = try await document.save(from: textView)
        XCTAssertTrue(result.generationMatched)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), accepted)

        // Reload exercises the load+parse path; rendering the state proves it reparsed.
        let reloaded = try await WorkbenchDocument.load(contentsOf: url)
        let fresh = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        if let state = reloaded.pendingState {
            fresh.setState(state)
        }
        XCTAssertEqual(fresh.text, accepted)
    }

    // MARK: - Helpers

    private var window: NSWindow?

    private func makePreparedView(from document: WorkbenchDocument) throws -> (textView: TextView, stringView: StringView) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: window.contentView!.bounds)
        window.contentView = textView
        self.window = window
        if let state = document.pendingState {
            textView.setState(state)
            document.pendingState = nil
            return (textView, state.stringView)
        }
        textView.text = document.text
        return (textView, StringView(string: document.text))
    }

    private func writeTempFile(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try text.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}

private struct AcceptSaveStubProvider: CompletionProvider {
    let name = "AcceptSaveStub"

    func provide(context: CompletionContext) async -> [CompletionItem] {
        ["hello", "helium"].map {
            CompletionItem(label: $0, insertText: $0, kind: .function, range: context.range, source: name)
        }
    }
}
