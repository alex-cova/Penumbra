import AppKit
import EditorIntelligence
import Foundation
import JavaIntelligence
import Penumbra

/// The window's side of Run: the Run tab, the sessions, the temporary and saved configurations and the
/// Edit Configurations dialog. What starting a program takes (validation, the before-launch steps, the
/// build, the JDK, the process) is the Java run provider's (`IDEJavaRunProvider`); these are the
/// window's views of it.
extension IDEWorkspace {
    typealias LaunchProgress = IDEJavaRunProvider.LaunchProgress

    // MARK: - The Run tab

    func closeRunSession(_ id: UUID) {
        runs.close(id)
        if !runs.hasContent, isBottomTabSelected(.run) { deselectBottomTab(.run) }
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

    // MARK: - Run and Debug actions

    var runHelp: String {
        activeRunProvider?.runHelp(fileURL: runFileURL) ?? javaRun.runHelp(fileURL: runFileURL)
    }

    var debugHelp: String {
        (activeRunProvider ?? javaRun).debugHelp(fileURL: runFileURL, canRun: runFileCanRun)
    }

    var runFileCanDebug: Bool {
        runFileCanRun && (activeRunProvider ?? javaRun).canDebug(fileURL: runFileURL)
    }

    var isRunActive: Bool {
        runProviders.hasActiveWork || debugSession.isActive || dapDebugSession.isActive || runs.isAnyActive
    }

    public func buildGradleProject() {
        guard let system = projectSystems.active, project.rootURL != nil else { return }
        if let tab = system.consoleTab {
            showBottomTab(tab)
        }
        system.build()
    }

    public func runActiveFile() {
        startActiveFile(mode: .run)
    }

    public func debugActiveFile() {
        guard runFileCanDebug else { return }
        startActiveFile(mode: .debug)
    }

    /// The play and bug buttons: what the active file's run provider starts by default.
    private func startActiveFile(mode: IDERunMode) {
        guard runFileCanRun, let provider = activeRunProvider, let document = activeRunDocument() else { return }
        provider.run(document, mode: mode)
    }

    func stopRunning() {
        runProviders.stopAll()
        runs.stopAll()
        if debugSession.isActive || dapDebugSession.isActive || gradleDebugActive {
            stopDebugging()
        }
    }

    func chooseGradleRunTask(_ taskName: String) {
        guard let prompt = gradleRunTaskPrompt else { return }
        gradleRunTaskPrompt = nil
        javaRun.chooseGradleRunTask(taskName, for: prompt)
    }

    func dismissGradleRunTaskPrompt() {
        gradleRunTaskPrompt = nil
    }

    /// Reruns the last launched configuration, whatever file is active.
    func runLastRunConfiguration() {
        guard let lastRunConfiguration else { return }
        launch(lastRunConfiguration)
    }

    /// Opens the run configuration sheet for the active file's launch, or for the last one when
    /// the active file can't be launched.
    func editRunConfiguration() {
        runConfigurationsEditor = makeRunConfigurationsEditor(
            highlighting: javaRun.activeRunConfiguration() ?? lastRunConfiguration
        )
    }

    var canEditRunConfiguration: Bool {
        project.rootURL != nil || runFileCanRun || lastRunConfiguration != nil
    }

    func dismissRunConfigurationSheet() {
        runConfigurationsEditor = nil
    }

    func launch(_ configuration: JavaRunConfiguration) {
        javaRun.launch(configuration)
    }

    // MARK: - Run / Debug in context

    /// Runs (or debugs) what the caret is in, through the active document's run provider. Anywhere
    /// else, and in a file with no run provider, it repeats the last configuration, so the key is
    /// never dead.
    func runInContext(debug: Bool) {
        Task { @MainActor [self] in
            if let provider = activeRunProvider, let document = activeRunDocument(),
               await provider.runInContext(document, mode: debug ? .debug : .run) {
                return
            }
            if debug { debugLastConfiguration() } else { runLastRunConfiguration() }
        }
    }

    // MARK: - Run gutter

    /// The Run / Debug / Modify menu for the gutter's play button on the `main` at `line`. Parses
    /// fresh at click time: the buttons may be one debounce behind an edit.
    func showMainRunMenu(atLine line: Int, file: URL, in textView: TextView) {
        let text = textView.text
        guard let location = JavaMainMethod.locations(in: text, fileName: file.lastPathComponent).first(where: { $0.line == line }),
              let configuration = mainRunConfiguration(for: location, file: file, source: text) else { return }
        let menu = IDERunGutterMenu.make(
            title: "\(location.simpleClassName).main()",
            keymapPreset: preferences.keymapPreset,
            run: { [weak self] in self?.launch(configuration, mode: .run) },
            debug: { [weak self] in self?.launch(configuration, mode: .debug) },
            modify: { [weak self] in self?.runConfigurationDraft = configuration }
        )
        IDERunGutterMenu.popUp(menu, in: textView)
    }

    func launch(_ configuration: JavaRunConfiguration, mode: JavaLaunchMode) {
        javaRun.launch(configuration, mode: mode)
    }

    func mainRunConfiguration(for location: JavaMainMethodLocation, file: URL, source: String) -> JavaRunConfiguration? {
        javaRun.mainRunConfiguration(for: location, file: file, source: source)
    }

    // MARK: - Run configuration picker

    func reportRunProblem(_ message: String) {
        if javaSupport.maven.isActive, !javaSupport.gradle.isActive {
            maven.appendConsoleNote(message)
            showMavenOutput()
        } else {
            gradle.appendConsoleNote(message)
            showGradleOutput()
        }
    }

    func refreshLastRunConfiguration() {
        lastRunConfiguration = runConfigurationStore.last(forProject: project.rootURL)
        runConfigurations = runConfigurationStore.configurations(forProject: project.rootURL)
    }

    // MARK: Run configuration picker

    /// Makes `id` the selected configuration without running it.
    func selectRunConfiguration(_ id: UUID) {
        runConfigurationStore.select(id, forProject: project.rootURL)
        refreshLastRunConfiguration()
    }

    /// Runs the configuration `id` from the picker, selecting it.
    func runRunConfiguration(_ id: UUID) {
        guard let configuration = runConfigurations.first(where: { $0.id == id }) else { return }
        launch(configuration)
    }

    func editRunConfiguration(_ id: UUID) {
        guard let configuration = runConfigurations.first(where: { $0.id == id }) else { return }
        runConfigurationDraft = configuration
    }

    func newRunConfiguration() {
        let draft = javaRun.newConfigurationDraft()
        let editor = makeRunConfigurationsEditor(highlighting: nil)
        editor.add(kind: draft?.kind ?? .gradle, target: draft?.target ?? .gradleRun(projectPath: ":"))
        runConfigurationsEditor = editor
    }

    func duplicateRunConfiguration(_ id: UUID) {
        runConfigurationStore.duplicate(id, forProject: project.rootURL)
        refreshLastRunConfiguration()
    }

    func deleteRunConfiguration(_ id: UUID) {
        runConfigurationStore.delete(id, forProject: project.rootURL)
        refreshLastRunConfiguration()
    }
}
