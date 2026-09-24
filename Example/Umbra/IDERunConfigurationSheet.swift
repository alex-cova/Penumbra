import JavaIntelligence
import SwiftUI

/// Edits a run configuration: its name, what it launches, and the arguments, JVM options and
/// environment it launches with.
struct IDERunConfigurationSheet: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var draft: JavaRunConfiguration
    @State private var environmentText: String
    @State private var kind: TargetKind
    @State private var gradleProjectPath: String
    @State private var filePath: String
    @State private var className: String
    @State private var launchMode: JavaLaunchMode
    @State private var suspendOnStart: Bool

    enum TargetKind: String, CaseIterable, Identifiable {
        case gradleRun = "Gradle run"
        case singleFile = "Single file"
        case classpathMain = "Class with classpath"

        var id: String { rawValue }
    }

    init(configuration: JavaRunConfiguration) {
        _draft = State(initialValue: configuration)
        _environmentText = State(initialValue: JavaRunConfiguration.environmentText(configuration.environment))
        switch configuration.target {
        case .gradleRun(let path):
            _kind = State(initialValue: .gradleRun)
            _gradleProjectPath = State(initialValue: path)
            _filePath = State(initialValue: "")
            _className = State(initialValue: "")
        case .singleFile(let path):
            _kind = State(initialValue: .singleFile)
            _gradleProjectPath = State(initialValue: ":")
            _filePath = State(initialValue: path)
            _className = State(initialValue: "")
        case .classpathMain(let name, let source):
            _kind = State(initialValue: .classpathMain)
            _gradleProjectPath = State(initialValue: ":")
            _filePath = State(initialValue: source)
            _className = State(initialValue: name)
        }
        _launchMode = State(initialValue: configuration.launchMode)
        _suspendOnStart = State(initialValue: configuration.suspendOnStart)
    }

    /// The target the fields describe, or `nil` while they are incomplete.
    private var target: JavaRunConfiguration.Target? {
        switch kind {
        case .gradleRun:
            let path = gradleProjectPath.trimmingCharacters(in: .whitespaces)
            return path.hasPrefix(":") ? .gradleRun(projectPath: path) : nil
        case .singleFile:
            let path = filePath.trimmingCharacters(in: .whitespaces)
            return path.hasSuffix(".java") ? .singleFile(path: path) : nil
        case .classpathMain:
            let name = className.trimmingCharacters(in: .whitespaces)
            let path = filePath.trimmingCharacters(in: .whitespaces)
            return name.isEmpty || !path.hasSuffix(".java") ? nil : .classpathMain(className: name, sourceFile: path)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            Text("Run Configuration")
                .font(IDEAppearance.Typography.brandTitle)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)

            field("Name", caption: "Shown in the run picker. Left empty, it is named after the target.") {
                TextField(draft.defaultName, text: Binding(
                    get: { draft.name ?? "" },
                    set: { draft.name = $0.isEmpty ? nil : $0 }
                ))
                .textFieldStyle(.roundedBorder)
            }

            field("Launch", caption: kindCaption) {
                Picker("Launch", selection: $kind) {
                    ForEach(TargetKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }

            targetFields

            field("Program arguments", caption: "Passed to main(String[]). Quote arguments that contain spaces.") {
                TextField("--port 8080", text: $draft.programArguments)
                    .textFieldStyle(.roundedBorder)
                    .font(IDEAppearance.Typography.monoSmall)
            }

            field(
                "VM options",
                caption: kind == .gradleRun
                    ? "Gradle's run task takes JVM options from the build script (applicationDefaultJvmArgs), not from here."
                    : "For example -Xmx512m -Dkey=value."
            ) {
                TextField("-Xmx512m", text: $draft.vmArguments)
                    .textFieldStyle(.roundedBorder)
                    .font(IDEAppearance.Typography.monoSmall)
                    .disabled(kind == .gradleRun)
            }

            field("Environment variables", caption: "One NAME=value per line.") {
                TextEditor(text: $environmentText)
                    .font(IDEAppearance.Typography.monoSmall)
                    .frame(height: 72)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(IDEAppearance.ColorToken.workbench, in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.control))
            }

            if kind == .classpathMain || kind == .gradleRun {
                field("Debug", caption: debugCaption) {
                    Toggle("Launch in debug mode", isOn: Binding(
                        get: { launchMode == .debug },
                        set: { launchMode = $0 ? .debug : .run }
                    ))
                    Toggle("Suspend on start", isOn: $suspendOnStart)
                        .disabled(launchMode != .debug)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { workspace.dismissRunConfigurationSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commit(run: false) }
                    .disabled(target == nil)
                if launchMode == .debug, kind == .classpathMain || kind == .gradleRun {
                    Button("Debug") { commit(run: true, debug: true) }
                        .disabled(target == nil)
                }
                Button("Run") { commit(run: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(target == nil)
            }
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(width: 480)
    }

    private var kindCaption: String {
        switch kind {
        case .gradleRun: return "Runs the project's Gradle run task."
        case .singleFile: return "Runs one file with java File.java."
        case .classpathMain: return "Runs a compiled class with the module's runtime classpath. It is built first if needed."
        }
    }

    private var debugCaption: String {
        switch kind {
        case .gradleRun:
            return "Gradle run uses --debug-jvm (port \(JavaLaunchCommand.gradleDebugJdwpPort)). ⌃⌥D to debug last configuration."
        case .classpathMain:
            return "Classpath launches run under the managed debugger. ⌃⌥D to debug last configuration."
        default:
            return ""
        }
    }

    @ViewBuilder
    private var targetFields: some View {
        switch kind {
        case .gradleRun:
            field("Gradle project", caption: "`:` for the root project, `:app` for a module.") {
                TextField(":app", text: $gradleProjectPath)
                    .textFieldStyle(.roundedBorder)
                    .font(IDEAppearance.Typography.monoSmall)
            }
        case .singleFile:
            field("Java file", caption: "The full path of a .java file with a main method.") {
                TextField("/path/to/Main.java", text: $filePath)
                    .textFieldStyle(.roundedBorder)
                    .font(IDEAppearance.Typography.monoSmall)
            }
        case .classpathMain:
            field("Main class", caption: "The fully qualified class name, such as com.example.Main.") {
                TextField("com.example.Main", text: $className)
                    .textFieldStyle(.roundedBorder)
                    .font(IDEAppearance.Typography.monoSmall)
            }
            field("Source file", caption: "A file of the module the class belongs to; its Gradle source set supplies the classpath.") {
                TextField("/path/to/Main.java", text: $filePath)
                    .textFieldStyle(.roundedBorder)
                    .font(IDEAppearance.Typography.monoSmall)
            }
        }
    }

    private func commit(run: Bool, debug: Bool = false) {
        guard let target else { return }
        var configuration = draft
        configuration.target = target
        configuration.environment = JavaRunConfiguration.parseEnvironment(environmentText)
        configuration.launchMode = debug ? .debug : launchMode
        configuration.suspendOnStart = suspendOnStart
        workspace.saveRunConfiguration(configuration, run: run)
    }

    private func field<Control: View>(_ title: String, caption: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Text(title)
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            control()
            Text(caption)
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
        }
    }
}
