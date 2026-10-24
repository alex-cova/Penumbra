import JavaIntelligence
import SwiftUI

/// The toolbar's run configuration picker: saved configurations by kind, the temporary ones made by
/// running something below them, and the actions on the selected one. A configuration with a
/// problem (its file is gone, its Gradle task unknown) has a ✕ and opens its settings when run.
struct IDERunConfigurationMenu: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        let configurations = workspace.runConfigurations
        let selected = workspace.lastRunConfiguration
        // Shown once a project has something to pick from, or a Java file could start one.
        if !configurations.isEmpty || workspace.runFileCanRun {
            Menu {
                if configurations.isEmpty {
                    Text("No saved configurations")
                }
                ForEach(JavaRunConfiguration.Kind.allCases, id: \.self) { kind in
                    let saved = configurations.filter { $0.kind == kind && !$0.isTemporary }
                    if !saved.isEmpty {
                        Section(kind.title) {
                            ForEach(saved, id: \.id) { row($0, selected: selected) }
                        }
                    }
                }
                let temporary = configurations.filter(\.isTemporary)
                if !temporary.isEmpty {
                    Section("Temporary") {
                        ForEach(temporary, id: \.id) { row($0, selected: selected) }
                    }
                }
                Divider()
                if let selected {
                    Button("Run “\(selected.displayName)”") { workspace.runRunConfiguration(selected.id) }
                    if selected.supportsDebugLaunch {
                        Button("Debug “\(selected.displayName)”") { workspace.launch(selected, mode: .debug) }
                    }
                    Button("Edit “\(selected.displayName)”…") { workspace.editRunConfiguration(selected.id) }
                    if selected.isTemporary {
                        Button("Save Configuration") { workspace.saveTemporaryRunConfiguration(selected.id) }
                    }
                    Button("Duplicate") { workspace.duplicateRunConfiguration(selected.id) }
                    Button("Delete", role: .destructive) { workspace.deleteRunConfiguration(selected.id) }
                    Divider()
                }
                Button("Edit Configurations…") { workspace.editRunConfiguration() }
                Button("New Configuration…") { workspace.newRunConfiguration() }
            } label: {
                HStack(spacing: 4) {
                    if let selected, !workspace.validationProblems(for: selected).isEmpty {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(IDEAppearance.ColorToken.error)
                    }
                    Text(selected?.displayName ?? "Run")
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                        .opacity(selected?.isTemporary == true ? 0.7 : 1)
                        .lineLimit(1)
                        .frame(maxWidth: 140)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help("Run configuration")
            .accessibilityLabel("Run configuration")
        }
    }

    @ViewBuilder
    private func row(_ configuration: JavaRunConfiguration, selected: JavaRunConfiguration?) -> some View {
        let broken = !workspace.validationProblems(for: configuration).isEmpty
        Button {
            workspace.selectRunConfiguration(configuration.id)
        } label: {
            if configuration.id == selected?.id {
                Label(configuration.displayName, systemImage: "checkmark")
            } else if broken {
                Label(configuration.displayName, systemImage: "xmark.circle")
            } else {
                Text(configuration.displayName)
            }
        }
    }
}
