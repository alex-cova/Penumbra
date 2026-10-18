import EditorIntelligence
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
            "Maven",
            footer: "Reading POMs needs no trust. Goals and downloads run only after you trust the project."
        ) {
            IDESettingsToggle("Read Maven Projects", isOn: $preferences.javaMavenAutoRead)
            IDESettingsToggle(
                "Download Dependencies",
                isOn: $preferences.javaMavenDownloadDependencies,
                detail: "Fetches jars that are not already in the local repository."
            )
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
                Text("Maven Executable")
                TextField("mvn on PATH", text: $preferences.javaMavenExecutable)
                    .textFieldStyle(.roundedBorder)
                    .font(IDEAppearance.Typography.monoSmall)
                Text("Used when the project has no mvnw. Empty looks up mvn.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
                Text("User Settings File")
                TextField("~/.m2/settings.xml", text: $preferences.javaMavenSettingsFile)
                    .textFieldStyle(.roundedBorder)
                    .font(IDEAppearance.Typography.monoSmall)
                Text("Passed as mvn -s. Empty uses Maven's own settings lookup.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            IDEPreferencesIntStepper(
                title: "Goal Timeout",
                value: $preferences.javaMavenGoalTimeoutSeconds,
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
            footer: "Profile uses Java Flight Recorder, which comes with the JDK (Java 11 or newer). Nothing is attached to a running program: the recording is made by the JVM Umbra starts. 0 keeps the recording settings' own value; the period, allocation rate and wait threshold need Java 17, and a custom .jfc file carries them on older JDKs."
        ) {
            IDESettingsPicker("Recording Settings", selection: $preferences.javaProfileSettings) {
                Text("Profile (about 2% overhead)").tag("profile")
                Text("Default (about 1%)").tag("default")
                Text("Custom .jfc file").tag("custom")
            }
            if preferences.javaProfileSettings == "custom" {
                IDESettingsRow("Settings File") {
                    HStack(spacing: IDEAppearance.Spacing.xs) {
                        Text(preferences.javaProfileSettingsFile.isEmpty
                            ? "None chosen" : URL(fileURLWithPath: preferences.javaProfileSettingsFile).lastPathComponent)
                            .font(IDEAppearance.Typography.caption)
                            .foregroundStyle(IDEAppearance.ColorToken.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseFiles = true
                            panel.canChooseDirectories = false
                            panel.message = "Choose a Java Flight Recorder settings file (.jfc), made in JDK Mission Control."
                            panel.allowsOtherFileTypes = true
                            if panel.runModal() == .OK, let url = panel.url { preferences.javaProfileSettingsFile = url.path }
                        }
                        .controlSize(.small)
                    }
                }
            }
            IDEPreferencesIntStepper(
                title: "CPU Sample Period",
                value: $preferences.javaProfileSamplePeriod,
                range: 0...100,
                valueWidth: 40,
                valueSuffix: "ms"
            )
            IDEPreferencesIntStepper(
                title: "Stack Depth",
                value: $preferences.javaProfileStackDepth,
                range: 16...JavaFlightRecorder.maximumStackDepth,
                step: 16,
                valueWidth: 40
            )
            IDEPreferencesIntStepper(
                title: "Allocation Samples per Second",
                value: $preferences.javaProfileAllocationRate,
                range: 0...5000,
                step: 50,
                valueWidth: 48,
                valueSuffix: "/s"
            )
            IDEPreferencesIntStepper(
                title: "Shortest Wait Recorded",
                value: $preferences.javaProfileWaitThreshold,
                range: 0...1000,
                step: 5,
                valueWidth: 48,
                valueSuffix: "ms"
            )
            IDESettingsToggle(
                "Show Live Charts While Running",
                isOn: $preferences.javaProfileShowsLiveCharts,
                detail: "Opens the profiler when a run starts, with CPU, heap and thread charts, Capture Snapshot and Perform GC. The report fills in when the program ends."
            )
            IDESettingsToggle(
                "Show Profile Hints in the Editor",
                isOn: $preferences.javaProfileLineHints,
                detail: "Each line of an open Java file gets its share of the profile you are looking at, and the hottest lines are tinted. It replaces the Git blame column while it is showing."
            )
            .onChange(of: preferences.javaProfileLineHints) { workspace.profileLineHintsPreferenceChanged() }
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
            "Postfix Completion",
            footer: "The expansion key applies a template when the caret is just after .key and the popup is closed. A word that is not a template is typed normally. ⌘J in the IntelliJ keymap lists the templates that apply at the caret."
        ) {
            IDESettingsToggle("Enable Postfix Completion", isOn: postfixEnabled)
            IDESettingsPicker("Expand With", selection: postfixExpansionKey) {
                ForEach(PostfixExpansionKey.allCases, id: \.self) { key in
                    Text(key.title).tag(key)
                }
            }
            .disabled(!preferences.javaPostfix.isEnabled)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(JavaPostfixConfiguration.builtInKeys, id: \.self) { key in
                    Toggle(key, isOn: postfixKeyBinding(key))
                        .toggleStyle(.checkbox)
                }
            }
            .disabled(!preferences.javaPostfix.isEnabled)
            postfixCustomTemplates
        }
        .onChange(of: preferences.javaPostfix) {
            workspace.applyPreferencesToAllHosts()
        }

        IDESettingsSection(
            "Imports",
            footer: "An unresolved type is imported after a pause when only one class matches. Several matches stay for Show Context Actions. A package becomes a star import at the class count, and one class's static imports at the names count. 999 never collapses. Excluded classes and packages are never imported or offered."
        ) {
            IDESettingsToggle(
                "Add Unambiguous Imports on the Fly",
                isOn: $preferences.javaAddUnambiguousImports
            )
            .onChange(of: preferences.javaAddUnambiguousImports) {
                workspace.applyCodeInsightPreferences()
            }

            IDESettingsToggle(
                "Insert Imports on Paste",
                isOn: $preferences.javaInsertImportsOnPaste,
                detail: "Adds imports for unresolved types in pasted code."
            )
            .onChange(of: preferences.javaInsertImportsOnPaste) {
                workspace.applyCodeInsightPreferences()
            }

            IDESettingsToggle(
                "Use Single Class Imports",
                isOn: $preferences.javaUseSingleClassImports,
                detail: "Off writes import pkg.* once a second class from that package is imported."
            )
            .onChange(of: preferences.javaUseSingleClassImports) {
                workspace.applyCodeInsightPreferences()
            }

            IDEPreferencesIntStepper(
                title: "Class Count to Use '*'",
                value: $preferences.javaClassCountToUseStarImport,
                range: 1...999,
                valueWidth: 36
            )
            .onChange(of: preferences.javaClassCountToUseStarImport) {
                workspace.applyCodeInsightPreferences()
            }

            IDEPreferencesIntStepper(
                title: "Names Count to Use Static '*'",
                value: $preferences.javaStaticCountToUseStarImport,
                range: 1...999,
                valueWidth: 36
            )
            .onChange(of: preferences.javaStaticCountToUseStarImport) {
                workspace.applyCodeInsightPreferences()
            }

            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
                Text("Exclude Classes and Packages")
                TextField("java.awt.List, java.awt", text: $preferences.javaImportExclusions)
                    .textFieldStyle(.roundedBorder)
                    .font(IDEAppearance.Typography.monoSmall)
                Text("A package name excludes classes in that package, not in a subpackage.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            .onChange(of: preferences.javaImportExclusions) {
                workspace.applyCodeInsightPreferences()
            }

            VStack(alignment: .leading, spacing: IDEAppearance.Spacing.xs) {
                Text("Classes to Import Static Members From")
                TextField("java.util.Objects", text: $preferences.javaStaticMemberClasses)
                    .textFieldStyle(.roundedBorder)
                    .font(IDEAppearance.Typography.monoSmall)
                Text("Completion can insert import static for their public members. A leading minus drops one member, such as -java.util.Objects.requireNonNull.")
                    .font(IDEAppearance.Typography.caption)
                    .foregroundStyle(IDEAppearance.ColorToken.muted)
            }
            .onChange(of: preferences.javaStaticMemberClasses) {
                workspace.applyCodeInsightPreferences()
            }
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

        IDEPreferencesIntentionsPane(preferences: preferences)

        IDEPreferencesInspectionsPane(preferences: preferences)
    }

    private var postfixEnabled: Binding<Bool> {
        Binding {
            preferences.javaPostfix.isEnabled
        } set: { isOn in
            updatePostfix { $0.isEnabled = isOn }
        }
    }

    private var postfixExpansionKey: Binding<PostfixExpansionKey> {
        Binding {
            preferences.javaPostfix.expansionKey
        } set: { key in
            updatePostfix { $0.expansionKey = key }
        }
    }

    private func postfixKeyBinding(_ key: String) -> Binding<Bool> {
        Binding {
            !preferences.javaPostfix.disabledKeys.contains(key)
        } set: { isOn in
            updatePostfix { configuration in
                if isOn {
                    configuration.disabledKeys.removeAll { $0 == key }
                } else if !configuration.disabledKeys.contains(key) {
                    configuration.disabledKeys.append(key)
                    configuration.disabledKeys.sort()
                }
            }
        }
    }

    private func updatePostfix(_ change: (inout JavaPostfixConfiguration) -> Void) {
        var configuration = preferences.javaPostfix
        change(&configuration)
        preferences.javaPostfix = configuration
    }

    private var postfixCustomTemplates: some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.md) {
            Text("Custom Templates")
                .font(IDEAppearance.Typography.body.weight(.semibold))
                .foregroundStyle(IDEAppearance.ColorToken.foreground)
            ForEach(preferences.javaPostfix.customTemplates) { template in
                postfixCustomTemplate(template)
            }
            Button("Add Template") {
                updatePostfix { $0.customTemplates.append(JavaPostfixCustomTemplate(key: "")) }
            }
            .disabled(!preferences.javaPostfix.isEnabled)
        }
        .disabled(!preferences.javaPostfix.isEnabled)
    }

    private func postfixCustomTemplate(_ template: JavaPostfixCustomTemplate) -> some View {
        VStack(alignment: .leading, spacing: IDEAppearance.Spacing.sm) {
            HStack {
                TextField("Key", text: postfixTemplateBinding(template.id, \.key))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Picker("Applies to", selection: postfixApplicableTag(template.id)) {
                    Text("Any").tag("any")
                    Text("Boolean").tag("boolean")
                    Text("Non-void").tag("nonVoid")
                    Text("Iterable").tag("iterable")
                    Text("Array").tag("array")
                    Text("String").tag("string")
                    Text("Number").tag("number")
                    Text("Class").tag("class")
                }
                .labelsHidden()
                .frame(width: 140)
                Spacer()
                Button("Remove") {
                    updatePostfix { $0.customTemplates.removeAll { $0.id == template.id } }
                }
            }
            if case .qualifiedClass = template.applicable {
                TextField("Qualified class", text: postfixQualifiedClass(template.id))
                    .textFieldStyle(.roundedBorder)
            }
            TextField("Body ($EXPR$ is the receiver)", text: postfixTemplateBinding(template.id, \.body), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...6)
            Toggle("Apply to the topmost expression", isOn: postfixTemplateBinding(template.id, \.topmost))
                .toggleStyle(.checkbox)
            Toggle("Use static import if possible", isOn: postfixTemplateBinding(template.id, \.useStaticImport))
                .toggleStyle(.checkbox)
        }
        .padding(.vertical, 4)
    }

    private func postfixTemplateBinding<Value>(_ id: UUID, _ keyPath: WritableKeyPath<JavaPostfixCustomTemplate, Value>) -> Binding<Value> {
        Binding {
            preferences.javaPostfix.customTemplates.first { $0.id == id }?[keyPath: keyPath] ?? JavaPostfixCustomTemplate(key: "")[keyPath: keyPath]
        } set: { newValue in
            updatePostfix { configuration in
                guard let index = configuration.customTemplates.firstIndex(where: { $0.id == id }) else { return }
                configuration.customTemplates[index][keyPath: keyPath] = newValue
            }
        }
    }

    private func postfixApplicableTag(_ id: UUID) -> Binding<String> {
        Binding {
            guard let template = preferences.javaPostfix.customTemplates.first(where: { $0.id == id }) else { return "any" }
            switch template.applicable {
            case .any: return "any"
            case .boolean: return "boolean"
            case .nonVoid: return "nonVoid"
            case .iterable: return "iterable"
            case .array: return "array"
            case .string: return "string"
            case .number: return "number"
            case .qualifiedClass: return "class"
            }
        } set: { tag in
            updatePostfix { configuration in
                guard let index = configuration.customTemplates.firstIndex(where: { $0.id == id }) else { return }
                let current = configuration.customTemplates[index].applicable
                configuration.customTemplates[index].applicable = switch tag {
                case "boolean": .boolean
                case "nonVoid": .nonVoid
                case "iterable": .iterable
                case "array": .array
                case "string": .string
                case "number": .number
                case "class":
                    if case .qualifiedClass(let name) = current { .qualifiedClass(name) } else { .qualifiedClass("") }
                default: .any
                }
            }
        }
    }

    private func postfixQualifiedClass(_ id: UUID) -> Binding<String> {
        Binding {
            guard let template = preferences.javaPostfix.customTemplates.first(where: { $0.id == id }),
                  case .qualifiedClass(let name) = template.applicable else { return "" }
            return name
        } set: { name in
            updatePostfix { configuration in
                guard let index = configuration.customTemplates.firstIndex(where: { $0.id == id }) else { return }
                configuration.customTemplates[index].applicable = .qualifiedClass(name)
            }
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
