import AppKit
import EditorIntelligence
import Foundation
import JavaIntelligence

/// Starting, stopping and rerunning programs in the Run tool window: validation, the before-launch
/// steps, the build, the JDK, and the process itself. Gradle runs and tests keep their own consoles.
extension IDEWorkspace {
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

    /// Runs `session`'s configuration again in the same tab, with the settings it has now.
    func rerun(_ session: IDERunSession) {
        let fresh = runConfigurations.first { $0.id == session.configurationID } ?? session.configuration
        startRunSession(fresh, replacing: session)
    }

    // MARK: - Validation

    /// What the checks of a run configuration need to know about this window.
    func runValidationContext() -> JavaRunConfigurationValidator.Context {
        JavaRunConfigurationValidator.Context(
            projectRoot: project.rootURL,
            gradleModel: javaSupport.gradleModel,
            configurations: runConfigurations,
            jdkFeatureVersion: javaSupport.jdk.current?.installation.featureVersion
        )
    }

    func validationProblems(for configuration: JavaRunConfiguration) -> [JavaRunConfigurationValidator.Problem] {
        JavaRunConfigurationValidator.problems(for: configuration, context: runValidationContext())
    }

    // MARK: - Starting

    /// Runs a compiled class or a single file in a console of the Run tab. A rerun of a
    /// configuration that is still going stops it first, unless the configuration allows several
    /// instances.
    @discardableResult
    func startRunSession(_ configuration: JavaRunConfiguration, replacing explicit: IDERunSession? = nil) -> IDERunSession? {
        if let problem = validationProblems(for: configuration).first {
            reportRunProblem("“\(configuration.displayName)” can't run: \(problem.message)")
            runConfigurationDraft = configuration
            return nil
        }
        runConfigurationStore.setLast(configuration, forProject: project.rootURL)
        refreshLastRunConfiguration()

        let previous = explicit ?? runs.latest(forConfiguration: configuration.id)
        let replaced: IDERunSession?
        if explicit != nil {
            replaced = explicit
        } else if let previous, !configuration.allowMultipleInstances || !previous.isActive {
            replaced = previous
        } else {
            replaced = nil
        }
        let session = IDERunSession(configuration: configuration)
        runs.add(session, replacing: replaced)
        selectRunTab()

        let toStop = replaced?.isActive == true ? replaced : nil
        toStop?.stop()
        Task { @MainActor [weak self, weak session] in
            // A server that is going down still holds its port: wait for it before starting again.
            if let toStop { await toStop.waitUntilFinished() }
            guard let self, let session, session.isActive else { return }
            await self.runPipeline(session: session, configuration: configuration)
        }
        return session
    }

    private func runPipeline(session: IDERunSession, configuration: JavaRunConfiguration) async {
        var chain: Set<UUID> = [configuration.id]
        guard await prepareLaunch(configuration, session: session, chain: &chain) else { return }
        guard session.isActive else { return }

        guard let jdk = await resolveRunJDK(for: configuration) else {
            session.fail("No JDK found to run on. Choose one under Java ▸ Project JDK.")
            return
        }
        guard session.isActive else { return }

        let newProtocol = usesNewLaunchProtocol(configuration)
        if newProtocol, jdk.featureVersion < JavaLaunchCommand.minimumJavaForNewLaunchProtocol {
            session.fail(
                "Its main method (an instance main, no arguments, or a file without a class) needs Java "
                + "\(JavaLaunchCommand.minimumJavaForNewLaunchProtocol) or later, and this runs on Java \(jdk.featureVersion)."
            )
            return
        }

        var classpath: [URL]?
        if case .classpathMain(_, let sourceFile) = configuration.target {
            classpath = javaSupport.gradleModel?.runtimeClasspath(forFile: URL(fileURLWithPath: sourceFile))
            guard classpath != nil else {
                session.fail("It needs a synced Gradle project that contains \((sourceFile as NSString).lastPathComponent).")
                return
            }
        }
        guard let launch = JavaLaunchCommand.makeProcessLaunch(
            configuration: configuration,
            javaHome: jdk.home,
            runtimeClasspath: classpath,
            projectRoot: project.rootURL,
            jdkFeatureVersion: jdk.featureVersion,
            usesNewLaunchProtocol: newProtocol
        ) else {
            session.fail("It can't be launched: check its target.")
            return
        }
        session.appendNote("Java \(jdk.featureVersion) · \(jdk.home.path)")
        session.appendNote(launch.displayCommand + "\n")
        session.start(launch)
    }

    // MARK: - Before the program starts

    /// What reports on a launch in progress and learns that it was stopped: a run session, or the
    /// workspace's notes for a debug launch.
    struct LaunchProgress {
        var isActive: () -> Bool
        var note: (String) -> Void
        var fail: (String) -> Void
    }

    private func prepareLaunch(
        _ configuration: JavaRunConfiguration, session: IDERunSession, chain: inout Set<UUID>
    ) async -> Bool {
        let progress = LaunchProgress(
            isActive: { [weak session] in session?.isActive ?? false },
            note: { [weak session] in session?.appendNote($0) },
            fail: { [weak session] in session?.fail($0) }
        )
        return await prepareLaunch(configuration, progress: progress, chain: &chain)
    }

    /// The before-launch steps and the build that come ahead of the program. Reports why to
    /// `progress` when something fails, and returns `false` then (or when the launch was stopped).
    func prepareLaunch(
        _ configuration: JavaRunConfiguration, progress: LaunchProgress, chain: inout Set<UUID>, includesBuild: Bool = true
    ) async -> Bool {
        for step in configuration.beforeLaunch {
            guard progress.isActive() else { return false }
            switch step {
            case .gradleTasks(let tasks):
                let names = tasks.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
                guard !names.isEmpty else { continue }
                progress.note("Before launch: gradle \(names.joined(separator: " "))")
                let outcome = await runGradleAndWait(names)
                guard progress.isActive() else { return false }
                if let failure = Self.failureDescription(of: outcome) {
                    showGradleOutput()
                    progress.fail("Before-launch step “gradle \(names.joined(separator: " "))” failed: \(failure)")
                    return false
                }
            case .runConfiguration(let id):
                guard let other = runConfigurations.first(where: { $0.id == id }) else {
                    progress.fail("A configuration it runs first was deleted.")
                    return false
                }
                guard !chain.contains(other.id) else {
                    progress.fail("“\(other.displayName)” runs this configuration first, so they wait on each other.")
                    return false
                }
                progress.note("Before launch: run “\(other.displayName)”")
                chain.insert(other.id)
                let succeeded = await runToCompletion(other, waitingFor: progress)
                chain.remove(other.id)
                guard progress.isActive() else { return false }
                guard succeeded else {
                    progress.fail("“\(other.displayName)” did not finish successfully, so “\(configuration.displayName)” was not started.")
                    return false
                }
            }
        }

        if includesBuild, case .classpathMain(_, let sourceFile) = configuration.target {
            guard progress.isActive() else { return false }
            guard let classpath = javaSupport.gradleModel?.runtimeClasspath(forFile: URL(fileURLWithPath: sourceFile)) else {
                progress.fail("It needs a synced Gradle project that contains \((sourceFile as NSString).lastPathComponent).")
                return false
            }
            let missing = !JavaRunConfiguration.missingClassDirectories(in: classpath).isEmpty
            if configuration.buildBeforeRun || missing, let task = classesTaskPath(forSourceFile: sourceFile) {
                progress.note("Building \(task) — output is in the Gradle tab")
                let outcome = await runGradleAndWait([task])
                guard progress.isActive() else { return false }
                if let failure = Self.failureDescription(of: outcome) {
                    showGradleOutput()
                    progress.fail("Build failed, so it was not started: \(failure). Errors are listed under Problems.")
                    return false
                }
            }
        }
        return true
    }

    /// Runs a configuration's before-launch steps ahead of a launch that has no console of its own
    /// (a Gradle task, tests), then `proceed`. A failing step is reported in the Gradle console and
    /// the launch does not happen; Stop cancels a wait. With no steps `proceed` runs at once.
    func runBeforeLaunchSteps(for configuration: JavaRunConfiguration, then proceed: @escaping @MainActor () -> Void) {
        guard !configuration.beforeLaunch.isEmpty else {
            proceed()
            return
        }
        let epoch = launchEpoch
        Task { @MainActor [weak self] in
            guard let self else { return }
            let progress = LaunchProgress(
                isActive: { [weak self] in self?.launchEpoch == epoch },
                note: { _ in },
                fail: { [weak self] in self?.reportRunProblem("“\(configuration.displayName)”: \($0)") }
            )
            var chain: Set<UUID> = [configuration.id]
            guard await self.prepareLaunch(configuration, progress: progress, chain: &chain, includesBuild: false),
                  self.launchEpoch == epoch else { return }
            proceed()
        }
    }

    /// Runs another configuration to its end for a before-launch step. `true` when it succeeded.
    /// Stopping the waiting session stops it too.
    private func runToCompletion(_ configuration: JavaRunConfiguration, waitingFor parent: LaunchProgress) async -> Bool {
        switch configuration.target {
        case .classpathMain, .singleFile:
            guard let other = startRunSession(configuration) else { return false }
            while other.isActive {
                if !parent.isActive() { other.stop() }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return other.state == .exited(0)
        case .gradleRun(let projectPath, let taskName):
            let outcome = await runGradleAndWait(
                [JavaLaunchCommand.gradleRunTask(for: projectPath, taskName: taskName ?? "run")],
                extra: JavaLaunchCommand.gradleRunArguments(configuration: configuration), runsApplication: true
            )
            return Self.failureDescription(of: outcome) == nil
        case .gradleTest(let taskPath, let filters, _):
            var extra = ["--no-configuration-cache"]
            for filter in filters { extra += ["--tests", filter] }
            return Self.failureDescription(of: await runGradleAndWait([taskPath], extra: extra)) == nil
        }
    }

    /// Runs Gradle tasks through the window's one Gradle runner and waits for the outcome.
    private func runGradleAndWait(
        _ tasks: [String], extra: [String] = [], runsApplication: Bool = false
    ) async -> IDEGradleRunOutcome {
        await withCheckedContinuation { continuation in
            javaSupport.runGradleTasks(tasks, extraArguments: extra, runsApplication: runsApplication) { outcome in
                continuation.resume(returning: outcome)
            }
        }
    }

    /// Why a Gradle run counts as failed, or `nil` when it succeeded.
    private static func failureDescription(of outcome: IDEGradleRunOutcome) -> String? {
        switch outcome {
        case .finished(let result): return result.exitCode == 0 ? nil : "Gradle exited with \(result.exitCode)"
        case .timedOut: return "Gradle timed out"
        case .cancelled: return "it was cancelled"
        case .notStarted(let reason), .failed(let reason): return reason
        }
    }

    /// `:app:classes` for the source set that holds `sourceFile`; `nil` outside any.
    func classesTaskPath(forSourceFile sourceFile: String) -> String? {
        guard let match = javaSupport.gradleModel?.sourceSet(containing: URL(fileURLWithPath: sourceFile)) else { return nil }
        let name = match.sourceSet.name == "main" ? "classes" : "\(match.sourceSet.name)Classes"
        return match.subproject.path == ":" ? name : "\(match.subproject.path):\(name)"
    }

    /// Whether the program's `main` needs Java 21+'s launch protocol (an instance `main`, one without
    /// arguments, or a compact source file). Reads the source, from the editor if it is open.
    func usesNewLaunchProtocol(_ configuration: JavaRunConfiguration) -> Bool {
        let path: String
        let className: String?
        switch configuration.target {
        case .classpathMain(let name, let sourceFile): (path, className) = (sourceFile, name)
        case .singleFile(let file): (path, className) = (file, nil)
        case .gradleRun, .gradleTest: return false
        }
        let url = URL(fileURLWithPath: path)
        guard let source = openBufferText(for: url) ?? (try? String(contentsOf: url, encoding: .utf8)) else { return false }
        let locations = JavaMainMethod.locations(in: source, fileName: url.lastPathComponent)
        if let className {
            return locations.first { $0.binaryClassName == className }?.usesNewLaunchProtocol ?? false
        }
        // `java File.java` starts the first class of the file; its main decides.
        return locations.first?.usesNewLaunchProtocol ?? false
    }

    /// The JDK a configuration runs on: the one it names, else the project's.
    func resolveRunJDK(for configuration: JavaRunConfiguration) async -> JDKInstallation? {
        if let home = configuration.jdkHome, !home.isEmpty {
            return JDKLocator().installation(atUserSelected: URL(fileURLWithPath: home))
        }
        return await javaSupport.jdk.resolve(minimumFeatureVersion: javaSupport.gradleModel?.maxLanguageLevel)?.installation
    }
}

// MARK: - ⌥↩ Run actions

extension IDEWorkspace {
    /// Carries out a Run, Debug or Modify Run Configuration chosen in the ⌥↩ menu on a `main`, a
    /// test method or a test class of the active file.
    func performRunCodeAction(_ command: CodeActionCommand) {
        typealias Provider = IDERunCodeActionProvider
        guard [Provider.runCommand, Provider.debugCommand, Provider.modifyCommand].contains(command.id),
              command.arguments.count == 2, let kind = Provider.Kind(rawValue: command.arguments[0]),
              let line = Int(command.arguments[1]),
              let file = workbench.activePane.selectedDocument?.url else { return }
        let mode: JavaLaunchMode = command.id == Provider.debugCommand ? .debug : .run
        let modify = command.id == Provider.modifyCommand

        switch kind {
        case .main:
            let source = host(for: workbench.activePaneID).textView.text
            guard let location = JavaMainMethod.locations(in: source, fileName: file.lastPathComponent).first(where: { $0.line == line }),
                  let configuration = mainRunConfiguration(for: location, file: file, source: source) else {
                reportRunProblem("There is nothing to run at that line.")
                return
            }
            if modify { runConfigurationDraft = configuration } else { launch(configuration, mode: mode) }
        case .testMethod, .testClass:
            guard let testClass = activeJavaTestClass else {
                reportRunProblem("The tests of this file are not known yet. Try again in a moment.")
                return
            }
            let scope: JavaTestRunScope
            let title: String
            if kind == .testMethod, let method = testClass.methods.first(where: { $0.line == line }) {
                scope = .testMethod(method, taskPath: testClass.gradleTaskPath)
                title = "\(method.methodName)()"
            } else {
                scope = .testClass(testClass)
                title = testClass.qualifiedName.split(separator: ".").last.map(String.init) ?? testClass.qualifiedName
            }
            if modify {
                let fresh = JavaRunConfiguration.makeTestLaunch(scope: scope)
                let saved = runConfigurationStore.configurations(forProject: project.rootURL)
                runConfigurationDraft = fresh.inheritingSettings(from: saved.last { $0.target == fresh.target })
            } else if mode == .debug {
                debugTests(scope: scope, title: title)
            } else {
                runTests(scope: scope, title: title)
            }
        }
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
        let file = javaRunFileURL?.path ?? ""
        switch kind {
        case .application: return .classpathMain(className: "", sourceFile: file)
        case .javaFile: return .singleFile(path: file)
        case .gradle: return .gradleRun(projectPath: JavaRunConfiguration.gradleProjectPath(for: javaRunFileURL, model: javaSupport.gradleModel))
        case .junit: return .gradleTest(taskPath: ":test", filters: [], sourceFile: nil)
        }
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
        var context = runValidationContext()
        context.configurations = others
        return JavaRunConfigurationValidator.problems(for: configuration, context: context)
    }
}
