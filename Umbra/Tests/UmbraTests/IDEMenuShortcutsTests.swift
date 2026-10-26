import AppKit
import SwiftUI
import XCTest
@testable import Penumbra
@testable import Umbra

/// Menu shortcuts are handled before the editor sees a key, so they have to agree with the
/// selected preset's `Keymap` and not collide with each other.
final class IDEMenuShortcutsTests: XCTestCase {
    private func shortcut(_ command: IDEMenuCommand, _ preset: KeymapPreset) -> KeyboardShortcut? {
        IDEMenuShortcuts.shortcut(for: command, in: preset)
    }

    /// The `KeyChord` a menu shortcut produces, so it can be compared with a `Keymap` binding.
    private func chord(of shortcut: KeyboardShortcut) -> KeyChord {
        var modifiers: KeyChord.Modifiers = []
        if shortcut.modifiers.contains(.command) { modifiers.insert(.command) }
        if shortcut.modifiers.contains(.option) { modifiers.insert(.option) }
        if shortcut.modifiers.contains(.control) { modifiers.insert(.control) }
        if shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
        if shortcut.key == .return { return KeyChord(code: 0x24, modifiers) }
        if shortcut.key.character == Character(UnicodeScalar(NSF2FunctionKey)!) {
            return KeyChord(code: 0x78, modifiers)
        }
        if shortcut.key.character == Character(UnicodeScalar(NSF12FunctionKey)!) {
            return KeyChord(code: 0x6F, modifiers)
        }
        if shortcut.key.character == Character(UnicodeScalar(NSF3FunctionKey)!) {
            return KeyChord(code: 0x63, modifiers)
        }
        if shortcut.key.character == Character(UnicodeScalar(NSF8FunctionKey)!) {
            return KeyChord(code: 0x64, modifiers)
        }
        // The keymaps bind the brackets by key code.
        if shortcut.key.character == "[" { return KeyChord(code: 0x21, modifiers) }
        if shortcut.key.character == "]" { return KeyChord(code: 0x1E, modifiers) }
        if shortcut.key == .downArrow { return KeyChord(code: 0x7D, modifiers) }
        if shortcut.key == .upArrow { return KeyChord(code: 0x7E, modifiers) }
        return KeyChord(String(shortcut.key.character), modifiers)
    }

    func testNoTwoCommandsShareAShortcutWithinAPreset() {
        for preset in KeymapPreset.allCases {
            var seen: [KeyboardShortcut: IDEMenuCommand] = [:]
            for command in IDEMenuCommand.allCases {
                guard let shortcut = shortcut(command, preset) else { continue }
                if let other = seen[shortcut] {
                    XCTFail("\(preset): \(command) and \(other) both use \(chord(of: shortcut).displayString)")
                }
                seen[shortcut] = command
            }
        }
    }

    func testSublimeAndDefaultColumnsKeepTheShippedShortcuts() {
        for preset in [KeymapPreset.sublime, .default_] {
            XCTAssertEqual(shortcut(.goToFile, preset), KeyboardShortcut("p"))
            XCTAssertEqual(shortcut(.goToSymbol, preset), KeyboardShortcut("r"))
            XCTAssertEqual(shortcut(.openFolder, preset), KeyboardShortcut("o", modifiers: [.command, .shift]))
            XCTAssertEqual(shortcut(.commandPalette, preset), KeyboardShortcut("p", modifiers: [.command, .shift]))
            XCTAssertEqual(shortcut(.sendHTTPRequest, preset), KeyboardShortcut("r", modifiers: [.command, .shift]))
            XCTAssertEqual(shortcut(.toggleSidebar, preset), KeyboardShortcut("0"))
            XCTAssertEqual(shortcut(.toggleProblems, preset), KeyboardShortcut("m", modifiers: [.command, .shift]))
            XCTAssertNil(shortcut(.recentLocations, preset))
            XCTAssertNil(shortcut(.gitPush, preset))
            XCTAssertNil(shortcut(.replaceInFiles, preset), "⇧⌘R is Send Request in these presets")
            XCTAssertNil(shortcut(.gitRevert, preset))
            XCTAssertNil(shortcut(.recentChanges, preset), "⌥⇧C is the IntelliJ keymap's Recent Changes")
            XCTAssertEqual(shortcut(.zoomIn, preset), KeyboardShortcut("=", modifiers: .command))
            XCTAssertEqual(shortcut(.zoomOut, preset), KeyboardShortcut("-", modifiers: .command))
            XCTAssertNil(shortcut(.nextSplit, preset))
            XCTAssertNil(shortcut(.debugStepInto, preset), "The debugger keys are IntelliJ's; other presets use the menu")
        }
    }

    func testSaveAllIsOptionCommandSExceptInIntelliJWhereCommandSIsSaveAll() {
        for preset in [KeymapPreset.sublime, .default_] {
            XCTAssertEqual(shortcut(.save, preset), KeyboardShortcut("s"))
            XCTAssertEqual(shortcut(.saveAll, preset), KeyboardShortcut("s", modifiers: [.command, .option]))
            XCTAssertNil(shortcut(.reloadAllFromDisk, preset))
        }
        XCTAssertNil(shortcut(.save, .intelliJ), "⌘S saves everything in IntelliJ")
        XCTAssertEqual(shortcut(.saveAll, .intelliJ), KeyboardShortcut("s"))
        XCTAssertEqual(shortcut(.reloadAllFromDisk, .intelliJ), KeyboardShortcut("y", modifiers: [.command, .option]))
    }

    func testEveryPresetSwitchesTabsWithTheMacStandardKeys() {
        for preset in KeymapPreset.allCases {
            XCTAssertEqual(shortcut(.nextTab, preset), KeyboardShortcut("]", modifiers: [.command, .shift]), "\(preset)")
            XCTAssertEqual(shortcut(.previousTab, preset), KeyboardShortcut("[", modifiers: [.command, .shift]), "\(preset)")
        }
    }

    func testIntelliJColumnUsesIntelliJKeys() {
        let preset = KeymapPreset.intelliJ
        XCTAssertNil(shortcut(.openFolder, preset), "⇧⌘O is Go to File in IntelliJ")
        XCTAssertEqual(shortcut(.fileStructure, preset), KeyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF12FunctionKey)!)), modifiers: .command))
        XCTAssertEqual(shortcut(.goToSymbol, preset), KeyboardShortcut("o", modifiers: [.command, .option]))
        XCTAssertEqual(shortcut(.goToFile, preset), KeyboardShortcut("o", modifiers: [.command, .shift]))
        XCTAssertEqual(shortcut(.commandPalette, preset), KeyboardShortcut("a", modifiers: [.command, .shift]))
        XCTAssertEqual(shortcut(.recentLocations, preset), KeyboardShortcut("e", modifiers: [.command, .shift]))
        XCTAssertEqual(shortcut(.sendHTTPRequest, preset), KeyboardShortcut(.return, modifiers: .control))
        XCTAssertEqual(shortcut(.parameterInfo, preset), KeyboardShortcut("p"))
        XCTAssertEqual(shortcut(.replaceInFiles, preset), KeyboardShortcut("r", modifiers: [.command, .shift]))
        XCTAssertEqual(shortcut(.gitPull, preset), KeyboardShortcut("t", modifiers: .command))
        XCTAssertEqual(shortcut(.gitPush, preset), KeyboardShortcut("k", modifiers: [.command, .shift]))
        XCTAssertEqual(shortcut(.gitRevert, preset), KeyboardShortcut("z", modifiers: [.command, .option]))
        XCTAssertNil(shortcut(.gitFileHistory, preset), "IntelliJ has no default key for file history")
        XCTAssertEqual(shortcut(.nextSplit, preset), KeyboardShortcut(.tab, modifiers: .option))
        XCTAssertEqual(shortcut(.previousSplit, preset), KeyboardShortcut(.tab, modifiers: [.option, .shift]))
        XCTAssertEqual(shortcut(.toggleDebugTool, preset), KeyboardShortcut("5", modifiers: .command))
        XCTAssertEqual(shortcut(.hideAllToolWindows, preset),
                       KeyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF12FunctionKey)!)), modifiers: [.command, .shift]))
        XCTAssertNil(shortcut(.zoomIn, preset), "⌘= and ⌘- fold and unfold in IntelliJ, which has no zoom key")
        XCTAssertNil(shortcut(.zoomOut, preset))
        XCTAssertEqual(shortcut(.debugStepOver, preset), KeyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF8FunctionKey)!)), modifiers: []))
        XCTAssertEqual(shortcut(.debugStepInto, preset), KeyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF7FunctionKey)!)), modifiers: []))
        XCTAssertEqual(shortcut(.debugStepOut, preset), KeyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF8FunctionKey)!)), modifiers: .shift))
        XCTAssertEqual(shortcut(.debugResume, preset), KeyboardShortcut("r", modifiers: [.command, .option]))
        XCTAssertEqual(shortcut(.debugStop, preset), KeyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!)), modifiers: .command))
        XCTAssertNil(shortcut(.debugPause, preset), "IntelliJ has no default key for Pause")
        XCTAssertEqual(shortcut(.toggleSidebar, preset), KeyboardShortcut("1"))
        XCTAssertEqual(shortcut(.toggleProblems, preset), KeyboardShortcut("6"))
        XCTAssertEqual(shortcut(.toggleStructure, preset), KeyboardShortcut("7"))
        XCTAssertEqual(shortcut(.toggleSourceControl, preset), KeyboardShortcut("k"), "⌘K is Commit in IntelliJ")
        XCTAssertTrue(
            IDEMenuShortcuts.secondaryShortcuts(in: preset).contains { $0.command == .toggleSourceControl && $0.key == "9" && $0.modifiers == .command },
            "⌘9 (Version Control) still shows Changes"
        )
        XCTAssertNil(
            Keymap.intelliJ.action(for: KeyStroke(KeyChord("k", .command), KeyChord("d", .command))),
            "⌘K is the Changes shortcut, so the ⌘K ⌘D chord is unbound"
        )
        XCTAssertEqual(shortcut(.recentChanges, preset), KeyboardShortcut("c", modifiers: [.option, .shift]))
    }

    func testIntelliJGivesShiftCommandRToReplaceInFilesNotToSendRequest() {
        // ⇧⌘R is Replace in Path under IntelliJ; Send Request moved to ⌃↵ to free it.
        let reserved = KeyboardShortcut("r", modifiers: [.command, .shift])
        XCTAssertEqual(shortcut(.replaceInFiles, .intelliJ), reserved)
        XCTAssertNotEqual(shortcut(.sendHTTPRequest, .intelliJ), reserved)
    }

    func testRevealActiveFileNoLongerSharesEncapsulateFieldKeyInIntelliJ() {
        XCTAssertNotEqual(shortcut(.revealActiveFile, .intelliJ), shortcut(.encapsulateField, .intelliJ))
    }

    /// A menu command that mirrors a `Keymap` action must use the key the preset binds it to,
    /// or the menu shadows the keymap with a different key.
    func testIntelliJMenuShortcutsAgreeWithTheIntelliJKeymap() {
        let mirrored: [(IDEMenuCommand, EditorActionID)] = [
            (.goToFile, .quickOpenFile),
            (.goToSymbol, .goToSymbol),
            (.fileStructure, .goToFileSymbol),
            (.goToLine, .goToLine),
            (.recentLocations, .recentLocations),
            (.commandPalette, .findAction),
            (.findInFiles, .findInFiles),
            (.parameterInfo, .showParameterInfo),
            (.goToTypeDefinition, .goToTypeDefinition),
            (.nextProblem, .goToNextProblem),
            (.previousProblem, .goToPreviousProblem),
            (.replace, .toggleReplacePanel),
            (.find, .toggleFindPanel)
        ]
        for (command, action) in mirrored {
            guard let menuShortcut = shortcut(command, .intelliJ) else {
                XCTFail("\(command) has no IntelliJ menu shortcut")
                continue
            }
            XCTAssertEqual(
                Keymap.intelliJ.action(for: KeyStroke(chord(of: menuShortcut))),
                action,
                "\(command) uses \(chord(of: menuShortcut).displayString), which the IntelliJ keymap binds differently"
            )
        }
    }

    // MARK: - Bookmarks and navigation

    private let f2 = KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!))
    private let f3 = KeyEquivalent(Character(UnicodeScalar(NSF3FunctionKey)!))
    private let f8 = KeyEquivalent(Character(UnicodeScalar(NSF8FunctionKey)!))

    func testSublimeAndDefaultBookmarkKeysAreSublimes() {
        for preset in [KeymapPreset.sublime, .default_] {
            XCTAssertEqual(shortcut(.toggleBookmark, preset), KeyboardShortcut(f2, modifiers: .command))
            XCTAssertEqual(shortcut(.showBookmarks, preset), KeyboardShortcut(f2, modifiers: [.command, .shift]))
            XCTAssertEqual(shortcut(.nextBookmark, preset), KeyboardShortcut(f2, modifiers: []))
            XCTAssertEqual(shortcut(.previousBookmark, preset), KeyboardShortcut(f2, modifiers: .shift))
            XCTAssertNil(shortcut(.toggleBookmarkWithMnemonic, preset))
            XCTAssertEqual(shortcut(.toggleBreakpoint, preset), KeyboardShortcut(f3, modifiers: []), "F3 stays the breakpoint key here")
        }
    }

    func testIntelliJBookmarkKeysAreIntelliJsAndBreakpointsMoveToCommandF8() {
        XCTAssertEqual(shortcut(.toggleBookmark, .intelliJ), KeyboardShortcut(f3, modifiers: []))
        XCTAssertEqual(shortcut(.toggleBookmarkWithMnemonic, .intelliJ), KeyboardShortcut(f3, modifiers: .option))
        XCTAssertEqual(shortcut(.showBookmarks, .intelliJ), KeyboardShortcut(f3, modifiers: .command))
        XCTAssertEqual(shortcut(.nextBookmark, .intelliJ), KeyboardShortcut(.downArrow, modifiers: [.control, .option]))
        XCTAssertEqual(shortcut(.previousBookmark, .intelliJ), KeyboardShortcut(.upArrow, modifiers: [.control, .option]))
        XCTAssertEqual(shortcut(.toggleBreakpoint, .intelliJ), KeyboardShortcut(f8, modifiers: .command))
        XCTAssertFalse(
            IDEMenuShortcuts.secondaryShortcuts(in: .intelliJ).contains { $0.command == .toggleBreakpoint },
            "⌘F8 is the menu key now, not a secondary one"
        )
    }

    func testNoMenuShortcutShadowsAnEditorKeymapBindingOfAnotherAction() {
        // Menu keys are handled before the editor, so a menu command on a key the keymap binds to
        // something else would silently replace that action.
        let navigation: [(IDEMenuCommand, EditorActionID?)] = [
            (.navigateBack, .navigateBack), (.navigateForward, .navigateForward),
            (.toggleBookmark, nil), (.toggleBookmarkWithMnemonic, nil), (.showBookmarks, nil),
            (.nextBookmark, nil), (.previousBookmark, nil)
        ]
        for preset in KeymapPreset.allCases {
            for (command, mirrored) in navigation {
                guard let menuShortcut = shortcut(command, preset) else { continue }
                let bound = preset.keymap.action(for: KeyStroke(chord(of: menuShortcut)))
                // A command that mirrors an editor action may sit on a key the preset leaves
                // unbound (the menu then adds it); any other binding would be shadowed.
                let agrees = bound == nil || bound == mirrored
                XCTAssertTrue(agrees, "\(preset): \(command) uses \(chord(of: menuShortcut).displayString), bound to \(String(describing: bound))")
                if mirrored == nil { XCTAssertNil(bound) }
            }
        }
    }

    func testIntelliJKeymapBindsTheNavigationActions() {
        let keymap = Keymap.intelliJ
        XCTAssertEqual(keymap.action(for: KeyStroke(KeyChord(code: 0x33, [.command, .shift]))), .lastEditLocation)
        XCTAssertEqual(keymap.action(for: KeyStroke(KeyChord(code: 0x7D, .control))), .nextMethod)
        XCTAssertEqual(keymap.action(for: KeyStroke(KeyChord(code: 0x7E, .control))), .previousMethod)
        XCTAssertEqual(keymap.action(for: KeyStroke(KeyChord(code: 0x7D, [.control, .option, .shift]))), .nextChange)
        XCTAssertEqual(keymap.action(for: KeyStroke(KeyChord(code: 0x7E, [.control, .option, .shift]))), .previousChange)
        XCTAssertEqual(keymap.action(for: KeyStroke(KeyChord(code: 0x21, [.command, .option]))), .moveToCodeBlockStart)
        XCTAssertEqual(keymap.action(for: KeyStroke(KeyChord(code: 0x1E, [.command, .option]))), .moveToCodeBlockEnd)
        XCTAssertEqual(keymap.action(for: KeyStroke(KeyChord(code: 0x21, [.command, .option, .shift]))), .selectToCodeBlockStart)
        XCTAssertEqual(keymap.action(for: KeyStroke(KeyChord(code: 0x1E, [.command, .option, .shift]))), .selectToCodeBlockEnd)
    }

    func testFileStructureMenuUsesCommandF12InEveryPreset() {
        let commandF12 = KeyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF12FunctionKey)!)), modifiers: .command)
        for preset in KeymapPreset.allCases {
            XCTAssertEqual(shortcut(.fileStructure, preset), commandF12, "\(preset)")
        }
    }

    func testIntelliJKeymapBindsFindInFilesAndFileStructure() {
        XCTAssertEqual(Keymap.intelliJ.action(for: KeyStroke(KeyChord("f", [.command, .shift]))), .findInFiles)
        XCTAssertEqual(Keymap.intelliJ.action(for: KeyStroke(KeyChord(code: 0x6F, .command))), .goToFileSymbol)
    }
}
