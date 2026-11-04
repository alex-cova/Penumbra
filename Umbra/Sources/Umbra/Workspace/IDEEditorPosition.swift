import Foundation
import Observation

/// Where the caret is, for the status bar: line, column and how much is selected. These change on
/// every keystroke and every caret move, and nothing but the status bar's position text reads them,
/// so they live in an object of their own. Kept on `IDEWorkspace`, they made the whole status bar
/// (the breadcrumb, module items, the language and encoding pickers) re-evaluate on each key
/// (F21): a view that reads `workspace.statusLine` is invalidated by the workspace, a view that
/// reads `workspace.position.line` only by this.
@MainActor
@Observable
final class IDEEditorPosition {
    var line = 1
    var column = 1
    var selectionLength = 0
}
