import JavaIntelligence
import SwiftUI

/// Run or Debug in a Gradle module that has neither `run` nor `bootRun`: which task to launch.
struct IDEGradleRunTaskPrompt: Equatable {
    /// `:` for the root project, `:app` for a module.
    let projectPath: String
    let tasks: [JavaGradleProjectModel.GradleTask]
    let launchMode: JavaLaunchMode
}

/// Lists a module's Gradle tasks for Run to launch. The pick is saved as the module's run
/// configuration, so the question comes up once.
struct IDEGradleTaskPickerSheet: View {
    @Environment(IDEWorkspace.self) private var workspace
    let prompt: IDEGradleRunTaskPrompt
    @State private var query = ""
    @State private var selection: String?

    /// Filtered by name, description or group; `application` first since that is where run tasks live.
    private var groups: [JavaGradleProjectModel.TaskGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let tasks = needle.isEmpty ? prompt.tasks : prompt.tasks.filter {
            $0.name.localizedCaseInsensitiveContains(needle)
                || $0.description.localizedCaseInsensitiveContains(needle)
                || $0.group.localizedCaseInsensitiveContains(needle)
        }
        let grouped = JavaGradleProjectModel.groupTasks(tasks)
        return grouped.filter { $0.name == "application" } + grouped.filter { $0.name != "application" }
    }

    private var moduleName: String {
        prompt.projectPath == ":" ? "the root project" : prompt.projectPath
    }

    private var verb: String {
        prompt.launchMode == .debug ? "Debug" : "Run"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            Text("Choose a Gradle Task")
                .font(IDEAppearance.Typography.brandTitle)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)

            Text("\(moduleName) has no run or bootRun task. Choose the task to \(verb.lowercased()):")
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)

            TextField("Filter tasks", text: $query)
                .textFieldStyle(.roundedBorder)

            List(selection: $selection) {
                ForEach(groups, id: \.name) { group in
                    Section(group.name.isEmpty ? "other" : group.name) {
                        ForEach(group.tasks, id: \.name) { task in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.name)
                                    .font(IDEAppearance.Typography.monoSmall)
                                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                                if !task.description.isEmpty {
                                    Text(task.description)
                                        .font(IDEAppearance.Typography.caption)
                                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                                        .lineLimit(1)
                                }
                            }
                            .tag(task.name)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { workspace.chooseGradleRunTask(task.name) }
                        }
                    }
                }
            }
            .frame(height: 260)
            .onKeyPress(.return) {
                guard let selection else { return .ignored }
                workspace.chooseGradleRunTask(selection)
                return .handled
            }

            Text("Your choice is saved as a run configuration. Change it with Edit Configurations.")
                .font(IDEAppearance.Typography.caption)
                .foregroundStyle(IDEAppearance.ColorToken.muted)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { workspace.dismissGradleRunTaskPrompt() }
                    .keyboardShortcut(.cancelAction)
                Button(verb) {
                    if let selection { workspace.chooseGradleRunTask(selection) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil)
            }
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(width: 440)
    }
}
