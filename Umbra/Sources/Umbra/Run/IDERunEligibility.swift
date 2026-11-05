import Foundation
import JavaIntelligence
import Observation

/// What the window worked out about the active editor once typing pauses: whether Run, Test and
/// HTTP Send apply, and to which file (F-11). The settle-time refreshes on `IDEWorkspace` write
/// these; the toolbar, menus, run providers and coverage read them. Views observe the store
/// through the workspace, the same nesting as the structure and problems stores.
@MainActor
@Observable
final class IDERunEligibility {
    /// The file Run and Debug apply to: the active editor's file, as of the last availability refresh.
    var runFileURL: URL?
    /// True when the active editor has something to launch: the file itself, or a Gradle `run` task.
    var runFileCanRun = false
    /// True when the active editor is a Java test source file with discovered tests.
    var javaFileCanTest = false
    /// The test class of the active file, kept by the gutter refresh.
    var activeJavaTestClass: JavaTestClass?
    /// True when the active editor is an HTTP request file with a parsable request at the caret.
    var httpFileCanSend = false
}
