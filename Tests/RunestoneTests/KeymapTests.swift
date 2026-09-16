import AppKit
import XCTest
@testable import Runestone

/// Covers the keystroke → action layer: chord resolution, two-step chords, the double-Shift
/// detector, and that the two shipped presets don't collide where they must differ.
final class KeymapTests: XCTestCase {
    private func event(_ characters: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 0) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        )!
    }

    func testSingleChordResolvesToAction() {
        var dispatcher = KeymapDispatcher()
        let result = dispatcher.resolve(event: event("d", [.command, .shift], keyCode: 0x02), keymap: .default_)
        XCTAssertEqual(result, .action(.selectNextOccurrence))
    }

    func testUnboundStrokeIsUnhandled() {
        var dispatcher = KeymapDispatcher()
        XCTAssertEqual(dispatcher.resolve(event: event("z", [.command], keyCode: 0x06), keymap: .default_), .unhandled)
    }

    func testTwoStepChordArmsThenCompletes() {
        var dispatcher = KeymapDispatcher()
        let first = dispatcher.resolve(event: event("k", .command, keyCode: 0x28), keymap: .default_, now: 100)
        XCTAssertEqual(first, .pendingChord)
        let second = dispatcher.resolve(event: event("d", .command, keyCode: 0x02), keymap: .default_, now: 100.5)
        XCTAssertEqual(second, .action(.skipCurrentOccurrence))
    }

    func testExpiredChordPrefixFallsBackToStandaloneResolution() {
        var dispatcher = KeymapDispatcher()
        _ = dispatcher.resolve(event: event("k", .command, keyCode: 0x28), keymap: .default_, now: 0)
        // 'd' alone with ⌘ after the window: not the chord, but ⌘D is bound on its own.
        let late = dispatcher.resolve(event: event("d", .command, keyCode: 0x02), keymap: .default_, now: 99)
        XCTAssertEqual(late, .action(.duplicateLines))
    }

    func testIntelliJKeymapRebindsConflictingShortcuts() {
        XCTAssertEqual(Keymap.default_.action(for: KeyStroke(KeyChord("l", .command))), .selectLines)
        XCTAssertEqual(Keymap.intelliJ.action(for: KeyStroke(KeyChord("l", .command))), .goToLine)
        XCTAssertEqual(Keymap.intelliJ.action(for: KeyStroke(KeyChord(code: 0x7E, .option))), .expandSelection)
        XCTAssertEqual(Keymap.intelliJ.action(for: KeyStroke(KeyChord("g", .control))), .selectNextOccurrence)
    }

    func testMarkdownPreviewShortcutOnShippedPresets() {
        XCTAssertEqual(Keymap.default_.action(for: KeyStroke(KeyChord("b", .command))), .toggleMarkdownPreview)
        XCTAssertEqual(Keymap.sublime.action(for: KeyStroke(KeyChord("b", .command))), .toggleMarkdownPreview)
        XCTAssertEqual(Keymap.intelliJ.action(for: KeyStroke(KeyChord("b", .command))), .toggleMarkdownPreview)
        XCTAssertEqual(Keymap.sublime.action(for: KeyStroke(KeyChord(code: 0x6F))), .goToDefinition)
        XCTAssertEqual(Keymap.intelliJ.action(for: KeyStroke(KeyChord(code: 0x6F))), .goToDefinition)
    }

    func testSublimeKeymapMatchesSublimeTextSemanticsForDAndF() {
        // Sublime Text binds ⌘D to Select Next Occurrence and ⌘⇧D to Duplicate Line — the
        // opposite of `default_`'s historical pair — plus ⌘⇧F for Find in Files.
        XCTAssertEqual(Keymap.sublime.action(for: KeyStroke(KeyChord("d", .command))), .selectNextOccurrence)
        XCTAssertEqual(Keymap.sublime.action(for: KeyStroke(KeyChord("d", [.command, .shift]))), .duplicateLines)
        XCTAssertEqual(Keymap.sublime.action(for: KeyStroke(KeyChord("f", [.command, .shift]))), .findInFiles)
        // `default_` and `intelliJ` keep the historical pair; only `sublime` overrides it.
        XCTAssertEqual(Keymap.default_.action(for: KeyStroke(KeyChord("d", .command))), .duplicateLines)
        XCTAssertEqual(Keymap.default_.action(for: KeyStroke(KeyChord("d", [.command, .shift]))), .selectNextOccurrence)
        XCTAssertEqual(Keymap.intelliJ.action(for: KeyStroke(KeyChord("d", .command))), .duplicateLines)
    }

    func testControlSpaceResolvesToTriggerCompletion() {
        XCTAssertEqual(
            Keymap.default_.action(for: KeyStroke(KeyChord(code: 0x31, .control))),
            .triggerCompletion
        )
        XCTAssertEqual(
            Keymap.intelliJ.action(for: KeyStroke(KeyChord(code: 0x31, .control))),
            .triggerCompletion
        )
        // Space is matched by key code, including when AppKit reports a character or none.
        var dispatcher = KeymapDispatcher()
        XCTAssertEqual(
            dispatcher.resolve(event: event(" ", .control, keyCode: 0x31), keymap: .default_),
            .action(.triggerCompletion)
        )
        XCTAssertEqual(
            dispatcher.resolve(event: event("", .control, keyCode: 0x31), keymap: .default_),
            .action(.triggerCompletion)
        )
        XCTAssertEqual(KeyChord(event: event(" ", .control, keyCode: 0x31)).displayString, "\u{2303}Space")
    }

    func testStrokeForActionIsInverseOfBinding() {
        let stroke = Keymap.intelliJ.stroke(for: .expandSelection)
        XCTAssertEqual(stroke, KeyStroke(KeyChord(code: 0x7E, .option)))
        XCTAssertEqual(stroke?.displayString, "\u{2325}\u{2191}")
    }

    func testArrowEventsMatchByKeyCodeNotCharacter() {
        // AppKit reports ↑ as a function-key code point; the chord must key off keyCode.
        let chord = KeyChord(event: event(String(UnicodeScalar(0xF700)!), .option, keyCode: 0x7E))
        XCTAssertEqual(chord.key, .code(0x7E))
        XCTAssertEqual(chord.modifiers, .option)
    }

    func testDoubleShiftDetectorFiresOnSecondTapWithinWindow() {
        var detector = DoubleModifierDetector()
        func flags(_ f: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: f, timestamp: 0,
                             windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                             isARepeat: false, keyCode: 56)!
        }
        XCTAssertFalse(detector.handleFlagsChanged(flags(.shift), now: 0))   // press 1
        XCTAssertFalse(detector.handleFlagsChanged(flags([]), now: 0.1))     // release 1
        XCTAssertTrue(detector.handleFlagsChanged(flags(.shift), now: 0.2))  // press 2 -> fire
    }

    func testDoubleShiftDetectorResetsAfterOtherInput() {
        var detector = DoubleModifierDetector()
        func flags(_ f: NSEvent.ModifierFlags, _ t: TimeInterval) -> Bool {
            detector.handleFlagsChanged(
                NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: f, timestamp: 0,
                                 windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                 isARepeat: false, keyCode: 56)!,
                now: t
            )
        }
        _ = flags(.shift, 0)
        _ = flags([], 0.1)
        detector.noteOtherInput()
        XCTAssertFalse(flags(.shift, 0.15), "A key press between taps must cancel the double-Shift")
    }
}
