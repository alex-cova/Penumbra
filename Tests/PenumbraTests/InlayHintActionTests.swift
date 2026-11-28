@preconcurrency import AppKit
import EditorIntelligence
import XCTest
@testable import Penumbra

/// The inlay hint actions a keystroke can be bound to: follow the link in the hint at the caret, apply it as
/// text, and (for the host) toggle hints.
@MainActor
final class InlayHintActionTests: XCTestCase {
    private func makeController(text: String) -> (EditorIntelligenceController, TextView, NSWindow) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: window.contentView!.bounds)
        textView.theme = DefaultTheme()
        textView.text = text
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        textView.layoutIfNeeded()
        let controller = EditorIntelligenceController(
            textView: textView,
            completionEngine: CompletionEngine(providers: [], debounceInterval: 0),
            hoverEngine: HoverEngine(providers: []),
            diagnosticEngine: DiagnosticEngine(providers: [])
        )
        return (controller, textView, window)
    }

    private let place = LSPRange(start: LSPPosition(line: 3, character: 7), end: LSPPosition(line: 3, character: 11))

    func testFollowingAHintLinkOpensItsLocationLikeAGoToDefinitionResult() throws {
        let (controller, textView, window) = makeController(text: "let value = make()")
        defer { window.orderOut(nil) }
        textView.inlayHints = [InlayHint(
            utf16Offset: 9, label: ": List", kind: .type,
            parts: [InlayHintLabelPart(range: NSRange(location: 2, length: 4), target: .location(uri: "file:///tmp/List.swift", range: place))]
        )]
        var opened: [Location] = []
        controller.onOpenLocationInOtherDocument = { opened.append($0); return true }

        textView.selectedRange = NSRange(location: 9, length: 0)
        XCTAssertEqual(textView.editorActionHandler?(.followInlayHintLink), true)
        XCTAssertEqual(opened.map(\.url), [URL(string: "file:///tmp/List.swift")])
        XCTAssertEqual(opened.first?.range.start.line, 3)
        XCTAssertEqual(opened.first?.range.start.column, 7)

        textView.selectedRange = NSRange(location: 2, length: 0)
        XCTAssertEqual(textView.editorActionHandler?(.followInlayHintLink), false, "no hint at the caret: not handled")
        textView.selectedRange = NSRange(location: 9, length: 3)
        XCTAssertEqual(textView.editorActionHandler?(.followInlayHintLink), false, "a selection is not a caret at the hint")
        XCTAssertEqual(opened.count, 1)
    }

    func testApplyingNeedsAHintAtTheCaretThatOffersAnEdit() {
        let (_, textView, window) = makeController(text: "let value = make()")
        defer { window.orderOut(nil) }
        textView.inlayHints = [InlayHint(utf16Offset: 9, label: ": Int", kind: .type)]
        textView.selectedRange = NSRange(location: 9, length: 0)
        XCTAssertEqual(textView.editorActionHandler?(.applyInlayHint), false, "this hint has no edit to apply")
        textView.selectedRange = NSRange(location: 0, length: 0)
        XCTAssertEqual(textView.editorActionHandler?(.applyInlayHint), false)
    }

    func testTheActionsHaveTitlesForTheKeymapAndPaletteAndNoDefaultKeys() {
        for action in [EditorActionID.applyInlayHint, .followInlayHintLink, .toggleInlayHints] {
            XCTAssertFalse(action.title.isEmpty)
            XCTAssertNotEqual(action.title, action.rawValue, "a real title, not the raw id")
            for keymap in [Keymap.default_, .intelliJ, .sublime, .vsCode] {
                XCTAssertNil(keymap.stroke(for: action), "\(action) is bound by the user, not by a preset")
            }
        }
    }
}
