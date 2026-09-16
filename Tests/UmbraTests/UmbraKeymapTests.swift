import Runestone
import XCTest
@testable import UmbraCore

final class UmbraKeymapTests: XCTestCase {
    func testUmbraOverlayDoesNotEditEngineSublimePreset() {
        XCTAssertEqual(
            Keymap.sublime.action(for: KeyStroke(KeyChord("d", .command))),
            .duplicateLines
        )
        XCTAssertEqual(
            Keymap.sublime.action(for: KeyStroke(KeyChord("d", [.command, .shift]))),
            .selectNextOccurrence
        )
        XCTAssertEqual(
            UmbraKeymap.sublime.action(for: KeyStroke(KeyChord("d", .command))),
            .selectNextOccurrence
        )
        XCTAssertEqual(
            UmbraKeymap.sublime.action(for: KeyStroke(KeyChord("d", [.command, .shift]))),
            .duplicateLines
        )
    }

    func testSublimeKeymapBindsDefiningShortcuts() {
        let map = UmbraKeymap.sublime
        XCTAssertEqual(
            map.action(for: KeyStroke(KeyChord("d", .command))),
            .selectNextOccurrence
        )
        XCTAssertEqual(
            map.action(for: KeyStroke(KeyChord("d", [.command, .shift]))),
            .duplicateLines
        )
        XCTAssertEqual(
            map.action(for: KeyStroke(KeyChord("g", .command))),
            .goToLine
        )
        XCTAssertEqual(
            map.action(for: KeyStroke(KeyChord("f", [.command, .shift]))),
            UmbraKeymap.findInFiles
        )
    }

    func testSublimeKeymapKeepsFilePaletteAndSymbolShortcuts() {
        let map = UmbraKeymap.sublime
        XCTAssertEqual(
            map.action(for: KeyStroke(KeyChord("p", .command))),
            .quickOpenFile
        )
        XCTAssertEqual(
            map.action(for: KeyStroke(KeyChord("p", [.command, .shift]))),
            .findAction
        )
        XCTAssertEqual(
            map.action(for: KeyStroke(KeyChord("r", .command))),
            .goToSymbol
        )
    }

    func testFindInFilesAndGoToLineAreOnTheCommandSurface() {
        XCTAssertEqual(UmbraKeymap.findInFiles.rawValue, "findInFiles")
        XCTAssertEqual(EditorActionID.goToLine.rawValue, "goToLine")
        XCTAssertEqual(
            UmbraKeymap.sublime.stroke(for: UmbraKeymap.findInFiles),
            KeyStroke(KeyChord("f", [.command, .shift]))
        )
        XCTAssertEqual(
            UmbraKeymap.sublime.stroke(for: .goToLine),
            KeyStroke(KeyChord("g", .command))
        )
    }

    func testUmbraMenusWireFindInFilesAndGoToLine() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Example/Umbra/UmbraApp.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(appSource.contains("Find in Files…"), "Find menu must expose Find in Files")
        XCTAssertTrue(appSource.contains("showFindInFiles"), "Find in Files must call the workspace command")
        XCTAssertTrue(appSource.contains("Go to Line…"), "Go menu must expose Go to Line")
        XCTAssertTrue(appSource.contains("showGoToLine"), "Go to Line must call the workspace command")
        XCTAssertTrue(
            appSource.contains("keyboardShortcut(\"f\", modifiers: [.command, .shift])"),
            "Find in Files must be bound to ⌘⇧F"
        )
        XCTAssertTrue(
            appSource.contains("keyboardShortcut(\"g\")"),
            "Go to Line must be bound to ⌘G"
        )
        XCTAssertTrue(appSource.contains("showQuickOpen"), "⌘P Go to File must stay wired")
        XCTAssertTrue(appSource.contains("showCommandPalette"), "⌘⇧P Command Palette must stay wired")
        XCTAssertTrue(appSource.contains("showGoToSymbol"), "⌘R Go to Symbol must stay wired")

        let workspaceSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Example/Umbra/IDEWorkspace.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(workspaceSource.contains("FindInFilesService.search"))
        XCTAssertTrue(workspaceSource.contains("FindInFilesService.openTarget"))
        XCTAssertTrue(workspaceSource.contains("GoToLineCommand.apply"))
        XCTAssertTrue(workspaceSource.contains("UmbraKeymap.findInFiles"))

        let preferencesSource = try String(
            contentsOf: repoRoot.appendingPathComponent("Example/Umbra/IDEPreferences.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            preferencesSource.contains("UmbraKeymap.sublime"),
            "Sublime preset must assign UmbraKeymap.sublime to editors"
        )
    }
}
