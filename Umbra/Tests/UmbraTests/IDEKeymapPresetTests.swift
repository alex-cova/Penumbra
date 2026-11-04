import AppKit
import SwiftUI
import XCTest
@testable import Penumbra
@testable import Umbra

/// F28: a menu key equivalent is handled before the editor, so it silently replaces whatever the
/// preset's `Keymap` binds on the same key. These hold every preset's menu column and keymap to
/// each other, which is what a new preset (VS Code) must not break.
final class IDEKeymapPresetTests: XCTestCase {
    private func chord(of shortcut: KeyboardShortcut) -> KeyChord {
        var modifiers: KeyChord.Modifiers = []
        if shortcut.modifiers.contains(.command) { modifiers.insert(.command) }
        if shortcut.modifiers.contains(.option) { modifiers.insert(.option) }
        if shortcut.modifiers.contains(.control) { modifiers.insert(.control) }
        if shortcut.modifiers.contains(.shift) { modifiers.insert(.shift) }
        let functionKeys: [(Int, UInt16)] = [
            (NSF1FunctionKey, 0x7A), (NSF2FunctionKey, 0x78), (NSF3FunctionKey, 0x63), (NSF4FunctionKey, 0x76),
            (NSF5FunctionKey, 0x60), (NSF6FunctionKey, 0x61), (NSF7FunctionKey, 0x62), (NSF8FunctionKey, 0x64),
            (NSF9FunctionKey, 0x65), (NSF10FunctionKey, 0x6D), (NSF12FunctionKey, 0x6F)
        ]
        for (scalar, code) in functionKeys where shortcut.key.character == Character(UnicodeScalar(scalar)!) {
            return KeyChord(code: code, modifiers)
        }
        switch shortcut.key {
        case .return: return KeyChord(code: 0x24, modifiers)
        case .space: return KeyChord(code: 0x31, modifiers)
        case .downArrow: return KeyChord(code: 0x7D, modifiers)
        case .upArrow: return KeyChord(code: 0x7E, modifiers)
        case .leftArrow: return KeyChord(code: 0x7B, modifiers)
        case .rightArrow: return KeyChord(code: 0x7C, modifiers)
        default: break
        }
        // The keymaps bind the brackets by key code.
        if shortcut.key.character == "[" { return KeyChord(code: 0x21, modifiers) }
        if shortcut.key.character == "]" { return KeyChord(code: 0x1E, modifiers) }
        return KeyChord(String(shortcut.key.character), modifiers)
    }

    /// Menu commands that do what a keymap action does, so a keymap binding on the same key is the
    /// menu item's own key rather than something it shadows.
    private let mirrored: [IDEMenuCommand: EditorActionID] = [
        .find: .toggleFindPanel, .replace: .toggleReplacePanel, .findInFiles: .findInFiles,
        .goToFile: .quickOpenFile, .goToSymbol: .goToSymbol, .fileStructure: .goToFileSymbol, .goToLine: .goToLine,
        .commandPalette: .findAction, .recentLocations: .recentLocations,
        .nextProblem: .goToNextProblem, .previousProblem: .goToPreviousProblem,
        .navigateBack: .navigateBack, .navigateForward: .navigateForward,
        .showContextActions: .showContextActions, .parameterInfo: .showParameterInfo,
        .goToTypeDefinition: .goToTypeDefinition, .markdownPreview: .toggleMarkdownPreview,
        .extractVariable: .extractVariable, .extractField: .extractField, .extractConstant: .extractConstant,
        .extractMethod: .extractMethod, .inlineVariable: .inlineVariable, .encapsulateField: .encapsulateField
    ]

    func testNoMenuShortcutShadowsADifferentKeymapActionInAnyPreset() {
        for preset in KeymapPreset.allCases {
            for command in IDEMenuCommand.allCases {
                guard let shortcut = IDEMenuShortcuts.shortcut(for: command, in: preset) else { continue }
                let key = chord(of: shortcut)
                guard let bound = preset.keymap.action(for: KeyStroke(key)) else { continue }
                XCTAssertEqual(
                    bound, mirrored[command],
                    "\(preset): the \(command) menu key \(key.displayString) hides the keymap's \(bound.rawValue)"
                )
            }
        }
    }

    func testNoChordEndsInAKeyAMenuHandlesFirst() {
        // The second key of ⌘K ⌘x is a ⌘ key; if a menu item owns it, AppKit runs the menu and the
        // chord never completes.
        for preset in KeymapPreset.allCases {
            let menuChords = Set(IDEMenuCommand.allCases.compactMap { command in
                IDEMenuShortcuts.shortcut(for: command, in: preset).map { chord(of: $0) }
            } + IDEMenuShortcuts.secondaryShortcuts(in: preset).map {
                KeyChord($0.key, KeyChord.Modifiers(flags: $0.modifiers))
            })
            for (stroke, action) in preset.keymap.bindings where stroke.chords.count == 2 {
                let second = stroke.chords[1]
                XCTAssertFalse(
                    menuChords.contains(second),
                    "\(preset): \(stroke.displayString) (\(action.rawValue)) ends in \(second.displayString), which a menu item takes first"
                )
            }
        }
    }

    func testEveryPresetCarriesItsKeymapAndMenuColumn() {
        XCTAssertEqual(KeymapPreset.allCases.map(\.rawValue), ["sublime", "default_", "intelliJ", "vsCode"])
        XCTAssertEqual(KeymapPreset.vsCode.title, "Visual Studio Code")
        XCTAssertEqual(KeymapPreset.vsCode.keymap.bindings, Keymap.vsCode.bindings)
        let vsCode = KeymapPreset.vsCode
        XCTAssertEqual(IDEMenuShortcuts.shortcut(for: .goToSymbol, in: vsCode), KeyboardShortcut("t"))
        XCTAssertEqual(IDEMenuShortcuts.shortcut(for: .goToLine, in: vsCode), KeyboardShortcut("g", modifiers: .control))
        XCTAssertEqual(IDEMenuShortcuts.shortcut(for: .navigateBack, in: vsCode), KeyboardShortcut("-", modifiers: .control))
        XCTAssertNil(IDEMenuShortcuts.shortcut(for: .openFolder, in: vsCode), "⇧⌘O is the file outline in VS Code")
        XCTAssertEqual(IDEMenuShortcuts.shortcut(for: .toggleSidebar, in: vsCode), KeyboardShortcut("b"))
        // Unchanged from the shared column.
        XCTAssertEqual(IDEMenuShortcuts.shortcut(for: .goToFile, in: vsCode), KeyboardShortcut("p"))
        XCTAssertEqual(IDEMenuShortcuts.shortcut(for: .save, in: vsCode), KeyboardShortcut("s"))
    }

    func testTheSublimeAndDefaultMenusKeepTheKeysTheFoldChordsRelyOn() {
        // ⌘K ⌘1 / ⌘K ⌘J end in keys no menu item may take in these presets.
        for preset in [KeymapPreset.sublime, .default_] {
            for command in IDEMenuCommand.allCases {
                guard let shortcut = IDEMenuShortcuts.shortcut(for: command, in: preset) else { continue }
                XCTAssertNotEqual(chord(of: shortcut), KeyChord("1", .command), "\(preset) \(command)")
                XCTAssertNotEqual(chord(of: shortcut), KeyChord("j", .command), "\(preset) \(command)")
            }
        }
    }

    func testTheLanguageServersLeaveTheOutlineToTheNativeProviders() {
        // F26 gave the LSP service a documentSymbol outline; claiming `.structure` here would put it in
        // front of SwiftStructureProvider / TypeScriptStructureProvider while the server is connected.
        XCTAssertFalse(IDESourceKitServer.features.contains(.structure))
        XCTAssertFalse(IDETypeScriptServer.features.contains(.structure))
    }
}

private extension KeyChord.Modifiers {
    init(flags: NSEvent.ModifierFlags) {
        var result: KeyChord.Modifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        self = result
    }
}
