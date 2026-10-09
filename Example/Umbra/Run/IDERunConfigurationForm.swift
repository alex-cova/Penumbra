import JavaIntelligence
import SwiftUI

/// The fields of one run configuration (or one kind's template) in the Edit Configurations dialog.
/// A field that the configuration's target does not use is hidden or disabled, with the reason.
struct IDERunConfigurationForm: View {
    @Environment(IDEWorkspace.self) private var workspace
    @Binding var configuration: JavaRunConfiguration
    let problems: [JavaRunConfigurationValidator.Problem]
    let otherConfigurations: [JavaRunConfiguration]
    let isTemplate: Bool

    @State private var environmentText = ""
    @State private var loadedID: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
                if isTemplate {
                    Text("\(configuration.kind.title) template")
                        .font(IDEAppearance.Typography.brandTitle)
                    Text("New \(configuration.kind.title) configurations start with these settings.")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                } else {
                    identity
                    targetFields
                }
                optionFields
                if !isTemplate { beforeLaunchSection }
                if configuration.supportsDebugLaunch { debugSection }
            }
            .padding(IDEAppearance.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: loadEnvironment)
        .onChange(of: configuration.id) { _, _ in loadEnvironment() }
    }

    private func loadEnvironment() {
        guard loadedID != configuration.id else { return }
        loadedID = configuration.id
        environmentText = JavaRunConfiguration.environmentText(configuration.environment)
    }

    // MARK: - Sections

    private var identity: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            field("Name", caption: "Shown in the run picker. Left empty, it is named after the target.", problems: []) {
                TextField(configuration.defaultName, text: Binding(
                    get: { configuration.name ?? "" },
                    set: { configuration.name = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }
            HStack(alignment: .top, spacing: IDEAppearance.Spacing.lg) {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Store as project file", isOn: $configuration.storeAsProjectFile)
                    Text(configuration.storeAsProjectFile
                        ? "Written to .umbra/runConfigurations, so it can be committed. Its environment variables are committed too."
                        : "Kept on this Mac only.")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Folder").font(IDEAppearance.Typography.caption).foregroundStyle(IDEAppearance.ColorToken.muted)
                    TextField("None", text: Binding(
                        get: { configuration.folder ?? "" },
                        set: { configuration.folder = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                }
            }
            if configuration.isTemporary {
                Label("Temporary: only the newest few are kept. Saving makes it permanent.", systemImage: "clock")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
        }
    }

    @ViewBuilder
    private var targetFields: some View {
        let targetProblems = problems.filter { $0.field == .target }
        switch configuration.target {
        case .classpathMain:
            field("Main class", caption: "The fully qualified name, such as com.example.Main.", problems: targetProblems) {
                monoField("com.example.Main", text: mainClass)
            }
            field("Source file", caption: "A file of the module the class belongs to; its Gradle source set supplies the classpath.", problems: problems.filter { $0.field == .sourceFile }) {
                monoField("/path/to/Main.java", text: sourceFile)
            }
        case .singleFile:
            field("Java file", caption: "A .java file with a main method, run with java File.java.", problems: targetProblems) {
                monoField("/path/to/Main.java", text: singleFilePath)
            }
        case .gradleRun:
            field("Gradle project", caption: "`:` for the root project, `:app` for a module.", problems: targetProblems) {
                monoField(":app", text: gradleProjectPath)
            }
            field("Task", caption: "run for the application plugin, bootRun for Spring Boot.", problems: []) {
                monoField("run", text: gradleTaskName)
            }
        case .gradleTest:
            field("Test task", caption: "The task path, such as :test or :app:test.", problems: targetProblems) {
                monoField(":app:test", text: testTaskPath)
            }
            field("Test filters", caption: "One --tests pattern per line, such as app.FooTest or app.FooTest.testAdds. Empty runs every test.", problems: []) {
                TextEditor(text: testFilters)
                    .font(IDEAppearance.Typography.monoSmall)
                    .frame(height: 56)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(IDEAppearance.ColorToken.workbench, in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.control))
            }
        }
    }

    @ViewBuilder
    private var optionFields: some View {
        if configuration.supportsWorkingDirectory {
            field(
                "JRE",
                caption: "Which JDK runs it. “Project JDK” follows Java ▸ Project JDK.",
                problems: problems.filter { $0.field == .jdk }
            ) {
                jdkPicker
            }
        }
        if configuration.supportsVMArguments {
            field("VM options", caption: "For example -Xmx512m -Dkey=value. Quote an option that contains spaces.", problems: []) {
                monoField("-Xmx512m", text: $configuration.vmArguments)
            }
        } else if case .gradleRun = configuration.target {
            Text("A Gradle run takes JVM options from the build script (applicationDefaultJvmArgs, jvmArgs), not from here.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
        if configuration.testScope == nil {
            field("Program arguments", caption: "Passed to main(String[]). Quote an argument that contains spaces.", problems: []) {
                monoField("--port 8080", text: $configuration.programArguments)
            }
        }
        if configuration.supportsWorkingDirectory {
            field("Working directory", caption: "Relative paths in the program start here. Empty is the project folder.", problems: problems.filter { $0.field == .workingDirectory }) {
                HStack {
                    monoField(workspace.project.rootURL?.path ?? "Project folder", text: workingDirectory)
                    Button("Choose…") { chooseDirectory() }
                }
            }
            field("Environment variables", caption: "One NAME=value per line.", problems: []) {
                TextEditor(text: $environmentText)
                    .font(IDEAppearance.Typography.monoSmall)
                    .frame(height: 72)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(IDEAppearance.ColorToken.workbench, in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.control))
                    .onChange(of: environmentText) { _, text in
                        configuration.environment = JavaRunConfiguration.parseEnvironment(text)
                    }
            }
            field("Redirect input", caption: "A text file to use as the program's standard input instead of the console.", problems: problems.filter { $0.field == .redirectInput }) {
                monoField("/path/to/input.txt", text: redirectInput)
            }
        }
        if configuration.supportsBuildBeforeRun || configuration.supportsWorkingDirectory {
            VStack(alignment: .leading, spacing: 6) {
                if configuration.supportsBuildBeforeRun {
                    Toggle("Build before run", isOn: $configuration.buildBeforeRun)
                    if !configuration.buildBeforeRun {
                        Text("Without it, edited code runs from the last build. A missing build is still made.")
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                    }
                }
                if configuration.supportsWorkingDirectory {
                    Toggle("Allow multiple instances", isOn: $configuration.allowMultipleInstances)
                }
            }
            if configuration.supportsBuildBeforeRun {
                field("Shorten command line", caption: "An @argfile keeps a very long classpath off the command line (Java 9 and later).", problems: []) {
                    Picker("Shorten command line", selection: $configuration.shortenCommandLine) {
                        Text("Automatic").tag(JavaRunConfiguration.ShortenCommandLine.auto)
                        Text("Never").tag(JavaRunConfiguration.ShortenCommandLine.none)
                        Text("Always use @argfile").tag(JavaRunConfiguration.ShortenCommandLine.argFile)
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .leading)
                }
            }
        }
    }

    private var beforeLaunchSection: some View {
        field("Before launch", caption: "Steps that run first, in order. If one fails, the program is not started.", problems: problems.filter { $0.field == .beforeLaunch }) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(configuration.beforeLaunch.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 6) {
                        switch step {
                        case .gradleTasks(let tasks):
                            Image(systemName: "hammer").foregroundStyle(IDEAppearance.ColorToken.muted)
                            TextField("Gradle tasks, such as :app:generateSources", text: Binding(
                                get: { tasks.joined(separator: " ") },
                                set: { configuration.beforeLaunch[index] = .gradleTasks($0.split(whereSeparator: \.isWhitespace).map(String.init)) }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(IDEAppearance.Typography.monoSmall)
                        case .runConfiguration(let id):
                            Image(systemName: "play").foregroundStyle(IDEAppearance.ColorToken.muted)
                            Text("Run “\(otherConfigurations.first { $0.id == id }?.displayName ?? "deleted configuration")”")
                                .font(IDEAppearance.Typography.body)
                            Spacer()
                        }
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == configuration.beforeLaunch.count - 1)
                        Button { configuration.beforeLaunch.remove(at: index) } label: { Image(systemName: "minus.circle") }
                    }
                    .buttonStyle(.borderless)
                }
                Menu {
                    Button("Run Gradle Task") { configuration.beforeLaunch.append(.gradleTasks([])) }
                    Menu("Run Another Configuration") {
                        ForEach(otherConfigurations.filter { $0.id != configuration.id }, id: \.id) { other in
                            Button(other.displayName) { configuration.beforeLaunch.append(.runConfiguration(other.id)) }
                        }
                    }
                } label: {
                    Label("Add Step", systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private var debugSection: some View {
        field("Debug", caption: "⌃⌥D debugs the last configuration. Gradle tasks run with --debug-jvm on port \(JavaLaunchCommand.gradleDebugJdwpPort).", problems: []) {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Launch in debug mode", isOn: Binding(
                    get: { configuration.launchMode == .debug },
                    set: { configuration.launchMode = $0 ? .debug : .run }
                ))
                Toggle("Suspend on start", isOn: $configuration.suspendOnStart)
                    .disabled(configuration.launchMode != .debug)
            }
        }
    }

    // MARK: - Controls

    private var jdkPicker: some View {
        let detected = workspace.javaSupport.jdk.detected
        let chosen = configuration.jdkHome ?? ""
        return Picker("JRE", selection: Binding(get: { chosen }, set: { configuration.jdkHome = $0.isEmpty ? nil : $0 })) {
            Text("Project JDK").tag("")
            ForEach(detected, id: \.home) { jdk in
                Text(jdk.displayName).tag(jdk.home.path)
            }
            if !chosen.isEmpty, !detected.contains(where: { $0.home.path == chosen }) {
                Text(chosen).tag(chosen)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 320, alignment: .leading)
    }

    private func monoField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.roundedBorder)
            .font(IDEAppearance.Typography.monoSmall)
    }

    private func field<Control: View>(
        _ title: String, caption: String, problems: [JavaRunConfigurationValidator.Problem], @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Text(title)
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            control()
            ForEach(problems, id: \.message) { problem in
                Label(problem.message, systemImage: "xmark.circle.fill")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.error)
            }
            Text(caption)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard configuration.beforeLaunch.indices.contains(target) else { return }
        configuration.beforeLaunch.swapAt(index, target)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.directoryURL = workspace.project.rootURL
        if panel.runModal() == .OK, let url = panel.url { configuration.workingDirectory = url.path }
    }

    // MARK: - Target bindings

    private var mainClass: Binding<String> {
        Binding(
            get: { if case .classpathMain(let name, _) = configuration.target { name } else { "" } },
            set: { if case .classpathMain(_, let source) = configuration.target { configuration.target = .classpathMain(className: $0, sourceFile: source) } }
        )
    }

    private var sourceFile: Binding<String> {
        Binding(
            get: { if case .classpathMain(_, let source) = configuration.target { source } else { "" } },
            set: { if case .classpathMain(let name, _) = configuration.target { configuration.target = .classpathMain(className: name, sourceFile: $0) } }
        )
    }

    private var singleFilePath: Binding<String> {
        Binding(
            get: { if case .singleFile(let path) = configuration.target { path } else { "" } },
            set: { configuration.target = .singleFile(path: $0) }
        )
    }

    private var gradleProjectPath: Binding<String> {
        Binding(
            get: { if case .gradleRun(let path, _) = configuration.target { path } else { ":" } },
            set: { if case .gradleRun(_, let task) = configuration.target { configuration.target = .gradleRun(projectPath: $0, taskName: task) } }
        )
    }

    private var gradleTaskName: Binding<String> {
        Binding(
            get: { configuration.gradleTaskName ?? "run" },
            set: { name in
                if case .gradleRun(let path, _) = configuration.target {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    configuration.target = .gradleRun(projectPath: path, taskName: trimmed.isEmpty || trimmed == "run" ? nil : trimmed)
                }
            }
        )
    }

    private var testTaskPath: Binding<String> {
        Binding(
            get: { if case .gradleTest(let path, _, _) = configuration.target { path } else { "" } },
            set: { if case .gradleTest(_, let filters, let source) = configuration.target { configuration.target = .gradleTest(taskPath: $0, filters: filters, sourceFile: source) } }
        )
    }

    private var testFilters: Binding<String> {
        Binding(
            get: { if case .gradleTest(_, let filters, _) = configuration.target { filters.joined(separator: "\n") } else { "" } },
            set: { text in
                if case .gradleTest(let path, _, let source) = configuration.target {
                    let filters = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    configuration.target = .gradleTest(taskPath: path, filters: filters, sourceFile: source)
                }
            }
        )
    }

    private var workingDirectory: Binding<String> {
        Binding(get: { configuration.workingDirectory ?? "" }, set: { configuration.workingDirectory = $0.isEmpty ? nil : $0 })
    }

    private var redirectInput: Binding<String> {
        Binding(get: { configuration.redirectInputPath ?? "" }, set: { configuration.redirectInputPath = $0.isEmpty ? nil : $0 })
    }
}
