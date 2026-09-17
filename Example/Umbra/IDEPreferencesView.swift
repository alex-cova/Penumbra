import SwiftUI

struct IDEPreferencesView: View {
    @Bindable var preferences: IDEPreferences
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xl) {
                    IDESettingsSection(title: "Editor") {
                        IDESettingsRow(title: "Font Size") {
                            HStack(spacing: IDEAppearance.Spacing.sm) {
                                Slider(value: $preferences.fontSize, in: 9...32, step: 1)
                                    .frame(width: 160)
                                    .accessibilityLabel("Font Size")
                                    .accessibilityValue(
                                        Text(preferences.fontSize, format: .number.precision(.fractionLength(0)))
                                    )
                                Text(preferences.fontSize, format: .number.precision(.fractionLength(0)))
                                    .font(IDEAppearance.Typography.monoCaption)
                                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                                    .monospacedDigit()
                                    .frame(width: 24, alignment: .trailing)
                                    .accessibilityHidden(true)
                            }
                        }

                        IDESettingsSeparator()

                        IDESettingsRow(title: "Keymap") {
                            Picker("Keymap", selection: $preferences.keymapPreset) {
                                ForEach(KeymapPreset.allCases) { preset in
                                    Text(preset.title).tag(preset)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }

                        IDESettingsSeparator()

                        IDESettingsRow(title: "Tab Width") {
                            HStack(spacing: IDEAppearance.Spacing.xs) {
                                Text(preferences.tabWidth, format: .number)
                                    .font(IDEAppearance.Typography.monoCaption)
                                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                                    .monospacedDigit()
                                    .frame(width: 16, alignment: .trailing)
                                    .accessibilityHidden(true)
                                Stepper("Tab Width", value: $preferences.tabWidth, in: 2...8)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }
                        }

                        IDESettingsSeparator()

                        IDESettingsToggleRow(
                            title: "Indent with Spaces",
                            isOn: $preferences.useSpacesForTab
                        )
                    }

                    IDESettingsSection(title: "Display") {
                        IDESettingsToggleRow(title: "Line Numbers", isOn: $preferences.showLineNumbers)
                        IDESettingsSeparator()
                        IDESettingsToggleRow(title: "Code Folding", isOn: $preferences.isLineFoldingEnabled)
                        IDESettingsSeparator()
                        IDESettingsToggleRow(title: "Word Wrap", isOn: $preferences.wrapLines)
                        IDESettingsSeparator()
                        IDESettingsToggleRow(title: "Minimap", isOn: $preferences.showMinimap)
                        IDESettingsSeparator()
                        IDESettingsToggleRow(
                            title: "Metal Renderer",
                            caption: "Paints large files on the GPU.",
                            isOn: $preferences.isMetalRenderingEnabled
                        )
                    }
                }
                .padding(IDEAppearance.Spacing.lg)
            }

            IDESettingsTypePreview(
                fontSize: preferences.fontSize,
                tabWidth: preferences.tabWidth,
                useSpacesForTab: preferences.useSpacesForTab
            )
        }
        .frame(
            minWidth: IDEAppearance.Spacing.settingsWidth,
            idealWidth: IDEAppearance.Spacing.settingsWidth,
            minHeight: IDEAppearance.Spacing.settingsMinHeight
        )
        .background(IDEAppearance.ColorToken.workbench)
        .preferredColorScheme(.dark)
        .tint(IDEAppearance.ColorToken.accent)
        .onChange(of: preferences.fontSize) { _ in applyLivePreferences() }
        .onChange(of: preferences.keymapPreset) { _ in applyLivePreferences() }
        .onChange(of: preferences.showLineNumbers) { _ in applyLivePreferences() }
        .onChange(of: preferences.isLineFoldingEnabled) { _ in applyLivePreferences() }
        .onChange(of: preferences.wrapLines) { _ in applyLivePreferences() }
        .onChange(of: preferences.showMinimap) { _ in applyLivePreferences() }
        .onChange(of: preferences.isMetalRenderingEnabled) { _ in applyLivePreferences() }
    }

    private func applyLivePreferences() {
        workspace.applyPreferencesToAllHosts()
    }
}

private struct IDESettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            Text(title)
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, IDEAppearance.Spacing.md)
            .background(IDEAppearance.ColorToken.tabActive)
            .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.card, style: .continuous))
        }
    }
}

private struct IDESettingsRow<Control: View>: View {
    let title: String
    let control: Control

    init(title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(spacing: IDEAppearance.Spacing.md) {
            Text(title)
                .font(IDEAppearance.Typography.body)
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            Spacer(minLength: IDEAppearance.Spacing.md)
            control
        }
        .padding(.vertical, IDEAppearance.Spacing.sm)
    }
}

private struct IDESettingsToggleRow: View {
    let title: String
    var caption: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(IDEAppearance.Typography.body)
                    .foregroundStyle(IDEAppearance.ColorToken.foreground)
                if let caption {
                    Text(caption)
                        .font(IDEAppearance.Typography.caption)
                        .foregroundStyle(IDEAppearance.ColorToken.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.vertical, IDEAppearance.Spacing.sm)
        .help(caption ?? title)
    }
}

private struct IDESettingsSeparator: View {
    var body: some View {
        Rectangle()
            .fill(IDEAppearance.ColorToken.border)
            .frame(height: 1)
    }
}

private struct IDESettingsTypePreview: View {
    let fontSize: Double
    let tabWidth: Int
    let useSpacesForTab: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Text("Preview")
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .textCase(.uppercase)
                .accessibilityHidden(true)

            Text(previewSource)
                .font(.custom("Menlo", size: fontSize))
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(IDEAppearance.Spacing.md)
                .background(IDEAppearance.ColorToken.editor)
                .clipShape(RoundedRectangle(cornerRadius: IDEAppearance.Radius.control, style: .continuous))
                .accessibilityLabel(accessibilityPreview)
        }
        .padding(.horizontal, IDEAppearance.Spacing.lg)
        .padding(.vertical, IDEAppearance.Spacing.md)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(IDEAppearance.ColorToken.border)
                .frame(height: 1)
        }
        .background(IDEAppearance.ColorToken.sidebar)
    }

    private var previewSource: String {
        let indent = useSpacesForTab
            ? String(repeating: " ", count: tabWidth)
            : "\t"
        return "func greet(name: String) {\n\(indent)print(name)\n}"
    }

    private var accessibilityPreview: String {
        let indent = useSpacesForTab ? "spaces" : "tabs"
        let size = fontSize.formatted(.number.precision(.fractionLength(0)))
        return "Preview at \(size) points, indenting with \(indent), tab width \(tabWidth)"
    }
}

#Preview {
    IDEPreferencesView(preferences: IDEPreferences.shared)
        .environment(IDEWorkspace())
        .preferredColorScheme(.dark)
}
