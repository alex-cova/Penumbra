import Runestone

/// Umbra’s Sublime-style keymap: `Keymap.sublime` plus the host-owned rebinds the engine
/// preset does not ship (⌘D next occurrence, ⌘⇧D duplicate, ⌘⇧F Find in Files).
public enum UmbraKeymap {
    /// Host action for Find in Files. Runestone has no `EditorActionID.findInFiles`.
    public static let findInFiles = EditorActionID("findInFiles")

    /// Keymap Umbra assigns to editors when the Sublime preset is selected.
    public static let sublime: Keymap = {
        var map = Keymap.sublime
        map.unbindAll(.selectNextOccurrence)
        map.unbindAll(.duplicateLines)
        map.bind(KeyStroke(KeyChord("d", .command)), to: .selectNextOccurrence)
        map.bind(KeyStroke(KeyChord("d", [.command, .shift])), to: .duplicateLines)
        map.bind(KeyStroke(KeyChord("g", .command)), to: .goToLine)
        map.bind(KeyStroke(KeyChord("f", [.command, .shift])), to: findInFiles)
        return map
    }()
}
