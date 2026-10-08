import JavaIntelligence
import Penumbra
import SwiftUI

struct IDEPreferencesJavaPane: View {
    @Bindable var preferences: IDEPreferences
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        IDEPreferencesJDKSection()

        IDESettingsSection(
            "Gradle",
            footer: "Resolves modules and dependencies when a Gradle project opens. Build scripts still run only after you trust the project. A first sync may download a Gradle distribution."
        ) {
            IDESettingsToggle("Sync Gradle Projects", isOn: $preferences.javaGradleAutoSync)

            IDEPreferencesIntStepper(
                title: "Sync Timeout",
                value: $preferences.javaGradleSyncTimeoutSeconds,
                range: 30...3600,
                step: 30,
                valueWidth: 48,
                valueSuffix: "s"
            )
        }

        IDESettingsSection("Analysis") {
            IDESettingsToggle(
                "Compiler Diagnostics",
                isOn: $preferences.javaCompilerDiagnostics,
                detail: "Checks open Java files with the JDK javac and lists errors under Problems."
            )
            .onChange(of: preferences.javaCompilerDiagnostics) {
                workspace.javaCompilerDiagnosticsPreferenceChanged()
            }

            IDESettingsToggle(
                "Semantic Highlighting",
                isOn: $preferences.semanticHighlighting,
                detail: "Colours types, methods, fields, parameters, and locals by role."
            )
            .onChange(of: preferences.semanticHighlighting) {
                workspace.semanticHighlightingPreferenceChanged()
            }

            IDESettingsToggle("Parameter Name Hints", isOn: $preferences.javaInlayHints)
                .onChange(of: preferences.javaInlayHints) {
                    workspace.javaInlayHintsPreferenceChanged()
                }

            IDESettingsToggle(
                "Use Editor Font for Hints",
                isOn: $preferences.inlayHintsUseEditorFont,
                detail: "Draws inlay hints in the editor font, one point smaller, instead of the system font."
            )
        }

        IDESettingsSection(
            "Gutter Icons",
            footer: "Icons beside the line numbers for methods that implement or override another, types and methods that project subclasses implement or override, and recursive calls. Click an arrow to jump to the related declarations."
        ) {
            ForEach(JavaLineMarkerKind.allCases.sorted { $0.preferenceTitle < $1.preferenceTitle }, id: \.self) { kind in
                Toggle(isOn: gutterIconBinding(kind)) {
                    Label {
                        Text(kind.preferenceTitle)
                            .foregroundStyle(IDEAppearance.ColorToken.foreground)
                    } icon: {
                        Image(nsImage: GutterLineMarkerGlyphs.image(for: kind.gutterIcon, pointSize: 14))
                    }
                }
                .toggleStyle(.checkbox)
            }
        }

        IDESettingsSection("Editing") {
            IDESettingsToggle(
                "Optimize Imports on Save",
                isOn: $preferences.javaOptimizeImportsOnSave,
                detail: "Removes unused imports each time you save a Java file. Java > Optimize Imports does the same on demand."
            )
        }
    }

    private func gutterIconBinding(_ kind: JavaLineMarkerKind) -> Binding<Bool> {
        Binding {
            !preferences.javaDisabledGutterIcons.contains(kind)
        } set: { isOn in
            if isOn {
                preferences.javaDisabledGutterIcons.remove(kind)
            } else {
                preferences.javaDisabledGutterIcons.insert(kind)
            }
            workspace.javaGutterIconsPreferenceChanged()
        }
    }
}
