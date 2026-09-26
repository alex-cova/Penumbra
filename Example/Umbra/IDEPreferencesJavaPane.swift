import JavaIntelligence
import Penumbra
import SwiftUI

struct IDEPreferencesJavaPane: View {
    @Bindable var preferences: IDEPreferences
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        Form {
            Section {
                Toggle("Sync Gradle Projects", isOn: $preferences.javaGradleAutoSync)

                IDEPreferencesIntStepper(
                    title: "Gradle Sync Timeout",
                    value: $preferences.javaGradleSyncTimeoutSeconds,
                    range: 30...3600,
                    step: 30,
                    valueWidth: 48,
                    valueSuffix: "s"
                )
            } header: {
                Text("Gradle")
            } footer: {
                Text("Resolves modules and dependencies when a Gradle project opens. Build scripts still run only after you trust the project. A first sync may download a Gradle distribution.")
            }

            Section {
                Toggle("Compiler Diagnostics", isOn: $preferences.javaCompilerDiagnostics)
                    .onChange(of: preferences.javaCompilerDiagnostics) {
                        workspace.javaCompilerDiagnosticsPreferenceChanged()
                    }

                Toggle("Semantic Highlighting", isOn: $preferences.semanticHighlighting)
                    .onChange(of: preferences.semanticHighlighting) {
                        workspace.semanticHighlightingPreferenceChanged()
                    }

                Toggle("Parameter Name Hints", isOn: $preferences.javaInlayHints)
                    .onChange(of: preferences.javaInlayHints) {
                        workspace.javaInlayHintsPreferenceChanged()
                    }
            } header: {
                Text("Analysis")
            } footer: {
                Text("Compiler diagnostics check open Java files with the JDK javac and list errors under Problems. Semantic highlighting colours types, methods, fields, parameters, and locals by role.")
            }

            Section {
                ForEach(JavaLineMarkerKind.allCases.sorted { $0.preferenceTitle < $1.preferenceTitle }, id: \.self) { kind in
                    Toggle(isOn: gutterIconBinding(kind)) {
                        Label {
                            Text(kind.preferenceTitle)
                        } icon: {
                            Image(nsImage: GutterLineMarkerGlyphs.image(for: kind.gutterIcon, pointSize: 14))
                        }
                    }
                }
            } header: {
                Text("Gutter Icons")
            } footer: {
                Text("Icons beside the line numbers for methods that implement or override another, types and methods that project subclasses implement or override, and recursive calls. Click an arrow to jump to the related declarations.")
            }

            Section {
                Toggle("Optimize Imports on Save", isOn: $preferences.javaOptimizeImportsOnSave)
            } header: {
                Text("Editing")
            } footer: {
                Text("Removes unused imports from a Java file each time you save it. Java > Optimize Imports does the same on demand.")
            }
        }
        .formStyle(.grouped)
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
