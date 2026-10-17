import AppKit
import EditorIntelligence
import Foundation
import XCTest
@testable import Penumbra

/// `refreshDiagnostics` against a file-backed (elided-snapshot) adapter: the providers must see
/// the file's text, not the empty string the snapshot bridges for performance.
@MainActor
final class EditorIntelligenceControllerElidedDiagnosticsTests: XCTestCase {
    /// An adapter whose documents bridge elided, like `makeEIPDocument()` does for file-backed
    /// workbench documents (`text == nil`, so `Document.text` is empty).
    private final class ElidedSnapshotAdapter: EditorAdapter {
        let id = EditorAdapterID()
        let context = EditorContext()
        var events: AsyncStream<EditorEvent> { AsyncStream { _ in } }
        private let document: Document

        init(url: URL, utf16Length: Int) {
            let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
            document = Document(
                url: url, displayName: url.lastPathComponent,
                contentSnapshot: TextSnapshot(version: 0, utf16Length: utf16Length, text: nil),
                selection: Selection(range: EditorIntelligence.TextRange(start: position, end: position)),
                cursor: Cursor(position: position),
                viewport: Viewport(x: 0, y: 0, width: 0, height: 0),
                languageIdentifier: "java"
            )
        }

        var currentDocument: Document? { document }
        var openDocuments: [Document] { [document] }
        func document(withID id: DocumentID) -> Document? { id == document.id ? document : nil }
        func applyEdit(_ edit: TextEdit, toDocumentWithID documentID: DocumentID) async throws {}
        func focusRange(_ range: EditorIntelligence.TextRange, inDocumentWithID documentID: DocumentID) async throws {}
    }

    private actor CapturingDiagnosticProvider: DiagnosticProvider {
        let name = "Capture"
        private(set) var seenTexts: [String] = []
        private let findings: [Diagnostic]

        init(findings: [Diagnostic]) { self.findings = findings }

        func diagnostics(for document: Document) async -> [Diagnostic] {
            seenTexts.append(document.text)
            return findings
        }
    }

    func testRefreshDiagnosticsMaterializesElidedSnapshots() async throws {
        let text = "class Foo {\n    runs.forach(x);\n}\n"
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = text

        let url = URL(fileURLWithPath: "/proj/Foo.java")
        let adapter = ElidedSnapshotAdapter(url: url, utf16Length: (text as NSString).length)
        XCTAssertTrue(adapter.currentDocument?.contentSnapshot.isElided ?? false, "precondition: the adapter bridges elided")

        let position = TextPosition(line: 1, column: 4, utf16Offset: 19)
        let provider = CapturingDiagnosticProvider(findings: [
            Diagnostic(
                severity: .error, message: "Cannot resolve method 'forach'",
                range: TextRange(start: position, end: TextPosition(line: 1, column: 10, utf16Offset: 25)),
                source: "Test"
            )
        ])
        let controller = EditorIntelligenceController(
            textView: textView,
            adapter: adapter,
            completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: [provider])
        )

        controller.refreshDiagnostics()
        let deadline = Date().addingTimeInterval(3)
        while await provider.seenTexts.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let seen = await provider.seenTexts
        XCTAssertEqual(seen, [text], "providers must see the file's text, not the elided snapshot's empty string")
        XCTAssertEqual(textView.diagnostics.count, 1, "the finding paints a marker (squiggle and error stripe feed)")
    }

    func testRefreshDiagnosticsReusesNonElidedSnapshots() async throws {
        let text = "class Foo {}\n"
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.theme = DefaultTheme()
        textView.text = text

        // An in-memory adapter snapshot already carries its text: no copy needed.
        let position = TextPosition(line: 0, column: 0, utf16Offset: 0)
        let full = Document(
            url: URL(fileURLWithPath: "/proj/Foo.java"), displayName: "Foo.java",
            contentSnapshot: TextSnapshot(version: 0, text: text),
            selection: Selection(range: EditorIntelligence.TextRange(start: position, end: position)),
            cursor: Cursor(position: position),
            viewport: Viewport(x: 0, y: 0, width: 0, height: 0),
            languageIdentifier: "java"
        )
        let direct = DirectAdapter(document: full)
        let provider = CapturingDiagnosticProvider(findings: [])
        let controller = EditorIntelligenceController(
            textView: textView,
            adapter: direct,
            completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: [provider])
        )

        controller.refreshDiagnostics()
        let deadline = Date().addingTimeInterval(3)
        while await provider.seenTexts.isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let seen = await provider.seenTexts
        XCTAssertEqual(seen, [text])
    }

    private final class DirectAdapter: EditorAdapter {
        let id = EditorAdapterID()
        let context = EditorContext()
        var events: AsyncStream<EditorEvent> { AsyncStream { _ in } }
        private let document: Document

        init(document: Document) { self.document = document }

        var currentDocument: Document? { document }
        var openDocuments: [Document] { [document] }
        func document(withID id: DocumentID) -> Document? { id == document.id ? document : nil }
        func applyEdit(_ edit: TextEdit, toDocumentWithID documentID: DocumentID) async throws {}
        func focusRange(_ range: EditorIntelligence.TextRange, inDocumentWithID documentID: DocumentID) async throws {}
    }
}
