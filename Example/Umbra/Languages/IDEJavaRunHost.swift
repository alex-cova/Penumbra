import Foundation
import JavaIntelligence

/// What the Java run provider asks of its window. The window conforms (`IDEWorkspace`), and the
/// provider holds it weakly, so Run never keeps a window alive. Everything the provider shows or
/// stores goes through here: the window owns the tabs, the stores and the sheets.
@MainActor
protocol IDEJavaRunHost: AnyObject {
    var projectRootURL: URL? { get }
    /// The file Run and Debug apply to: the active editor's file, as of the last availability refresh.
    var runFileURL: URL? { get }
    var runConfigurationStore: JavaRunConfigurationCatalog { get }
    /// Every run configuration of the project, as the toolbar picker lists them.
    var runConfigurations: [JavaRunConfiguration] { get }
    var runSessions: IDERunSessions { get }
    var testResults: IDETestResultsStore { get }
    var problems: IDEProblemsStore { get }
    var notifications: IDENotificationCenter { get }
    /// The test class of the active file, kept by the gutter refresh.
    var activeJavaTestClass: JavaTestClass? { get }

    /// The text of `url` if it is open, unsaved edits included.
    func openBufferText(for url: URL) -> String?
    /// Re-reads the project's configurations and the last one into the picker.
    func refreshLastRunConfiguration()
    func showRunTab()
    func showGradleConsole()
    func showTestResults()
    func showProblems()
    /// Tells the user why a launch did not start (a line in the Gradle console, which is shown).
    func reportRunProblem(_ message: String)
    /// Opens Edit Configurations on `configuration` (a new entry if it is not saved yet).
    func openRunConfigurationDraft(_ configuration: JavaRunConfiguration)
    func promptForGradleRunTask(_ prompt: IDEGradleRunTaskPrompt)
    /// The debugger stays in the window: it is Java-only and shares the gutter and the tabs.
    func startDebugging(_ configuration: JavaRunConfiguration)
    func debugTests(scope: JavaTestRunScope, title: String, recording: JavaRunConfiguration?)
}
