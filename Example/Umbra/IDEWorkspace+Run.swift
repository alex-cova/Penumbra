import AppKit
import EditorIntelligence
import Foundation
import JavaIntelligence

/// The window's side of Run: the Run tab, the sessions, the temporary and saved configurations and the
/// Edit Configurations dialog. What starting a program takes (validation, the before-launch steps, the
/// build, the JDK, the process) is the Java run provider's (`IDEJavaRunProvider`); these are the
/// window's views of it.
extension IDEWorkspace {
    typealias LaunchProgress = IDEJavaRunProvider.LaunchProgress

    // MARK: - The Run tab

    func selectRunTab() {
        isRunSelected = true
        if !isTerminalVisible {
            isTerminalVisible = true
            saveSession()
        }
    }

    func closeRunSession(_ id: UUID) {
        runs.close(id)
        if !runs.hasContent, isRunSelected { isRunSelected = false }
    }

    /// Runs `session` again in the same tab, with the settings it has now.
    func rerun(_ session: IDERunSession) {
        runProviders.provider(id: session.providerID)?.rerun(session)
    }

    // MARK: - Starting

    /// Runs a compiled class or a single file in a console of the Run tab (see `IDEJavaRunProvider`).
    @discardableResult
    func startRunSession(_ configuration: JavaRunConfiguration, replacing explicit: IDERunSession? = nil) -> IDERunSession? {
        javaRun.startRunSession(configuration, replacing: explicit)
    }

    func validationProblems(for configuration: JavaRunConfiguration) -> [JavaRunConfigurationValidator.Problem] {
        javaRun.validationProblems(for: configuration)
    }

    func usesNewLaunchProtocol(_ configuration: JavaRunConfiguration) -> Bool {
        javaRun.usesNewLaunchProtocol(configuration)
    }
}

// MARK: - ⌥↩ Run actions

extension IDEWorkspace {
    /// Carries out a Run, Debug or Modify Run Configuration chosen in the ⌥↩ menu on a `main`, a
    /// test method or a test class of the active file.
    func performRunCodeAction(_ command: CodeActionCommand) {
        guard let file = workbench.activePane.selectedDocument?.url else { return }
        let paneID = workbench.activePaneID
        javaRun.performRunCodeAction(command, file: file, source: host(for: paneID).textView.text)
    }

    var hasTemporaryRunConfigurationSelected: Bool { lastRunConfiguration?.isTemporary == true }

    func saveSelectedTemporaryRunConfiguration() {
        if let id = lastRunConfiguration?.id { saveTemporaryRunConfiguration(id) }
    }

    /// Save Configuration: keeps a temporary configuration of the picker.
    func saveTemporaryRunConfiguration(_ id: UUID) {
        runConfigurationStore.makePermanent(id, forProject: project.rootURL)
        refreshLastRunConfiguration()
    }
}

// MARK: - Edit Configurations

extension IDEWorkspace {
    /// The dialog's working copy: every configuration of the project and the templates, opened on
    /// `draft` (added as a new entry when it is not saved yet).
    func makeRunConfigurationsEditor(highlighting draft: JavaRunConfiguration?) -> IDERunConfigurationsEditor {
        let root = project.rootURL
        var templates: [JavaRunConfiguration.Kind: JavaRunConfiguration] = [:]
        for kind in JavaRunConfiguration.Kind.allCases {
            templates[kind] = runConfigurationStore.template(for: kind, forProject: root)
        }
        return IDERunConfigurationsEditor(
            configurations: runConfigurationStore.configurations(forProject: root),
            templates: templates,
            highlighting: draft
        )
    }

    /// What a new configuration of `kind` launches before the user fills it in: the active file when
    /// there is one.
    func defaultTarget(for kind: JavaRunConfiguration.Kind) -> JavaRunConfiguration.Target {
        javaRun.defaultTarget(for: kind)
    }

    /// Writes the dialog's changes to the stores and refreshes the picker. `select` becomes the
    /// selected configuration, so Run Last Configuration repeats what was just edited.
    func applyRunConfigurationEdits(_ changes: IDERunConfigurationsEditor.Changes, select: UUID?) {
        let root = project.rootURL
        for id in changes.deleted { runConfigurationStore.delete(id, forProject: root) }
        for configuration in changes.saved { runConfigurationStore.save(configuration, forProject: root) }
        for template in changes.templates { runConfigurationStore.setTemplate(template, forProject: root) }
        if let select { runConfigurationStore.select(select, forProject: root) }
        refreshLastRunConfiguration()
    }

    /// The validator's findings for a configuration of the dialog, judged against the dialog's own
    /// list (a before-launch step may name a configuration that is not saved yet).
    func validationProblems(for configuration: JavaRunConfiguration, among others: [JavaRunConfiguration]) -> [JavaRunConfigurationValidator.Problem] {
        javaRun.validationProblems(for: configuration, among: others)
    }
}
