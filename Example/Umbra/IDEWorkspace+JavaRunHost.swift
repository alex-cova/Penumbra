import Foundation
import JavaIntelligence

/// The window as `IDEJavaRunProvider` sees it: the project, the stores, the tabs and the sheets it
/// owns. Mostly names the window already had; the rest are the window's answers to a provider that
/// must not know how the window is built.
extension IDEWorkspace: IDEJavaRunHost {
    var projectRootURL: URL? { project.rootURL }
    var runFileURL: URL? { javaRunFileURL }
    var runSessions: IDERunSessions { runs }

    func showRunTab() {
        showBottomTab(.run)
    }

    func showGradleConsole() {
        showGradleOutput()
    }

    func openRunConfigurationDraft(_ configuration: JavaRunConfiguration) {
        runConfigurationDraft = configuration
    }

    func promptForGradleRunTask(_ prompt: IDEGradleRunTaskPrompt) {
        gradleRunTaskPrompt = prompt
    }

    func startDebugging(_ configuration: JavaRunConfiguration) {
        debugLaunch(configuration)
    }
}
