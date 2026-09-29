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
            XCTAssertEqual(shortcut(.zoomIn, preset), KeyboardShortcut("=", modifiers: .command))
            XCTAssertEqual(shortcut(.zoomOut, preset), KeyboardShortcut("-", modifiers: .command))
            XCTAssertNil(shortcut(.nextSplit, preset))
            XCTAssertNil(shortcut(.debugStepInto, preset), "The debugger keys are IntelliJ's; other presets use the menu")
        }
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
        XCTAssertEqual(shortcut(.toggleSourceControl, preset), KeyboardShortcut("9"))
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
