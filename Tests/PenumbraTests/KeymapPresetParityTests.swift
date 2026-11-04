import XCTest
@testable import Penumbra

/// F28: every preset reaches every action (the command palette is bound in each), has the navigation,
/// folding and rename keys, and the VS Code preset carries VS Code's macOS keys.
final class KeymapPresetParityTests: XCTestCase {
    private let presets: [(name: String, keymap: Keymap)] = [
        ("default_", .default_), ("sublime", .sublime), ("vsCode", .vsCode), ("intelliJ", .intelliJ)
    ]

    private func stroke(_ chord: KeyChord) -> KeyStroke { KeyStroke(chord) }

    func testEveryPresetCanOpenTheCommandPaletteAndQuickOpen() {
        // Find Action lists every action, with its key, so a preset that binds it reaches them all.
        for (name, keymap) in presets {
            XCTAssertNotNil(keymap.stroke(for: .findAction), "\(name) has no key for Find Action")
            XCTAssertNotNil(keymap.stroke(for: .quickOpenFile), "\(name) has no key for Go to File")
        }
    }

    func testEveryPresetBindsNavigationFoldingRenameAndProblems() {
        let needed: [EditorActionID] = [
            .navigateBack, .navigateForward, .collapseRegion, .expandRegion, .collapseAllRegions, .expandAllRegions,
            .rename, .goToNextProblem, .goToPreviousProblem, .findNext, .findPrevious, .goToLine, .goToDefinition
        ]
        for (name, keymap) in presets {
            for action in needed {
                XCTAssertNotNil(keymap.stroke(for: action), "\(name) has no key for \(action.rawValue)")
            }
        }
    }

    func testIntelliJIsUntouchedByTheNewDefaults() {
        // IntelliJ starts from the historical set, not from `default_`, so what `default_` gained
        // (⌘P, ⌘G, F4, ⌘K chords…) does not leak into it.
        XCTAssertEqual(Keymap.intelliJ.bindings.count, 83)
        XCTAssertNil(Keymap.intelliJ.action(for: stroke(KeyChord("p", [.command, .shift]))))
        XCTAssertEqual(Keymap.intelliJ.action(for: stroke(KeyChord("g", .command))), .findNext)
        XCTAssertNil(Keymap.intelliJ.action(for: stroke(KeyChord(code: 0x76))), "F4 is not Next Problem in IntelliJ (F2 is)")
        XCTAssertFalse(Keymap.intelliJ.isChordPrefix(KeyChord("k", .command)), "⌘K is Commit in IntelliJ, not a chord prefix")
    }

    func testTheHistoricalBindingsAreStillInDefault() {
        XCTAssertEqual(Keymap.default_.action(for: stroke(KeyChord("d", .command))), .duplicateLines)
        XCTAssertEqual(Keymap.default_.action(for: stroke(KeyChord("l", .command))), .goToLine)
        XCTAssertEqual(
            Keymap.default_.chordedAction(prefix: KeyChord("k", .command), second: KeyChord("d", .command)), .skipCurrentOccurrence
        )
    }

    func testSublimeAndDefaultFoldWithSublimesKeys() {
        for keymap in [Keymap.default_, .sublime] {
            XCTAssertEqual(keymap.action(for: stroke(KeyChord(code: 0x21, [.command, .option]))), .collapseRegion)
            XCTAssertEqual(keymap.action(for: stroke(KeyChord(code: 0x1E, [.command, .option]))), .expandRegion)
            XCTAssertEqual(keymap.chordedAction(prefix: KeyChord("k", .command), second: KeyChord("1", .command)), .collapseAllRegions)
            XCTAssertEqual(keymap.chordedAction(prefix: KeyChord("k", .command), second: KeyChord("j", .command)), .expandAllRegions)
            XCTAssertEqual(keymap.action(for: stroke(KeyChord(code: 0x61, .shift))), .rename)
            XCTAssertEqual(keymap.action(for: stroke(KeyChord(code: 0x76))), .goToNextProblem)
            XCTAssertEqual(keymap.action(for: stroke(KeyChord(code: 0x76, .shift))), .goToPreviousProblem)
        }
        // ⌘G is Go to Line in the Sublime column, so Find Next moves; Default keeps ⌘G for it.
        XCTAssertEqual(Keymap.default_.action(for: stroke(KeyChord("g", .command))), .findNext)
        XCTAssertEqual(Keymap.sublime.action(for: stroke(KeyChord("g", .command))), .goToLine)
        XCTAssertEqual(Keymap.sublime.action(for: stroke(KeyChord("g", [.command, .option]))), .findNext)
        XCTAssertEqual(Keymap.sublime.action(for: stroke(KeyChord("g", [.command, .option, .shift]))), .findPrevious)
        XCTAssertNotEqual(Keymap.sublime.action(for: stroke(KeyChord("g", [.command, .shift]))), .findPrevious)
    }

    func testVSCodeKeysForTheActionsPenumbraImplements() {
        let map = Keymap.vsCode
        let expected: [(KeyChord, EditorActionID)] = [
            (KeyChord("p", .command), .quickOpenFile), (KeyChord("p", [.command, .shift]), .findAction),
            (KeyChord("f", [.command, .shift]), .findInFiles), (KeyChord("g", .command), .findNext),
            (KeyChord("g", .control), .goToLine), (KeyChord("t", .command), .goToSymbol),
            (KeyChord("o", [.command, .shift]), .goToFileSymbol),
            (KeyChord(code: 0x6F), .goToDefinition), (KeyChord(code: 0x6F, .command), .goToImplementation),
            (KeyChord(code: 0x6F, .shift), .findUsages), (KeyChord(code: 0x78), .rename),
            (KeyChord(code: 0x64), .goToNextProblem), (KeyChord(code: 0x64, .shift), .goToPreviousProblem),
            (KeyChord("-", .control), .navigateBack), (KeyChord("-", [.control, .shift]), .navigateForward),
            (KeyChord(".", .command), .showContextActions), (KeyChord("/", .command), .toggleComment),
            (KeyChord(code: 0x7E, .option), .moveLineUp), (KeyChord(code: 0x7D, .option), .moveLineDown),
            (KeyChord("k", [.command, .shift]), .deleteLines), (KeyChord("d", .command), .selectNextOccurrence),
            (KeyChord("l", [.command, .shift]), .selectAllOccurrences), (KeyChord("l", .command), .selectLines),
            (KeyChord(code: 0x21, .command), .outdentLines), (KeyChord(code: 0x1E, .command), .indentLines),
            (KeyChord(code: 0x21, [.command, .option]), .collapseRegion), (KeyChord(code: 0x1E, [.command, .option]), .expandRegion)
        ]
        for (chord, action) in expected {
            XCTAssertEqual(map.action(for: stroke(chord)), action, "\(chord.displayString)")
        }
        let chords: [(KeyChord, EditorActionID)] = [
            (KeyChord("d", .command), .skipCurrentOccurrence), (KeyChord("0", .command), .collapseAllRegions),
            (KeyChord("j", .command), .expandAllRegions), (KeyChord(code: 0x21, .command), .collapseRegionRecursively),
            (KeyChord(code: 0x1E, .command), .expandRegionRecursively), (KeyChord("i", .command), .quickDocumentation)
        ]
        for (second, action) in chords {
            XCTAssertEqual(map.chordedAction(prefix: KeyChord("k", .command), second: second), action, "⌘K \(second.displayString)")
        }
    }

    func testVSCodeIsItsOwnSetNotDefaultPlusExtras() {
        // ⌘D selects the next occurrence in VS Code (it duplicates a line in `default_`), and the
        // historical ⇧⌘D / ⌘⌫ keys are not VS Code's.
        XCTAssertEqual(Keymap.vsCode.action(for: stroke(KeyChord("d", .command))), .selectNextOccurrence)
        XCTAssertNil(Keymap.vsCode.action(for: stroke(KeyChord("d", [.command, .shift]))))
        XCTAssertNil(Keymap.vsCode.action(for: stroke(KeyChord(code: 0x33, .command))))
    }
}
