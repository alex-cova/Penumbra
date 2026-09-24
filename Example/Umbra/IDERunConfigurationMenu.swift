import JavaIntelligence
import SwiftUI

/// The toolbar's run configuration picker: the selected configuration's name, and a menu to run,
/// select, edit, create, duplicate or delete configurations.
struct IDERunConfigurationMenu: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        let configurations = workspace.runConfigurations
        let selected = workspace.lastRunConfiguration
        // Shown once a project has something to pick from, or a Java file could start one.
        if !configurations.isEmpty || workspace.javaFileCanRun {
            Menu {
                if configurations.isEmpty {
                    Text("No saved configurations")
                }
                ForEach(configurations, id: \.id) { configuration in
                    Button {
                        workspace.selectRunConfiguration(configuration.id)
                    } label: {
                        if configuration.id == selected?.id {
                            Label(configuration.displayName, systemImage: "checkmark")
                        } else {
                            Text(configuration.displayName)
                        }
                    }
                }
                Divider()
                if let selected {
                    Button("Run “\(selected.displayName)”") { workspace.runRunConfiguration(selected.id) }
                    Button("Edit “\(selected.displayName)”…") { workspace.editRunConfiguration(selected.id) }
                    Button("Duplicate") { workspace.duplicateRunConfiguration(selected.id) }
                    Button("Delete", role: .destructive) { workspace.deleteRunConfiguration(selected.id) }
                    Divider()
                }
                Button("New Configuration…") { workspace.newRunConfiguration() }
            } label: {
                Text(selected?.displayName ?? "Run")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                    .lineLimit(1)
                    .frame(maxWidth: 140)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help("Run configuration")
            .accessibilityLabel("Run configuration")
        }
    }
}
