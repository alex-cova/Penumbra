import SwiftUI
import XCTest
@testable import Penumbra
@testable import Umbra

/// The configurable Go to File shortcut: every key must actually open Quick Open,
/// taken keys are freed, double-tap stays a no-op in the keymap, and the menu shows
/// the chosen key while the displaced item loses its shortcut.
@MainActor
final class GoToFileShortcutTests: XCTestCase {
    func testEveryKeyOpensQuickOpenInEveryPreset() {
        for preset in KeymapPreset.allCases {
            for shortcut in GoToFileShortcut.allCases {
                var map = preset.keymap
                shortcut.apply(to: &map)
                if let stroke = shortcut.keyStroke {
                    XCTAssertEqual(
                        map.action(for: stroke), .quickOpenFile,
                        "\(shortcut.title) in \(preset.title) should open Quick Open"
                    )
                }
            }
        }
    }

    func testChoosingCommandPUnbindsParameterInfoInIntelliJ() {
        var map = KeymapPreset.intelliJ.keymap
        let stroke = KeyStroke(KeyChord("p", .command))
        XCTAssertEqual(map.action(for: stroke), .showParameterInfo, "precondition: ⌘P is Parameter Info")

        GoToFileShortcut.commandP.apply(to: &map)

        XCTAssertEqual(map.action(for: stroke), .quickOpenFile)
    }

    func testDoubleShiftLeavesTheKeymapAlone() {
        for preset in KeymapPreset.allCases {
            var map = preset.keymap
            let before = map
            GoToFileShortcut.doubleShift.apply(to: &map)
            XCTAssertEqual(map.bindings, before.bindings, "double-tap changes nothing in \(preset.title)")
        }
        XCTAssertTrue(GoToFileShortcut.doubleShift.doubleShiftEnabled)
        XCTAssertFalse(GoToFileShortcut.commandP.doubleShiftEnabled)
    }

    func testMenuShowsTheChosenKey() {
        XCTAssertEqual(
            IDEMenuShortcuts.shortcut(for: .goToFile, in: .sublime, goToFile: .commandShiftO),
            KeyboardShortcut("o", modifiers: [.command, .shift])
        )
        XCTAssertEqual(
            IDEMenuShortcuts.shortcut(for: .goToFile, in: .intelliJ, goToFile: .commandP),
            KeyboardShortcut("p", modifiers: .command)
        )
    }

    func testMenuFreesTheDisplacedShortcut() {
        // Sublime's Open Folder held ⇧⌘O; IntelliJ's Parameter Info held ⌘P.
        XCTAssertNil(IDEMenuShortcuts.shortcut(for: .openFolder, in: .sublime, goToFile: .commandShiftO))
        XCTAssertNil(IDEMenuShortcuts.shortcut(for: .parameterInfo, in: .intelliJ, goToFile: .commandP))
    }

    func testMenuWithoutOverrideKeepsPresetDefaults() {
        XCTAssertEqual(
            IDEMenuShortcuts.shortcut(for: .goToFile, in: .sublime),
            KeyboardShortcut("p", modifiers: .command)
        )
        XCTAssertEqual(
            IDEMenuShortcuts.shortcut(for: .goToFile, in: .intelliJ),
            KeyboardShortcut("o", modifiers: [.command, .shift])
        )
        XCTAssertNotNil(IDEMenuShortcuts.shortcut(for: .openFolder, in: .sublime))
    }
}
