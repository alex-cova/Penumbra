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
                Toggle("Optimize Imports on Save", isOn: $preferences.javaOptimizeImportsOnSave)
            } header: {
                Text("Editing")
            } footer: {
                Text("Removes unused imports from a Java file each time you save it. Java > Optimize Imports does the same on demand.")
            }
        }
        .formStyle(.grouped)
    }
}
