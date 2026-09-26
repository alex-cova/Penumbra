@preconcurrency import AppKit
import PenumbraLanguages
import XCTest
@testable import Penumbra

/// IntelliJ's Start New Line (⇧⏎ in the IntelliJ keymap): the caret moves to the end of its
/// line and a language-aware Enter runs there, leaving the current line intact.
@MainActor
final class StartNewLineTests: XCTestCase {
    private func makeJavaTextView(_ input: String) -> TextView {
        let text = input.replacingOccurrences(of: "|", with: "")
        let textView = makeFocusedTextView(text: text)
        if let language = BundledLanguages.language(forIdentifier: "java") {
            textView.setState(TextViewState(text: text, theme: DefaultTheme(), language: language))
        }
        textView.indentStrategy = .space(length: 4)
        textView.keymap = .intelliJ
        var carets: [NSRange] = []
        var offset = 0
        for character in input.utf16 {
            if character == 0x7C {
                carets.append(NSRange(location: offset, length: 0))
            } else {
                offset += 1
            }
        }
        textView.selectedRanges = carets
        return textView
    }

    private func annotated(_ textView: TextView) -> String {
        let text = NSMutableString(string: textView.text)
        for range in textView.selectedRanges.sorted(by: { $0.location > $1.location }) {
            text.insert("|", at: range.location)
        }
        return text as String
    }

    private func pressShiftEnter(_ textView: TextView) {
        send(keyEvent(keyCode: 0x24, characters: "\r", flags: .shift), to: textView)
    }

    func testShiftEnterMidLineOpensIndentedLineBelow() {
        let textView = makeJavaTextView("class A {\n    void f(|) {\n    }\n}")
        pressShiftEnter(textView)
        XCTAssertEqual(annotated(textView), "class A {\n    void f() {\n        |\n    }\n}")
    }

    func testShiftEnterKeepsSelectedText() {
        let textView = makeJavaTextView("class A {\n    int x = 1;\n}")
        textView.selectedRange = NSRange(location: 14, length: 5)
        pressShiftEnter(textView)
        XCTAssertEqual(annotated(textView), "class A {\n    int x = 1;\n    |\n}")
    }

    func testShiftEnterAtEveryCaret() {
        let textView = makeJavaTextView("class A {\n    int |a;\n    int |b;\n}")
        pressShiftEnter(textView)
        XCTAssertEqual(annotated(textView), "class A {\n    int a;\n    |\n    int b;\n    |\n}")
    }

    func testShiftEnterIsOneUndoStep() {
        let textView = makeJavaTextView("class A {\n    int |a;\n}")
        let original = textView.text
        pressShiftEnter(textView)
        XCTAssertNotEqual(textView.text, original)
        textView.undoManager?.undo()
        XCTAssertEqual(textView.text, original)
    }

    func testShiftEnterDoesNothingWhenReadOnly() {
        let textView = makeJavaTextView("class A {\n    int |a;\n}")
        let original = textView.text
        textView.isEditable = false
        pressShiftEnter(textView)
        XCTAssertEqual(textView.text, original)
    }

    func testDefaultKeymapLeavesShiftEnterAsPlainLineBreak() {
        let textView = makeJavaTextView("ab|cd")
        textView.keymap = .default_
        pressShiftEnter(textView)
        XCTAssertEqual(annotated(textView), "ab\n|cd")
    }

    func testIntelliJKeymapBindsShiftEnter() {
        XCTAssertEqual(Keymap.intelliJ.action(for: KeyStroke(KeyChord(code: 0x24, .shift))), .startNewLine)
        XCTAssertNil(Keymap.default_.action(for: KeyStroke(KeyChord(code: 0x24, .shift))))
    }
}
