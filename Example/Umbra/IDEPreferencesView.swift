import Penumbra
import SwiftUI

public struct IDEPreferencesView: View {
    @Bindable var preferences: IDEPreferences
    @Environment(IDEWorkspace.self) private var workspace

    public init(preferences: IDEPreferences) {
        self.preferences = preferences
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xl) {
                    IDESettingsSection(title: "Editor") {
                        IDESettingsRow(title: "Font") {
                            Picker("Font", selection: $preferences.fontName) {
                                ForEach(IDEEditorFonts.choices(including: preferences.fontName), id: \.self) { familyName in
                                    Text(familyName).tag(familyName)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 200)
                        }

                        IDESettingsSeparator()

                        IDESettingsRow(title: "Font Size") {
                            HStack(spacing: IDEAppearance.Spacing.xs) {
                                Text(preferences.fontSize, format: .number.precision(.fractionLength(0)))
                                    .font(IDEAppearance.Typography.monoCaption)
                                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                                    .monospacedDigit()
                                    .frame(width: 24, alignment: .trailing)
                                    .accessibilityHidden(true)
                                Stepper("Font Size", value: $preferences.fontSize, in: 9...32, step: 1)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .accessibilityLabel("Font Size")
                                    .accessibilityValue(
                                        Text(preferences.fontSize, format: .number.precision(.fractionLength(0)))
                                    )
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
                        IDESettingsRow(title: "Color Theme") {
                            Picker("Color Theme", selection: $preferences.themeID) {
                                ForEach(ThemeCatalog.palettes(preferring: true)) { palette in
                                    Text(palette.name).tag(palette.id)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 200)
                        }

                        IDESettingsSeparator()

                        IDESettingsToggleRow(
                            title: "Scale Markdown Headings",
                            caption: "Shows # headings at larger sizes in the editor.",
                            isOn: $preferences.scaleMarkdownHeadings
                        )
                        IDESettingsSeparator()
                        IDESettingsToggleRow(title: "Line Numbers", isOn: $preferences.showLineNumbers)
                        IDESettingsSeparator()
                        IDESettingsToggleRow(title: "Code Folding", isOn: $preferences.isLineFoldingEnabled)
                        IDESettingsSeparator()
                        IDESettingsToggleRow(title: "Word Wrap", isOn: $preferences.wrapLines)
                        IDESettingsSeparator()
                        IDESettingsToggleRow(title: "Minimap", isOn: $preferences.showMinimap)
                        IDESettingsSeparator()
                        IDESettingsToggleRow(
                            title: "Scrollbars",
                            caption: "The vertical scrollbar appears when the minimap is off.",
                            isOn: $preferences.showScrollbars
                        )
                        IDESettingsSeparator()
                        IDESettingsToggleRow(
                            title: "Metal Renderer",
                            caption: "Paints large files on the GPU.",
                            isOn: $preferences.isMetalRenderingEnabled
                        )
                        IDESettingsSeparator()
                        IDESettingsToggleRow(
                            title: "Method Separators",
                            caption: "A hairline between declarations, matching the right margin.",
                            isOn: $preferences.showMethodSeparators
                        )
                        IDESettingsSeparator()
                        IDESettingsToggleRow(
                            title: "Highlight Occurrences",
                            caption: "Emphasize other matches for the selection.",
                            isOn: $preferences.highlightsOccurrencesOfSelection
                        )
                        IDESettingsSeparator()
                        IDESettingsToggleRow(
                            title: "Invisible Characters",
                            caption: "Show tabs and spaces.",
                            isOn: $preferences.showInvisibleCharacters
                        )
                        IDESettingsSeparator()
                        IDESettingsToggleRow(
                            title: "Right Margin",
                            caption: "Show a vertical guide at the preferred line length.",
                            isOn: $preferences.showPageGuide
                        )
                        IDESettingsSeparator()
                        IDESettingsRow(title: "Margin Column") {
                            HStack(spacing: IDEAppearance.Spacing.xs) {
                                ForEach([80, 120], id: \.self) { preset in
                                    Button("\(preset)") {
                                        preferences.pageGuideColumn = preset
                                    }
                                    .buttonStyle(.borderless)
                                    .font(IDEAppearance.Typography.monoCaption)
                                    .foregroundStyle(
                                        preferences.pageGuideColumn == preset
                                            ? IDEAppearance.ColorToken.accent
                                            : IDEAppearance.ColorToken.muted
                                    )
                                    .disabled(!preferences.showPageGuide)
                                }
                                Text(preferences.pageGuideColumn, format: .number)
                                    .font(IDEAppearance.Typography.monoCaption)
                                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                                    .monospacedDigit()
                                    .frame(width: 28, alignment: .trailing)
                                    .accessibilityHidden(true)
                                Stepper("Margin Column", value: $preferences.pageGuideColumn, in: 40...200)
                                    .labelsHidden()
                                    .controlSize(.small)
                                    .disabled(!preferences.showPageGuide)
                            }
                        }
                        IDESettingsSeparator()
                        IDESettingsRow(title: "Line Height") {
                            HStack(spacing: IDEAppearance.Spacing.xs) {
                                Text(preferences.lineHeightMultiplier, format: .number.precision(.fractionLength(1)))
                                    .font(IDEAppearance.Typography.monoCaption)
                                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                                    .monospacedDigit()
                                    .frame(width: 28, alignment: .trailing)
                                    .accessibilityHidden(true)
                                Stepper("Line Height", value: $preferences.lineHeightMultiplier, in: 0.8...2.0, step: 0.1)
                                    .labelsHidden()
                                    .controlSize(.small)
                            }
                        }
                    }

                    IDESettingsSection(title: "View Modes") {
                        IDESettingsToggleRow(
                            title: "Typewriter Scrolling",
                            caption: "Keep the active line vertically centered.",
                            isOn: $preferences.isTypewriterScrollingEnabled
                        )
                        IDESettingsSeparator()
                        IDESettingsToggleRow(
                            title: "Distraction Free",
                            caption: "Fade chrome after a short idle period.",
                            isOn: $preferences.isDistractionFreeModeEnabled
                        )
                        IDESettingsSeparator()
                        IDESettingsToggleRow(
                            title: "Focus Mode",
                            caption: "Dim text outside the current sentence or paragraph.",
                            isOn: $preferences.isFocusModeEnabled
                        )
                    }

                    IDESettingsSection(title: "Explorer") {
                        IDESettingsToggleRow(
                            title: "Flatten Packages",
                            caption: "Show Java packages under each source root as single dotted rows.",
                            isOn: $preferences.flattenJavaPackages
                        )
                    }

                    IDESettingsSection(title: "Java") {
                        IDESettingsToggleRow(
                            title: "Sync Gradle Projects",
                            caption: "Resolve modules and dependencies when a Gradle project opens. Build scripts still run only after you trust the project.",
                            isOn: $preferences.javaGradleAutoSync
                        )
                        IDESettingsSeparator()
                        IDESettingsToggleRow(
                            title: "Compiler Diagnostics",
                            caption: "Check open Java files with the JDK's javac and list errors under Problems. Gradle projects are checked once they have synced.",
                            isOn: $preferences.javaCompilerDiagnostics
                        )
                        .onChange(of: preferences.javaCompilerDiagnostics) {
                            workspace.javaCompilerDiagnosticsPreferenceChanged()
                        }
                        IDESettingsSeparator()
                        IDESettingsToggleRow(
                            title: "Semantic Highlighting",
                            caption: "Colour Java types, methods, fields, parameters and locals by what they are, on top of the syntax colours.",
                            isOn: $preferences.semanticHighlighting
                        )
                        .onChange(of: preferences.semanticHighlighting) {
                            workspace.semanticHighlightingPreferenceChanged()
                        }
                        IDESettingsSeparator()
                        IDESettingsToggleRow(
                            title: "Optimize Imports on Save",
                            caption: "Remove unused imports from a Java file each time you save it. Java > Optimize Imports does the same on demand.",
                            isOn: $preferences.javaOptimizeImportsOnSave
                        )
                        IDESettingsSeparator()
                        IDESettingsRow(title: "Gradle Sync Timeout") {
                            HStack(spacing: IDEAppearance.Spacing.xs) {
                                Text("\(preferences.javaGradleSyncTimeoutSeconds)s")
                                    .font(IDEAppearance.Typography.monoCaption)
                                    .foregroundStyle(IDEAppearance.ColorToken.muted)
                                    .monospacedDigit()
                                    .frame(width: 48, alignment: .trailing)
                                    .accessibilityHidden(true)
                                Stepper(
                                    "Gradle Sync Timeout",
                                    value: $preferences.javaGradleSyncTimeoutSeconds,
                                    in: 30...3600,
                                    step: 30
                                )
                                .labelsHidden()
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .padding(IDEAppearance.Spacing.lg)
            }

            IDESettingsTypePreview(
                themeID: preferences.themeID,
                fontName: preferences.fontName,
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
        .onChange(of: preferences.fontName) { applyLivePreferences() }
        .onChange(of: preferences.fontSize) { applyLivePreferences() }
        .onChange(of: preferences.themeID) { applyLivePreferences() }
        .onChange(of: preferences.scaleMarkdownHeadings) { applyLivePreferences() }
        .onChange(of: preferences.keymapPreset) { applyLivePreferences() }
        .onChange(of: preferences.tabWidth) { applyLivePreferences() }
        .onChange(of: preferences.useSpacesForTab) { applyLivePreferences() }
        .onChange(of: preferences.showLineNumbers) { applyLivePreferences() }
        .onChange(of: preferences.isLineFoldingEnabled) { applyLivePreferences() }
        .onChange(of: preferences.wrapLines) { applyLivePreferences() }
        .onChange(of: preferences.showMinimap) { applyLivePreferences() }
        .onChange(of: preferences.showScrollbars) { applyLivePreferences() }
        .onChange(of: preferences.isMetalRenderingEnabled) { applyLivePreferences() }
        .onChange(of: preferences.showMethodSeparators) { applyLivePreferences() }
        .onChange(of: preferences.highlightsOccurrencesOfSelection) { applyLivePreferences() }
        .onChange(of: preferences.showInvisibleCharacters) { applyLivePreferences() }
        .onChange(of: preferences.showPageGuide) { applyLivePreferences() }
        .onChange(of: preferences.pageGuideColumn) { applyLivePreferences() }
        .onChange(of: preferences.lineHeightMultiplier) { applyLivePreferences() }
        .onChange(of: preferences.isTypewriterScrollingEnabled) { applyLivePreferences() }
        .onChange(of: preferences.isDistractionFreeModeEnabled) { applyLivePreferences() }
        .onChange(of: preferences.isFocusModeEnabled) { applyLivePreferences() }
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
    let themeID: String
    let fontName: String
    let fontSize: Double
    let tabWidth: Int
    let useSpacesForTab: Bool

    private var palette: ThemePalette {
        ThemeCatalog.palette(id: themeID, fallbackDark: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
            Text("Preview")
                .font(IDEAppearance.Typography.sectionHeader)
                .foregroundStyle(IDEAppearance.ColorToken.muted)
                .textCase(.uppercase)
                .accessibilityHidden(true)

            previewSourceView
                .font(Font(IDEEditorFonts.nsFont(familyName: fontName, size: CGFloat(fontSize))))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(IDEAppearance.Spacing.md)
                .background(Color(hex: palette.background))
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

    private var previewSourceView: Text {
        let indent = useSpacesForTab
            ? String(repeating: " ", count: tabWidth)
            : "\t"
        return Text("func ")
            .foregroundColor(Color(hex: palette.keyword))
        + Text("greet")
            .foregroundColor(Color(hex: palette.function))
        + Text("(name: ")
            .foregroundColor(Color(hex: palette.text))
        + Text("String")
            .foregroundColor(Color(hex: palette.type))
        + Text(") {\n")
            .foregroundColor(Color(hex: palette.text))
        + Text("\(indent)print")
            .foregroundColor(Color(hex: palette.function))
        + Text("(name)\n}")
            .foregroundColor(Color(hex: palette.text))
    }

    private var accessibilityPreview: String {
        let indent = useSpacesForTab ? "spaces" : "tabs"
        let size = fontSize.formatted(.number.precision(.fractionLength(0)))
        let themeName = palette.name
        return "Preview using \(themeName) in \(fontName) at \(size) points, indenting with \(indent), tab width \(tabWidth)"
    }
}

#Preview {
    IDEPreferencesView(preferences: IDEPreferences.shared)
        .environment(IDEWorkspace())
        .preferredColorScheme(.dark)
}
