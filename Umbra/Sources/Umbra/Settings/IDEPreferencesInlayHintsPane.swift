import SwiftUI

struct IDEPreferencesInlayHintsPane: View {
    @Environment(IDEWorkspace.self) private var workspace
    @Bindable var preferences: IDEPreferences

    var body: some View {
        Button("Back to Editor Settings", systemImage: "chevron.left") {
            workspace.requestedSettingsDomain = .editor
        }
        .buttonStyle(.borderless)

        IDESettingsSection("Visibility") {
            IDESettingsToggle("Show Inlay Hints", isOn: $preferences.inlayHintsEnabled)
            IDESettingsToggle("Language Server Hints", isOn: $preferences.lspInlayHintsEnabled)
            IDESettingsToggle("Language Server Code Lenses", isOn: $preferences.lspCodeLensEnabled)
            IDESettingsToggle("Project JDK Hints", isOn: $preferences.jdkConfigurationHintsEnabled)
            if let root = workspace.project.rootURL {
                IDESettingsPicker("This Workspace", selection: workspaceVisibility(root)) {
                    Text("Use Global Setting").tag(WorkspaceVisibility.inherit)
                    Text("Show Hints").tag(WorkspaceVisibility.show)
                    Text("Hide Hints").tag(WorkspaceVisibility.hide)
                }
            }
        }

        IDESettingsSection("Java") {
            IDESettingsToggle("Parameter Names", isOn: $preferences.javaInlayHints)
            IDESettingsToggle("Inferred Variable Types", isOn: $preferences.javaInlayVariableTypes)
            IDESettingsToggle("Lambda Parameter Types", isOn: $preferences.javaInlayLambdaTypes)
            IDESettingsToggle("Multiline Method Chain Types", isOn: $preferences.javaInlayChainTypes)
            TextField("Excluded Java symbols", text: $preferences.javaInlayExclusions, axis: .vertical)
                .lineLimit(2...6)
                .font(.body.monospaced())
            Text("Enter one qualified name per line. Use * to match any text.")
                .foregroundStyle(.secondary)
        }

        IDESettingsSection("Java Code Vision") {
            IDESettingsToggle("Usage Counts", isOn: $preferences.javaCodeVisionUsages)
            IDESettingsToggle("Implementation Counts", isOn: $preferences.javaCodeVisionImplementations)
        }

        IDESettingsSection("Appearance") {
            IDESettingsToggle("Use Editor Font", isOn: $preferences.inlayHintsUseEditorFont)
            IDESettingsPicker("Size", selection: $preferences.inlayHintsSizeAdjustment) {
                Text("Smallest").tag(-2)
                Text("Smaller").tag(-1)
                Text("Default").tag(0)
                Text("Larger").tag(1)
                Text("Larger Still").tag(2)
                Text("Largest").tag(3)
            }
            IDESettingsPicker("Background", selection: $preferences.inlayHintsBackgroundOpacity) {
                Text("None").tag(0.0)
                Text("Faint").tag(0.5)
                Text("Default").tag(1.0)
                Text("Strong").tag(2.0)
            }
            HStack(spacing: 2) {
                Text("resize(")
                if preferences.inlayHintsEnabled && preferences.javaInlayHints {
                    Text("width:")
                        .font(preferences.inlayHintsUseEditorFont ? .caption.monospaced() : .caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
                }
                Text("640)")
            }
            .font(.body.monospaced())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Java parameter hint preview")
            .accessibilityValue(preferences.inlayHintsEnabled && preferences.javaInlayHints ? "resize width 640" : "resize 640")
            Button("Restore Inlay Hint Defaults", action: preferences.restoreInlayHintDefaults)
        }
    }

    private enum WorkspaceVisibility: Hashable {
        case inherit, show, hide
    }

    private func workspaceVisibility(_ root: URL) -> Binding<WorkspaceVisibility> {
        Binding {
            switch preferences.inlayHintsOverride(for: root) {
            case true?: .show
            case false?: .hide
            case nil: .inherit
            }
        } set: { visibility in
            let override: Bool? = switch visibility {
            case .inherit: nil
            case .show: true
            case .hide: false
            }
            preferences.setInlayHintsOverride(override, for: root)
            workspace.applyPreferencesToAllHosts()
        }
    }

}
