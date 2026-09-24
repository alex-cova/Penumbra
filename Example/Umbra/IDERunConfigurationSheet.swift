import JavaIntelligence
import SwiftUI

/// Edits the arguments, JVM options and environment a Java program is launched with.
struct IDERunConfigurationSheet: View {
    @Environment(IDEWorkspace.self) private var workspace
    @State private var draft: JavaRunConfiguration
    @State private var environmentText: String

    init(configuration: JavaRunConfiguration) {
        _draft = State(initialValue: configuration)
        _environmentText = State(initialValue: JavaRunConfiguration.environmentText(configuration.environment))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Run Configuration")
                    .font(IDEAppearance.Typography.brandTitle)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                Text(draft.displayName)
                    .font(IDEAppearance.Typography.monoCaption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }

            field("Program arguments", caption: "Passed to main(String[]). Quote arguments that contain spaces.") {
                TextField("--port 8080", text: $draft.programArguments)
                    .textFieldStyle(.roundedBorder)
                    .font(IDEAppearance.Typography.monoSmall)
            }

            field(
                "VM options",
                caption: draft.supportsVMArguments
                    ? "For example -Xmx512m -Dkey=value."
                    : "Gradle's run task takes JVM options from the build script (applicationDefaultJvmArgs), not from here."
            ) {
                TextField("-Xmx512m", text: $draft.vmArguments)
                    .textFieldStyle(.roundedBorder)
                    .font(IDEAppearance.Typography.monoSmall)
                    .disabled(!draft.supportsVMArguments)
            }

            field("Environment variables", caption: "One NAME=value per line.") {
                TextEditor(text: $environmentText)
                    .font(IDEAppearance.Typography.monoSmall)
                    .frame(height: 84)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(IDEAppearance.ColorToken.workbench, in: RoundedRectangle(cornerRadius: IDEAppearance.Radius.control))
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { workspace.dismissRunConfigurationSheet() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commit(run: false) }
                Button("Run") { commit(run: true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(IDEAppearance.Spacing.lg)
        .frame(width: 460)
    }

    private func commit(run: Bool) {
        var configuration = draft
        configuration.environment = JavaRunConfiguration.parseEnvironment(environmentText)
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
