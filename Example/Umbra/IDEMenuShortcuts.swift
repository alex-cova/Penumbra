import SwiftUI

/// Menu items whose shortcut depends on the selected ``KeymapPreset``.
///
/// SwiftUI menu key equivalents are handled before the editor sees a key, so a shortcut written
/// on a menu item shadows the preset's `Keymap` binding for the same keys. Every command whose
/// key differs between presets goes through ``IDEMenuShortcuts`` instead of a literal
/// `.keyboardShortcut`. Editor-level actions (duplicate line, toggle comment, …) are not listed:
/// they live in `Keymap` and are dispatched by the text view.
enum IDEMenuCommand: CaseIterable, Hashable {
    // File
    case newFile, openFile, openFolder, save, saveAs, closeTab
    // Edit
    case find, replace, findInFiles, replaceInFiles
    // Go
    case goToFile, goToSymbol, fileStructure, goToLine, recentLocations, commandPalette, nextProblem, previousProblem
    // Java
    case showContextActions, parameterInfo, goToTypeDefinition
    case extractVariable, extractField, extractConstant, extractMethod
    case inlineVariable, encapsulateField
    case runLastConfiguration, debugLastConfiguration
    // Git
    case gitPull, gitPush, gitFileHistory, gitRevert
    // Run
    case toggleBreakpoint, debugResume, debugPause, debugStepOver, debugStepInto, debugStepOut, debugStop
    // HTTP
    case sendHTTPRequest
    // View
    case splitRight, splitDown
    case toggleSidebar, toggleStructure, revealActiveFile, markdownPreview
    case toggleTerminal, toggleProblems, toggleSourceControl
    case newTerminalTab, nextTerminalTab, previousTerminalTab
    case nextTab, previousTab, nextSplit, previousSplit
    case toggleDebugTool, hideAllToolWindows
    case zoomIn, zoomOut, resetZoom
}

/// The menu shortcut of each ``IDEMenuCommand`` under each ``KeymapPreset``.
///
/// The Sublime and Default columns are the shortcuts Umbra has always shipped. The IntelliJ
/// column starts from the same table and applies IntelliJ IDEA's macOS keys where they differ;
/// a `nil` entry there removes a shortcut that would clash with an IntelliJ binding.
enum IDEMenuShortcuts {
    static func shortcut(for command: IDEMenuCommand, in preset: KeymapPreset) -> KeyboardShortcut? {
        switch preset {
        case .sublime, .default_:
            return base[command] ?? nil
        case .intelliJ:
            if let override = intelliJOverrides[command] {
                return override
            }
            return base[command] ?? nil
        }
    }

    private static let functionKey12 = KeyEquivalent(Character(UnicodeScalar(NSF12FunctionKey)!))
    private static let functionKey1 = KeyEquivalent(Character(UnicodeScalar(NSF1FunctionKey)!))
    private static let functionKey2 = KeyEquivalent(Character(UnicodeScalar(NSF2FunctionKey)!))
    private static let functionKey7 = KeyEquivalent(Character(UnicodeScalar(NSF7FunctionKey)!))
    private static let functionKey8 = KeyEquivalent(Character(UnicodeScalar(NSF8FunctionKey)!))

    private static let base: [IDEMenuCommand: KeyboardShortcut?] = [
        .newFile: KeyboardShortcut("n"),
        .openFile: KeyboardShortcut("o"),
        .openFolder: KeyboardShortcut("o", modifiers: [.command, .shift]),
        .save: KeyboardShortcut("s"),
        .saveAs: KeyboardShortcut("s", modifiers: [.command, .shift]),
        .closeTab: KeyboardShortcut("w"),
        .find: KeyboardShortcut("f"),
        .replace: KeyboardShortcut("f", modifiers: [.command, .option]),
        .findInFiles: KeyboardShortcut("f", modifiers: [.command, .shift]),
        .goToFile: KeyboardShortcut("p"),
        .goToSymbol: KeyboardShortcut("r"),
        .goToLine: KeyboardShortcut("l"),
        .commandPalette: KeyboardShortcut("p", modifiers: [.command, .shift]),
        .showContextActions: KeyboardShortcut(.return, modifiers: .option),
        .parameterInfo: nil,
        .replaceInFiles: nil,
        .gitPull: nil,
        .gitPush: nil,
        .gitFileHistory: nil,
        .gitRevert: nil,
        .nextSplit: nil,
        .previousSplit: nil,
        .toggleDebugTool: nil,
        .hideAllToolWindows: nil,
        .resetZoom: nil,
        .toggleBreakpoint: nil,
        .debugResume: nil,
        .debugPause: nil,
        .debugStepOver: nil,
        .debugStepInto: nil,
        .debugStepOut: nil,
        .debugStop: nil,
        .fileStructure: nil,
        .nextProblem: nil,
        .previousProblem: nil,
        .goToTypeDefinition: nil,
        .extractVariable: KeyboardShortcut("v", modifiers: [.command, .option]),
        .extractField: KeyboardShortcut("f", modifiers: [.command, .option, .shift]),
        .extractConstant: KeyboardShortcut("c", modifiers: [.command, .option]),
        .extractMethod: KeyboardShortcut("m", modifiers: [.command, .option]),
        .inlineVariable: KeyboardShortcut("n", modifiers: [.command, .option]),
        .encapsulateField: KeyboardShortcut("e", modifiers: [.command, .option]),
        .runLastConfiguration: KeyboardShortcut("r", modifiers: [.control, .option]),
        .debugLastConfiguration: KeyboardShortcut("d", modifiers: [.control, .option]),
        .sendHTTPRequest: KeyboardShortcut("r", modifiers: [.command, .shift]),
        .splitRight: KeyboardShortcut("\\", modifiers: .command),
        .splitDown: KeyboardShortcut("\\", modifiers: [.command, .shift]),
        .toggleSidebar: KeyboardShortcut("0", modifiers: .command),
        .toggleStructure: KeyboardShortcut("7", modifiers: .command),
        // ⌥⌘E is Encapsulate Field (Java menu); two items cannot share it, so Reveal has no key.
        .revealActiveFile: nil,
        .markdownPreview: KeyboardShortcut("b", modifiers: .command),
        .toggleTerminal: KeyboardShortcut("`", modifiers: .control),
        .toggleProblems: KeyboardShortcut("m", modifiers: [.command, .shift]),
        .toggleSourceControl: KeyboardShortcut("g", modifiers: [.command, .control]),
        .newTerminalTab: KeyboardShortcut("`", modifiers: [.control, .shift]),
        // macOS's standard tab switching, and the usual editor zoom keys.
        .nextTab: KeyboardShortcut("]", modifiers: [.command, .shift]),
        .previousTab: KeyboardShortcut("[", modifiers: [.command, .shift]),
        .zoomIn: KeyboardShortcut("=", modifiers: .command),
        .zoomOut: KeyboardShortcut("-", modifiers: .command),
        .nextTerminalTab: KeyboardShortcut(.rightArrow, modifiers: [.control, .option]),
        .previousTerminalTab: KeyboardShortcut(.leftArrow, modifiers: [.control, .option])
    ]

    /// IntelliJ IDEA's macOS keys. ⇧⌘O is Go to File there (the keymap binds it, and the menu
    /// used to take it for Open Folder), ⇧⌘A is Find Action, ⌘F12 is File Structure, and tool
    /// windows are numbered (⌘1 Project, ⌘6 Problems, ⌘7 Structure, ⌘9 Version Control, ⌥F12
    /// Terminal). ⌃↵ runs the HTTP request at the caret, which frees ⇧⌘R for Replace in Files.
    private static let intelliJOverrides: [IDEMenuCommand: KeyboardShortcut?] = [
        .openFolder: nil,
        .goToFile: KeyboardShortcut("o", modifiers: [.command, .shift]),
        .goToSymbol: KeyboardShortcut("o", modifiers: [.command, .option]),
        .fileStructure: KeyboardShortcut(functionKey12, modifiers: .command),
        .parameterInfo: KeyboardShortcut("p"),
        // ⌘= / ⌘- fold and unfold in IntelliJ, and it has no zoom key.
        .zoomIn: nil,
        .zoomOut: nil,
        // Next / Previous Splitter.
        .nextSplit: KeyboardShortcut(.tab, modifiers: .option),
        .previousSplit: KeyboardShortcut(.tab, modifiers: [.option, .shift]),
        .toggleDebugTool: KeyboardShortcut("5", modifiers: .command),
        .hideAllToolWindows: KeyboardShortcut(functionKey12, modifiers: [.command, .shift]),
        // ⇧⌘R is Replace in Path in IntelliJ; Send Request moved to ⌃↵ to free it.
        .replaceInFiles: KeyboardShortcut("r", modifiers: [.command, .shift]),
        // IntelliJ's Update Project, Push and Rollback. History has no default key.
        .gitPull: KeyboardShortcut("t", modifiers: .command),
        .gitPush: KeyboardShortcut("k", modifiers: [.command, .shift]),
        .gitRevert: KeyboardShortcut("z", modifiers: [.command, .option]),
        // IntelliJ's debugger keys. Pause has no default key there.
        .toggleBreakpoint: KeyboardShortcut(functionKey8, modifiers: .command),
        .debugResume: KeyboardShortcut("r", modifiers: [.command, .option]),
        .debugStepOver: KeyboardShortcut(functionKey8, modifiers: []),
        .debugStepInto: KeyboardShortcut(functionKey7, modifiers: []),
        .debugStepOut: KeyboardShortcut(functionKey8, modifiers: .shift),
        .debugStop: KeyboardShortcut(functionKey2, modifiers: .command),
        .nextProblem: KeyboardShortcut(functionKey2, modifiers: []),
        .previousProblem: KeyboardShortcut(functionKey2, modifiers: .shift),
        .goToTypeDefinition: KeyboardShortcut("b", modifiers: [.control, .shift]),
        .recentLocations: KeyboardShortcut("e", modifiers: [.command, .shift]),
        .commandPalette: KeyboardShortcut("a", modifiers: [.command, .shift]),
        .sendHTTPRequest: KeyboardShortcut(.return, modifiers: .control),
        .toggleSidebar: KeyboardShortcut("1", modifiers: .command),
        .toggleProblems: KeyboardShortcut("6", modifiers: .command),
        .toggleSourceControl: KeyboardShortcut("9", modifiers: .command),
        .toggleTerminal: KeyboardShortcut(functionKey12, modifiers: .option),
        // ⌥⌘E is Encapsulate Field in IntelliJ; Select In Project View is ⌥F1.
        .revealActiveFile: KeyboardShortcut(functionKey1, modifiers: .option)
    ]
}

extension View {
    /// Applies the shortcut `command` has under `preset`, or none when the preset leaves it unbound.
    func menuShortcut(_ command: IDEMenuCommand, in preset: KeymapPreset) -> some View {
        keyboardShortcut(IDEMenuShortcuts.shortcut(for: command, in: preset))
    }
}
