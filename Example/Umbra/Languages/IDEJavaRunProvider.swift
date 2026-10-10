import EditorIntelligence
import Foundation
import JavaIntelligence

/// Java's Run and Test for a window: which launch the active file means, the checks before it (a run
/// configuration's validation, its before-launch steps, the build, the JDK), the process itself, Gradle
/// run and test tasks, and the test results and compiler errors a Gradle task leaves behind.
///
/// It was `IDEWorkspace`'s Run code. The window keeps what it owns: the tabs, the picker, the sheets and
/// the debugger (Java-only, so it asks this type for the launch, the classpath and the JDK). The
/// provider reaches the window only through `IDEJavaRunHost`, held weakly. The Gradle model comes from
/// the project system (`IDEGradleProjectSystem`), the JDK from `IDEJDKSelection`.
@MainActor
final class IDEJavaRunProvider: IDERunProvider {
    let id = "java"
    let languageIdentifiers: Set<String> = ["java"]

    let java: IDEJavaSupport
    var gradle: IDEGradleProjectSystem { java.gradle }
    weak var host: (any IDEJavaRunHost)?
    /// Bumped by Stop. A launch that is still building (a run, a debug) notices and gives up.
    private(set) var launchEpoch = 0
    /// When set, the finished Gradle run's XML reports are parsed into test results.
    var pendingTestRunRequest: JavaTestRunRequest?

    init(host: any IDEJavaRunHost, java: IDEJavaSupport) {
        self.host = host
        self.java = java
    }

    // MARK: - Availability

    func canRun(_ document: IDERunDocument) -> Bool {
        let hasMain = document.languageIdentifier == "java" && JavaMainMethod.containsMain(in: document.text)
        let canPlainRun = document.url?.pathExtension.lowercased() == "java"
        let canGradleRun = gradle.isActive && host?.projectRootURL != nil
        return hasMain && (canPlainRun || canGradleRun)
    }

    /// Only Gradle launches can be debugged from the toolbar; a lone `java File.java` can't.
    func canDebug(fileURL: URL?) -> Bool {
        gradle.isActive && host?.projectRootURL != nil
    }

    func runHelp(fileURL: URL?) -> String {
        guard gradle.isActive else { return "Run Java file" }
        return activeGradleRunTaskName(for: fileURL).map { "Run Gradle \($0)" } ?? "Run Gradle task…"
    }

    func debugHelp(fileURL: URL?, canRun: Bool) -> String {
        guard canRun, canDebug(fileURL: fileURL) else { return "Debugging needs a Gradle project" }
        return activeGradleRunTaskName(for: fileURL).map { "Debug Gradle \($0)" } ?? "Debug Gradle task…"
    }

    /// The task the toolbar buttons run for the active file: `run`, else `bootRun`; `nil` when the
    /// module has neither and a task gets picked (or was picked before). Read from the model only,
    /// since the toolbar evaluates it on every redraw.
    private func activeGradleRunTaskName(for fileURL: URL?) -> String? {
        let path = JavaRunConfiguration.gradleProjectPath(for: fileURL, model: gradle.model)
        switch JavaRunConfiguration.preferredGradleRunTask(for: path, model: gradle.model) {
        case .task(let name): return name
        case .unsynced: return "run"
        case .ask: return nil
        }
    }

    // MARK: - Runnable places

    /// Every `main` and, in a test source, every test method and the test class.
    func runnableLocations(in document: IDERunDocument) async -> [IDERunnableLocation] {
        guard document.languageIdentifier == "java", let url = document.url else { return [] }
        let text = document.text
        let fileName = url.lastPathComponent
        let mains = await Task.detached(priority: .utility) {
            JavaMainMethod.containsMain(in: text) ? JavaMainMethod.locations(in: text, fileName: fileName) : []
        }.value
        var testClass: JavaTestClass?
        var classLine: Int?
        if await java.isTestSource(file: url), let found = await java.tests(for: url), !found.methods.isEmpty {
            testClass = found
            classLine = await Self.classDeclarationLine(of: found, in: text)
        }
        return Self.locations(fromMains: mains, testClass: testClass, classLine: classLine)
    }

    /// The gutter buttons for a set of mains and a test class. The same lines and titles the gutter
    /// used to derive itself, so a provider location is that button.
    static func locations(
        fromMains mains: [JavaMainMethodLocation], testClass: JavaTestClass?, classLine: Int?
    ) -> [IDERunnableLocation] {
        var locations = mains.map {
            IDERunnableLocation(kind: .entryPoint, line: $0.line, title: "\($0.simpleClassName).main()")
        }
        if let testClass, !testClass.methods.isEmpty {
            if let classLine {
                locations.append(IDERunnableLocation(
                    kind: .testGroup, line: classLine, title: simpleName(testClass.qualifiedName)
                ))
            }
            locations += testClass.methods.map {
                IDERunnableLocation(kind: .test, line: $0.line, title: "\($0.methodName)()")
            }
        }
        return locations.sorted { $0.line < $1.line }
    }

    /// The line of `class Name` for a test class, found off the main thread.
    static func classDeclarationLine(of testClass: JavaTestClass, in text: String) async -> Int? {
        let simpleName = String(testClass.qualifiedName.split(separator: ".").last ?? "")
            .split(separator: "$").last.map(String.init) ?? ""
        guard !simpleName.isEmpty else { return nil }
        return await Task.detached(priority: .utility) {
            var number = 0
            var found: Int?
            text.enumerateLines { line, stop in
                number += 1
                if line.range(of: "\\bclass\\s+\(simpleName)\\b", options: .regularExpression) != nil {
                    found = number
                    stop = true
                }
            }
            return found
        }.value
    }

    static func simpleName(_ qualifiedName: String) -> String {
        String(qualifiedName.split(separator: ".").last ?? Substring(qualifiedName)).replacingOccurrences(of: "$", with: ".")
    }

    // MARK: - Run, Debug, Stop

    func run(_ document: IDERunDocument, mode: IDERunMode) {
        launchActiveFile(mode: mode == .debug ? .debug : .run)
    }

    func run(_ document: IDERunDocument, location: IDERunnableLocation, mode: IDERunMode) {
        let launchMode: JavaLaunchMode = mode == .debug ? .debug : .run
        switch location.kind {
        case .entryPoint:
            launchMain(in: document, line: location.line, mode: launchMode)
        case .test, .testGroup:
            let debug = mode == .debug
            Task { await launchTest(in: document, location: location, debug: debug) }
        }
    }

    func canEditRunConfiguration(_ location: IDERunnableLocation) -> Bool {
        location.kind == .entryPoint
    }

    func editRunConfiguration(_ document: IDERunDocument, location: IDERunnableLocation) {
        guard let configuration = mainConfiguration(in: document, line: location.line) else { return }
        host?.openRunConfigurationDraft(configuration)
    }

    private func launchMain(in document: IDERunDocument, line: Int, mode: JavaLaunchMode) {
        guard let configuration = mainConfiguration(in: document, line: line) else { return }
        launch(configuration, mode: mode)
    }

    private func mainConfiguration(in document: IDERunDocument, line: Int) -> JavaRunConfiguration? {
        guard let url = document.url else { return nil }
        let text = document.text
        guard let found = JavaMainMethod.locations(in: text, fileName: url.lastPathComponent).first(where: { $0.line == line }) else {
            return nil
        }
        return mainRunConfiguration(for: found, file: url, source: text)
    }

    private func launchTest(in document: IDERunDocument, location: IDERunnableLocation, debug: Bool) async {
        guard let url = document.url else { return }
        let standard = url.standardizedFileURL
        let cached = host?.activeJavaTestClass
        let testClass: JavaTestClass?
        if let cached, cached.sourceFile.standardizedFileURL == standard {
            testClass = cached
        } else {
            testClass = await java.tests(for: url)
        }
        guard let testClass, !testClass.methods.isEmpty else { return }
        if location.kind == .testGroup {
            let title = Self.simpleName(testClass.qualifiedName)
            if debug {
                host?.debugTests(scope: .testClass(testClass), title: title, recording: nil)
            } else {
                runTests(scope: .testClass(testClass), title: title)
            }
            return
        }
        guard let method = testClass.methods.first(where: { $0.line == location.line }) else { return }
        let title = "\(method.methodName)()"
        if debug {
            host?.debugTests(scope: .testMethod(method, taskPath: testClass.gradleTaskPath), title: title, recording: nil)
        } else {
            runTests(scope: .testMethod(method, taskPath: testClass.gradleTaskPath), title: title)
        }
    }

    /// Launches the active file's configuration in `mode`, or asks which Gradle task to run when
    /// its module has neither `run` nor `bootRun` and none was picked for it before.
    private func launchActiveFile(mode: JavaLaunchMode) {
        guard var configuration = activeRunConfiguration() else {
            if let prompt = gradleRunTaskPromptForActiveFile(mode: mode) {
                host?.promptForGradleRunTask(prompt)
            }
            return
        }
        configuration.launchMode = mode
        launch(configuration)
    }

    /// The picker's content, when the active file's module needs a task picked.
    private func gradleRunTaskPromptForActiveFile(mode: JavaLaunchMode) -> IDEGradleRunTaskPrompt? {
        guard gradle.isActive, host?.projectRootURL != nil else { return nil }
        let path = JavaRunConfiguration.gradleProjectPath(for: host?.runFileURL, model: gradle.model)
        guard case .ask(let tasks) = JavaRunConfiguration.preferredGradleRunTask(for: path, model: gradle.model) else {
            return nil
        }
        return IDEGradleRunTaskPrompt(projectPath: path, tasks: tasks, launchMode: mode)
    }

    /// The task picker's choice: saved as the module's run configuration, so the next Run goes
    /// straight to it, then launched.
    func chooseGradleRunTask(_ taskName: String, for prompt: IDEGradleRunTaskPrompt) {
        var configuration = JavaRunConfiguration(
            target: .gradleRun(projectPath: prompt.projectPath, taskName: taskName == "run" ? nil : taskName)
        )
        configuration.launchMode = prompt.launchMode
        launch(configuration)
    }

    /// Stop: ends what is starting and the Gradle task behind a run. The Run-tab sessions and the
    /// debugger are the window's.
    func stop() {
        launchEpoch += 1
        gradle.cancelTasks()
    }

    var hasActiveWork: Bool { gradle.isRunningTasks }



    func launch(_ configuration: JavaRunConfiguration, mode: JavaLaunchMode) {
        var configuration = configuration
        configuration.launchMode = mode
        launch(configuration)
    }

    func launch(_ configuration: JavaRunConfiguration) {
        if configuration.launchMode == .debug {
            host?.startDebugging(configuration)
            return
        }
        if case .gradleRun(let projectPath, let taskName) = configuration.target {
            runBeforeLaunchSteps(for: configuration) { [self] in
                launchGradleRun(configuration, projectPath: projectPath, taskName: taskName ?? "run")
            }
            return
        }
        if let scope = configuration.testScope {
            runBeforeLaunchSteps(for: configuration) { [self] in
                runTests(scope: scope, title: configuration.displayName, recording: configuration)
            }
            return
        }
        startRunSession(configuration)
    }

    /// A Gradle run task goes through the Gradle runner, not the terminal, so Stop can end it
    /// and the toolbar knows it is running. Its output goes to the Gradle console.
    private func launchGradleRun(_ configuration: JavaRunConfiguration, projectPath: String, taskName: String) {
        guard let host else { return }
        guard host.projectRootURL != nil else {
            host.reportRunProblem("“\(configuration.displayName)” needs an open project folder.")
            return
        }
        guard !gradle.isBusy else {
            host.reportRunProblem("Gradle is busy. Stop the running task first, then run “\(configuration.displayName)” again.")
            return
        }
        host.runConfigurationStore.setLast(configuration, forProject: host.projectRootURL)
        host.refreshLastRunConfiguration()
        host.showGradleConsole()
        gradle.runGradleTasks(
            [JavaLaunchCommand.gradleRunTask(for: projectPath, taskName: taskName)],
            extraArguments: JavaLaunchCommand.gradleRunArguments(configuration: configuration),
            runsApplication: true
        )
    }

    // MARK: - Run in context

    /// What Run in Context (⌃⇧R) and Debug in Context (⌃⇧D) act on, from the caret.
    private enum ContextTarget {
        case configuration(JavaRunConfiguration)
        case testMethod(JavaTestMethod, taskPath: String)
        case testClass(JavaTestClass)
    }

    /// Runs (or debugs) what the caret is in: the `main` method of the file's class, a test method,
    /// or a test class. Anywhere else, and in a file that isn't Java, it answers `false` and the
    /// window repeats the last configuration, so the key is never dead.
    func runInContext(_ document: IDERunDocument, mode: IDERunMode) async -> Bool {
        guard let target = await resolveContext(document) else { return false }
        let debug = mode == .debug
        switch target {
        case .configuration(var configuration):
            // Run and Debug both go through the store, so the toolbar picker now selects it.
            configuration.launchMode = debug ? .debug : .run
            launch(configuration)
        case .testMethod(let method, let taskPath):
            let scope = JavaTestRunScope.testMethod(method, taskPath: taskPath)
            if debug {
                host?.debugTests(scope: scope, title: "\(method.methodName)()", recording: nil)
            } else {
                runTests(scope: scope, title: "\(method.methodName)()")
            }
        case .testClass(let testClass):
            let title = String(testClass.qualifiedName.split(separator: ".").last ?? "")
            if debug {
                host?.debugTests(scope: .testClass(testClass), title: title, recording: nil)
            } else {
                runTests(scope: .testClass(testClass), title: title)
            }
        }
        return true
    }

    private func resolveContext(_ document: IDERunDocument) async -> ContextTarget? {
        guard document.languageIdentifier == "java", let url = document.url else { return nil }
        let text = document.text
        guard let context = await java.structureProvider.caretContext(
            in: text, atUTF16Offset: document.caretUTF16Offset
        ) else { return nil }
        let testClass = await java.tests(for: url)
        if let testClass, !testClass.methods.isEmpty {
            if let name = context.methodName,
               let method = testClass.methods.first(where: { $0.methodName == name && $0.line == context.methodNameLine }) {
                return .testMethod(method, taskPath: testClass.gradleTaskPath)
            }
            return .testClass(testClass)
        }
        guard JavaMainMethod.containsMain(in: text) else { return nil }
        // A `main` outside the file's own class can't be told apart by a file-based launch.
        let fileClass = url.deletingPathExtension().lastPathComponent
        let fresh = context.typeName == fileClass
            ? JavaRunConfiguration.makeClasspathLaunch(file: url, source: text, model: gradle.model)
            : nil
        guard let configuration = fresh ?? activeRunConfiguration() else { return nil }
        return .configuration(inheritingSavedSettings(configuration))
    }

    // MARK: - Configurations for what is open

    /// The active file's default launch, carrying over what was last typed for the same target.
    /// In a Gradle module with neither `run` nor `bootRun`, the task picked for it before; `nil`
    /// until one has been picked.
    func activeRunConfiguration() -> JavaRunConfiguration? {
        guard let host else { return nil }
        // Reuse what was saved for the same target, whichever configuration ran last.
        let saved = host.runConfigurationStore.configurations(forProject: host.projectRootURL)
        guard let fresh = JavaRunConfiguration.makeDefault(
            file: host.runFileURL,
            projectRoot: host.projectRootURL,
            isGradleProject: gradle.isActive,
            model: gradle.model
        ) else {
            guard gradle.isActive else { return nil }
            let path = JavaRunConfiguration.gradleProjectPath(for: host.runFileURL, model: gradle.model)
            return saved.last {
                if case .gradleRun(path, _) = $0.target { return true }
                return false
            }
        }
        return fresh.inheritingSettings(from: saved.last { $0.target == fresh.target })
    }

    /// A launch of the class declaring `location`: its own class name on the Gradle classpath, or
    /// the file's default launch (`java File.java`, `gradle run`) otherwise. What was last typed
    /// for the same target is kept.
    func mainRunConfiguration(for location: JavaMainMethodLocation, file: URL, source: String) -> JavaRunConfiguration? {
        let classpathLaunch = JavaRunConfiguration.makeClasspathLaunch(
            file: file, className: location.binaryClassName, model: gradle.model
        )
        let fallback = JavaRunConfiguration.makeDefault(
            file: file,
            projectRoot: host?.projectRootURL,
            isGradleProject: gradle.isActive,
            model: gradle.model
        )
        guard let configuration = classpathLaunch ?? fallback else { return nil }
        return inheritingSavedSettings(configuration)
    }

    /// What a new configuration of `kind` launches before the user fills it in: the active file when
    /// there is one.
    func defaultTarget(for kind: JavaRunConfiguration.Kind) -> JavaRunConfiguration.Target {
        let file = host?.runFileURL?.path ?? ""
        switch kind {
        case .application: return .classpathMain(className: "", sourceFile: file)
        case .javaFile: return .singleFile(path: file)
        case .gradle: return .gradleRun(projectPath: JavaRunConfiguration.gradleProjectPath(for: host?.runFileURL, model: gradle.model))
        case .junit: return .gradleTest(taskPath: ":test", filters: [], sourceFile: nil)
        }
    }

    /// What Edit Configurations opens on for a new entry: a classpath launch of the active file inside
    /// a Gradle source set, else what Run would use for it, else a Gradle run of the root project.
    func newConfigurationDraft() -> JavaRunConfiguration? {
        guard let host else { return nil }
        var draft: JavaRunConfiguration?
        if let file = host.runFileURL, let source = host.openBufferText(for: file) {
            draft = JavaRunConfiguration.makeClasspathLaunch(file: file, source: source, model: gradle.model)
        }
        return draft ?? JavaRunConfiguration.makeDefault(
            file: host.runFileURL, projectRoot: host.projectRootURL,
            isGradleProject: gradle.isActive, model: gradle.model
        )
    }

    private func inheritingSavedSettings(_ configuration: JavaRunConfiguration) -> JavaRunConfiguration {
        guard let host else { return configuration }
        let saved = host.runConfigurationStore.configurations(forProject: host.projectRootURL)
        return configuration.inheritingSettings(from: saved.last { $0.target == configuration.target })
    }

    // MARK: - What the debugger and the launch checks need

    /// The runtime classpath of `file`'s source set, in `java -cp` order; `nil` before a sync or
    /// outside any source set.
    func runtimeClasspath(forFile file: URL) -> [URL]? {
        gradle.model?.runtimeClasspath(forFile: file)
    }

    var maxLanguageLevel: Int? { gradle.model?.maxLanguageLevel }

    /// Directories the debugged program's sources live in: every Gradle source set, then the
    /// project folder.
    func debugSourceRoots() -> [URL] {
        var roots: [URL] = []
        for subproject in gradle.model?.subprojects ?? [] {
            for sourceSet in subproject.sourceSets {
                roots.append(contentsOf: sourceSet.sourceDirs)
                roots.append(contentsOf: sourceSet.generatedSourceDirs)
            }
        }
        if let root = host?.projectRootURL {
            roots.append(root)
        }
        var seen = Set<String>()
        return roots.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// The JDK a configuration runs on: the one it names, else the project's.
    func resolveRunJDK(for configuration: JavaRunConfiguration) async -> JDKInstallation? {
        if let home = configuration.jdkHome, !home.isEmpty {
            return JDKLocator().installation(atUserSelected: URL(fileURLWithPath: home))
        }
        return await java.jdk.resolve(minimumFeatureVersion: gradle.model?.maxLanguageLevel)?.installation
    }

    /// What the checks of a run configuration need to know about this window.
    func validationContext() -> JavaRunConfigurationValidator.Context {
        JavaRunConfigurationValidator.Context(
            projectRoot: host?.projectRootURL,
            gradleModel: gradle.model,
            configurations: host?.runConfigurations ?? [],
            jdkFeatureVersion: java.jdk.current?.installation.featureVersion
        )
    }

    func validationProblems(for configuration: JavaRunConfiguration) -> [JavaRunConfigurationValidator.Problem] {
        JavaRunConfigurationValidator.problems(for: configuration, context: validationContext())
    }

    /// The validator's findings for a configuration of the dialog, judged against the dialog's own
    /// list (a before-launch step may name a configuration that is not saved yet).
    func validationProblems(for configuration: JavaRunConfiguration, among others: [JavaRunConfiguration]) -> [JavaRunConfigurationValidator.Problem] {
        var context = validationContext()
        context.configurations = others
        return JavaRunConfigurationValidator.problems(for: configuration, context: context)
    }

    // MARK: - Session lifecycle

    func rerun(_ session: IDERunSession) {
        guard let host else { return }
        let configuration = host.runConfigurations.first { $0.id == session.configurationID }
            ?? (session.payload as? JavaRunConfiguration)
        guard let configuration else { return }
        startRunSession(configuration, replacing: session)
    }
}

extension IDERunSession {
    /// A session for a Java run configuration (tests make them this way).
    convenience init(configuration: JavaRunConfiguration) {
        self.init(
            configurationID: configuration.id, title: configuration.displayName,
            providerID: IDEJavaRunProvider.providerID, payload: configuration
        )
    }

    /// The configuration this session runs, as of its last start.
    var configuration: JavaRunConfiguration? { payload as? JavaRunConfiguration }

    func update(configuration: JavaRunConfiguration) {
        update(title: configuration.displayName, payload: configuration)
    }

    func start(_ launch: JavaProcessLaunch) {
        start(IDEProcessLaunch(launch))
    }
}

extension IDEJavaRunProvider {
    static let providerID = "java"
}
