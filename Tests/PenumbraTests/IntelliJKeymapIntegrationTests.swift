import AppKit
import XCTest
import TestTreeSitterLanguages
import TreeSitter
@testable import Penumbra

/// End-to-end checks that keymap actions reach real `TextView` behaviour, and that switching
/// to `.intelliJ` doesn't disturb the bindings shared with `.default_`.
@MainActor
final class IntelliJKeymapIntegrationTests: XCTestCase {
    private func flagsEvent(_ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags, timestamp: 0,
                         windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                         isARepeat: false, keyCode: 56)!
    }

    func testOptionUpArrowExpandsSelectionWithoutTreeSitter() {
        let textView = makeFocusedTextView(text: "hello world")
        textView.keymap = .intelliJ
        textView.selectedRange = NSRange(location: 2, length: 0)

        send(keyEvent(keyCode: TestKeyCode.upArrow, flags: .option), to: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 5), "First expand selects the word")

        send(keyEvent(keyCode: TestKeyCode.upArrow, flags: .option), to: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 11), "Second expand selects the line")

        send(keyEvent(keyCode: TestKeyCode.downArrow, flags: .option), to: textView)
        XCTAssertEqual(textView.selectedRange, NSRange(location: 0, length: 5), "Shrink steps back to the word")
    }

    func testControlShiftJJoinsLines() {
        let textView = makeFocusedTextView(text: "let a = 1\n    let b = 2")
        textView.keymap = .intelliJ
        textView.selectedRange = NSRange(location: 0, length: 0)

        send(keyEvent(keyCode: TestKeyCode.letterJ, characters: "j", flags: [.control, .shift]), to: textView)

        XCTAssertEqual(textView.text, "let a = 1 let b = 2")
    }

    func testJoinLinesIsMultiCaretAware() {
        let textView = makeFocusedTextView(text: "a1\n  a2\nGAP\nb1\n  b2\n")
        // A caret on line 0 ("a1") and a caret on line 3 ("b1", offset 12).
        textView.selectedRanges = [NSRange(location: 0, length: 0), NSRange(location: 12, length: 0)]
        XCTAssertTrue(textView.isMultiCursorActive)

        textView.perform(.joinLines)

        XCTAssertEqual(textView.text, "a1 a2\nGAP\nb1 b2\n")
        XCTAssertEqual(textView.selectedRanges.count, 2, "One caret per join point")
    }

    func testCommandLRoutesToGoToLineActionUnderIntelliJKeymap() {
        let textView = makeFocusedTextView(text: "a\nb\nc")
        textView.keymap = .intelliJ
        var received: EditorActionID?
        textView.editorActionHandler = { action in
            received = action
            return true
        }
        send(keyEvent(keyCode: TestKeyCode.letterL, characters: "l", flags: .command), to: textView)
        XCTAssertEqual(received, .goToLine)
    }

    func testCommandLInvokesGoToLineUnderDefaultKeymap() {
        let textView = makeFocusedTextView(text: "a\nb\nc")
        var received: EditorActionID?
        textView.editorActionHandler = { action in
            received = action
            return true
        }
        send(keyEvent(keyCode: TestKeyCode.letterL, characters: "l", flags: .command), to: textView)
        XCTAssertEqual(received, .goToLine)
    }

    func testCommandDStillDuplicatesUnderIntelliJKeymap() {
        let textView = makeFocusedTextView(text: "row")
        textView.keymap = .intelliJ
        textView.selectedRange = NSRange(location: 0, length: 0)
        send(keyEvent(keyCode: TestKeyCode.letterD, characters: "d", flags: .command), to: textView)
        XCTAssertEqual(textView.text, "row\nrow")
    }

    func testColumnSelectionModeTogglePersistsAcrossSelectionAssignment() {
        let textView = makeFocusedTextView(text: "aaaa\nbbbb\ncccc")
        textView.keymap = .intelliJ
        textView.selectedRange = NSRange(location: 0, length: 0)

        send(keyEvent(keyCode: TestKeyCode.digit8, characters: "8", flags: [.command, .shift]), to: textView)
        XCTAssertTrue(textView.isBlockSelectionActive, "⌘⇧8 starts a sticky block selection")

        send(keyEvent(keyCode: TestKeyCode.downArrow, flags: []), to: textView)
        XCTAssertTrue(textView.isBlockSelectionActive, "Arrow keys keep growing the block, not tear it down")

        send(keyEvent(keyCode: TestKeyCode.digit8, characters: "8", flags: [.command, .shift]), to: textView)
        XCTAssertFalse(textView.isBlockSelectionActive, "A second ⌘⇧8 exits the mode")
    }

    func testDoubleShiftInvokesGoToFileAction() {
        let textView = makeFocusedTextView(text: "x")
        textView.keymap = .intelliJ
        var received: EditorActionID?
        textView.editorActionHandler = { action in
            received = action
            return true
        }
        send(flagsEvent(.shift), to: textView)
        send(flagsEvent([]), to: textView)
        send(flagsEvent(.shift), to: textView)
        XCTAssertEqual(received, .quickOpenFile)
    }

    func testPerformDrivesActionsProgrammatically() {
        let textView = makeFocusedTextView(text: "one\ntwo\nthree")
        textView.selectedRange = NSRange(location: 5, length: 0)
        XCTAssertTrue(textView.perform(.selectLines))
        XCTAssertEqual(textView.selectedRange, NSRange(location: 4, length: 4))
    }

    func testSurroundSelectionWrapsWithUniversalTemplate() {
        let textView = makeFocusedTextView(text: "value")
        textView.selectedRange = NSRange(location: 0, length: 5)
        let braces = SurroundTemplate.universal.first { $0.id == "braces" }!
        textView.surroundSelection(with: braces)
        XCTAssertEqual(textView.text, "{value}")
    }

    // MARK: - Tree-sitter backed

    private func makeJavaScriptTextView(_ text: String) -> TextView {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let textView = TextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        textView.isEditable = true
        window.contentView = textView
        window.makeKeyAndOrderFront(nil)
        let language = TreeSitterLanguage(tree_sitter_javascript(), highlightsQuery: nil,
                                          injectionsQuery: nil, indentationScopes: nil)
        textView.setState(TextViewState(text: text, language: language, parsePolicy: .eager))
        textView.layoutIfNeeded()
        _ = textView.focusTextInput()
        return textView
    }

    func testExpandSelectionClimbsSyntaxNodes() {
        let textView = makeJavaScriptTextView("function greet() {\n  return value + 1;\n}\n")
        textView.keymap = .intelliJ
        guard let caret = textView.text.range(of: "value") else { return XCTFail() }
        let offset = textView.text.utf16.distance(from: textView.text.utf16.startIndex,
                                                  to: caret.lowerBound.samePosition(in: textView.text.utf16)!)
        textView.selectedRange = NSRange(location: offset, length: 0)

        send(keyEvent(keyCode: TestKeyCode.upArrow, flags: .option), to: textView)
        let afterWord = textView.selectedRange
        XCTAssertEqual((textView.text as NSString).substring(with: afterWord), "value")

        send(keyEvent(keyCode: TestKeyCode.upArrow, flags: .option), to: textView)
        let afterExpr = textView.selectedRange
        XCTAssertGreaterThan(afterExpr.length, afterWord.length, "Second expand climbs to an enclosing node")
        XCTAssertEqual((textView.text as NSString).substring(with: afterExpr), "value + 1",
                       "Second expand selects the binary expression")

        send(keyEvent(keyCode: TestKeyCode.upArrow, flags: .option), to: textView)
        XCTAssertGreaterThan(textView.selectedRange.length, afterExpr.length, "Third expand climbs again")

        send(keyEvent(keyCode: TestKeyCode.downArrow, flags: .option), to: textView)
        XCTAssertEqual(textView.selectedRange, afterExpr, "Shrink returns to the binary expression")
        send(keyEvent(keyCode: TestKeyCode.downArrow, flags: .option), to: textView)
        XCTAssertEqual(textView.selectedRange, afterWord, "Shrink again returns to the word")
    }

    func testMoveStatementRelocatesWholeBlock() {
        let source = "const a = 1;\nif (a) {\n  doThing();\n}\nconst b = 2;\n"
        let textView = makeJavaScriptTextView(source)
        textView.keymap = .intelliJ
        // Caret on the `if` line.
        let ifOffset = (source as NSString).range(of: "if (a)").location
        textView.selectedRange = NSRange(location: ifOffset, length: 0)

        send(keyEvent(keyCode: TestKeyCode.downArrow, flags: [.command, .shift]), to: textView)

        // The entire if-block should now sit after `const b = 2;`.
        let lines = textView.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(lines.first, "const a = 1;")
        XCTAssertTrue(textView.text.contains("const b = 2;\nif (a) {"))
    }
}
