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

        IDESettingsSection(
            "Run",
            footer: "Running a class or a test from its gutter button makes a temporary run configuration. Only the newest few are kept, shown faded in the run picker; Save Configuration keeps one for good."
        ) {
            IDEPreferencesIntStepper(
                title: "Temporary Configurations",
                value: $preferences.runTemporaryConfigurationLimit,
                range: 1...50,
                valueWidth: 32
            )
        }

        IDESettingsSection(
            "Coverage",
            footer: "Run ▸ Run with Coverage starts the program or the tests with the JaCoCo agent and paints the lines the run executed. Editing a file removes its colours, since they describe the text that ran."
        ) {
            IDESettingsToggle("Show Coverage in the Editor", isOn: $preferences.javaCoverageShowsInEditor)
                .onChange(of: preferences.javaCoverageShowsInEditor) {
                    workspace.refreshCoverageBands()
                }
            IDESettingsToggle(
                "Include Test Sources",
                isOn: $preferences.javaCoverageIncludesTests,
                detail: "Reports on the test classes too."
            )
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
                Text("Package Filter")
                TextField("com.acme, org.example.util", text: $preferences.javaCoveragePackageFilter)
                    .textFieldStyle(.roundedBorder)
                    .font(IDEAppearance.Typography.monoSmall)
                Text("Limits the report to these packages and their subpackages. Empty reports on all of them.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            IDESettingsToggle(
                "Clear Coverage on the Next Run",
                isOn: $preferences.javaCoverageClearsOnRun,
                detail: "Off keeps the previous colours until the new report is ready."
            )
            IDESettingsToggle("Open the Coverage Tab After a Run", isOn: $preferences.javaCoverageOpensWindow)
        }

        IDESettingsSection(
            "Profiling",
            footer: "Profile uses Java Flight Recorder, which comes with the JDK (Java 11 or newer). Nothing is attached to a running program: the recording is made by the JVM Umbra starts."
        ) {
            IDEPreferencesIntStepper(
                title: "CPU Sample Period",
                value: $preferences.javaProfileSamplePeriod,
                range: 0...100,
                valueWidth: 40,
                valueSuffix: "ms"
            )
            IDESettingsToggle("Open the Recording After a Run", isOn: $preferences.javaProfileOpensRecording)
            IDEPreferencesIntStepper(
                title: "Ask Before Reading Over",
                value: $preferences.javaProfileConfirmMegabytes,
                range: 50...5000,
                step: 50,
                valueWidth: 48,
                valueSuffix: "MB"
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
                "Variable Type Hints",
                isOn: $preferences.javaInlayVariableTypes,
                detail: "Shows the type after a `var` local or loop variable, unless the initializer already says it (`new Foo()`, a cast, a literal)."
            )
            .onChange(of: preferences.javaInlayVariableTypes) {
                workspace.javaInlayHintsPreferenceChanged()
            }

            IDESettingsToggle(
                "Lambda Parameter Type Hints",
                isOn: $preferences.javaInlayLambdaTypes,
                detail: "Shows the types of implicitly typed lambda parameters, read off the method they are passed to."
            )
            .onChange(of: preferences.javaInlayLambdaTypes) {
                workspace.javaInlayHintsPreferenceChanged()
            }

            IDESettingsToggle(
                "Code Vision: Usages",
                isOn: $preferences.javaCodeVisionUsages,
                detail: "Shows how many places use a class, method or constructor above its declaration. Counts come from the project index, so they follow saved files."
            )

            IDESettingsToggle(
                "Code Vision: Implementations",
                isOn: $preferences.javaCodeVisionImplementations,
                detail: "Shows how many project types implement an interface, abstract class or abstract method."
            )

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
