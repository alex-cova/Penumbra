import JavaIntelligence
import Penumbra
import SwiftUI

/// Java in Umbra's chrome: the Java palette commands, the Java menu, the Java and Inspections settings
/// pages, and the Debug, Test Results, Hierarchy, Call Hierarchy and Gradle tool windows. The
/// intelligence is `JavaLanguageService`; the project, run and debug machinery is still the workspace's
/// and `IDEJavaSupport` (plan, phase 5).
struct IDEJavaModule: IDELanguageModule {
    static let id = "java"
    var id: String { Self.id }

    func commands(for workspace: IDEWorkspace) -> [EditorCommand] {
        [
            EditorCommand(id: "app.java.buildGradleProject", title: "Java: Build Project", group: "Java",
                          action: { [weak workspace] in workspace?.buildGradleProject() }),
            EditorCommand(id: "app.java.runTests", title: "Java: Run Tests", group: "Java",
                          action: { [weak workspace] in workspace?.runActiveJavaTests() }),
            EditorCommand(id: "app.java.runLastConfiguration", title: "Java: Run Last Configuration", group: "Java",
                          action: { [weak workspace] in workspace?.runLastRunConfiguration() }),
            EditorCommand(id: "app.java.editRunConfiguration", title: "Java: Edit Configurations…", group: "Java",
                          action: { [weak workspace] in workspace?.editRunConfiguration() }),
            EditorCommand(id: "app.java.reloadGradleProject", title: "Java: Reload Gradle Project", group: "Java",
                          action: { [weak workspace] in workspace?.reloadGradleProject() }),
            EditorCommand(id: "app.java.showGradleOutput", title: "Java: Show Gradle Output", group: "Java",
                          action: { [weak workspace] in workspace?.showGradleOutput() }),
            EditorCommand(id: "app.java.showClassDiagram", title: "Java: Show Class Diagram", group: "Java",
                          action: { [weak workspace] in workspace?.showClassDiagramForActiveFile() }),
            EditorCommand(id: "app.java.showPackageDiagram", title: "Java: Show Package Class Diagram", group: "Java",
                          action: { [weak workspace] in workspace?.showClassDiagramForActivePackage() }),
            EditorCommand(id: "app.java.showProjectDiagram", title: "Java: Show Project Class Diagram", group: "Java",
                          action: { [weak workspace] in workspace?.showClassDiagramForProject() }),
            EditorCommand(id: "app.java.showGradleModuleDiagram", title: "Gradle: Show Module Diagram", group: "Java",
                          action: { [weak workspace] in workspace?.showGradleModuleDiagram() }),
            EditorCommand(id: "app.java.showGradleDependencyDiagram", title: "Gradle: Show Dependency Diagram", group: "Java",
                          action: { [weak workspace] in workspace?.showGradleDependencyDiagram() })
        ]
    }

    func toolWindows(for workspace: IDEWorkspace) -> [IDEToolWindow] {
        var windows: [IDEToolWindow] = []
        if workspace.showsLeadingToolWindows {
            if workspace.showsDebugTab {
                windows.append(workspace.bottomToolWindow(
                    .debug, "ladybug", "Debug", nil, .red, .leadingBottom, order: IDEToolWindow.Order.debug
                ))
            }
            if workspace.showsTestResultsTab {
                windows.append(workspace.bottomToolWindow(
                    .testResults, "flask", "Test Results", nil, .green, .leadingBottom, order: IDEToolWindow.Order.testResults
                ))
            }
            if workspace.showsTypeHierarchyTab {
                windows.append(workspace.bottomToolWindow(
                    .typeHierarchy, "list.bullet.indent", "Hierarchy", nil, .secondary, .leadingBottom,
                    order: IDEToolWindow.Order.typeHierarchy
                ))
            }
            if workspace.showsCallHierarchyTab {
                windows.append(workspace.bottomToolWindow(
                    .callHierarchy, "phone.arrow.down.left", "Call Hierarchy", nil, .secondary, .leadingBottom,
                    order: IDEToolWindow.Order.callHierarchy
                ))
            }
        }
        if workspace.javaSupport.isGradleProject {
            windows.append(IDEToolWindow(
                id: "gradle", systemImage: "square.stack.3d.up", title: "Gradle", shortcut: nil, tint: .purple,
                placement: .trailingTop, isOpen: workspace.showsGradleSidebar,
                toggle: { [weak workspace] in workspace?.toggleGradleSidebar() },
                order: IDEToolWindow.Order.gradleSidebar
            ))
        }
        if workspace.showsGradleConsoleTab {
            windows.append(workspace.bottomToolWindow(
                .gradle, "text.alignleft", "Gradle Console", nil, .purple, .trailingBottom,
                order: IDEToolWindow.Order.gradleConsole
            ))
        }
        return windows
    }

    /// The Java menu exists for a Java file or a Gradle project, the same condition as the JDK picker.
    func menu(for workspace: IDEWorkspace) -> IDEModuleMenu? {
        guard workspace.showsJDKPicker else { return nil }
        return IDEModuleMenu(title: "Java") { ref in AnyView(IDEJavaCommands(ref: ref)) }
    }

    var preferencePanes: [IDEPreferencesPane] {
        [
            IDEPreferencesPane(domain: .java) { preferences, _ in AnyView(IDEPreferencesJavaPane(preferences: preferences)) },
            IDEPreferencesPane(domain: .inspections) { preferences, _ in
                AnyView(IDEPreferencesInspectionsPane(preferences: preferences))
            }
        ]
    }
}

/// The Java menu: refactorings, Gradle and the project JDK.
private struct IDEJavaCommands: View {
    let ref: IDEWorkspaceRef

    /// Resolved when read, never stored: menu actions run long after this view was built, and a
    /// stored workspace would stay alive with them after its window closed.
    private var workspace: IDEWorkspace? { ref.workspace }

    private var preset: KeymapPreset { IDEPreferences.shared.keymapPreset }

    var body: some View {
        Button("Show Context Actions", action: { workspace?.showContextActions() })
            .menuShortcut(.showContextActions, in: preset)
        Button("Parameter Info", action: { workspace?.showParameterInfo() })
            .menuShortcut(.parameterInfo, in: preset)
        Button("Go to Super Method", action: { workspace?.goToSuperMethod() })
        Button("Go to Type Declaration", action: { workspace?.goToTypeDefinition() })
            .menuShortcut(.goToTypeDefinition, in: preset)
        Button("Rename…", action: { workspace?.renameSymbol() })
        Button("Extract Variable…", action: { workspace?.extractVariable() })
            .menuShortcut(.extractVariable, in: preset)
        Button("Extract Field…", action: { workspace?.extractField() })
            .menuShortcut(.extractField, in: preset)
        Button("Extract Constant…", action: { workspace?.extractConstant() })
            .menuShortcut(.extractConstant, in: preset)
        Button("Extract Method…", action: { workspace?.extractMethod() })
            .menuShortcut(.extractMethod, in: preset)
        Button("Inline Variable", action: { workspace?.inlineVariable() })
            .menuShortcut(.inlineVariable, in: preset)
        Button("Inline Method", action: { workspace?.inlineMethod() })
        Button("Change Method Signature…", action: { workspace?.changeMethodSignature() })
        Button("Encapsulate Field", action: { workspace?.encapsulateField() })
            .menuShortcut(.encapsulateField, in: preset)
        Button("Generate…", action: { workspace?.generate() })
        Button("Generate Getter and Setter", action: { workspace?.generateAccessors() })
        Button("Move Class…", action: { workspace?.moveClass() })
        Button("Safe Delete", action: { workspace?.safeDelete() })
        Button("Reformat Code", action: { workspace?.reformatCode() })
        Button("Type Hierarchy") { workspace?.showTypeHierarchy() }
        Button("Call Hierarchy") { workspace?.showCallHierarchy() }
        Menu("Diagrams") {
            Button("Show Class Diagram") { workspace?.showClassDiagramForActiveFile() }
                .disabled(!(workspace?.canShowClassDiagram ?? false))
            Button("Show Package Class Diagram") { workspace?.showClassDiagramForActivePackage() }
                .disabled(workspace?.activeJavaFileURL == nil)
            Button("Show Project Class Diagram") { workspace?.showClassDiagramForProject() }
                .disabled(!(workspace?.canShowClassDiagram ?? false))
            Divider()
            Button("Show Gradle Module Diagram") { workspace?.showGradleModuleDiagram() }
                .disabled(!(workspace?.javaSupport.isGradleProject ?? false))
            Button("Show Gradle Dependency Diagram") { workspace?.showGradleDependencyDiagram() }
                .disabled(!(workspace?.javaSupport.isGradleProject ?? false))
        }
        Divider()
        Button("Optimize Imports", action: { workspace?.optimizeImports() })
        Divider()
        Menu("Project JDK") {
            IDEJDKMenuFromRef(ref: ref)
        }
        Button("Build Project", systemImage: "hammer", action: { workspace?.buildGradleProject() })
            .disabled(!(workspace?.javaSupport.isGradleProject ?? false))
        Button("Reload Gradle Project", action: { workspace?.reloadGradleProject() })
            .disabled(!(workspace?.javaSupport.isGradleProject ?? false))
        Button("Show Gradle Output", action: { workspace?.showGradleOutput() })
            .disabled(workspace?.javaSupport.gradleConsole.lines.isEmpty ?? true)
    }
}

extension IDEPreferencesDomain {
    static let java = IDEPreferencesDomain(
        id: "java", title: "Java", symbol: "cup.and.saucer",
        searchTerms: ["jdk", "gradle", "sync", "timeout", "diagnostics", "compiler", "semantic highlighting", "parameter hints", "inlay", "gutter icons", "imports", "optimize imports", "run", "run configuration", "temporary"]
    )

    static let inspections = IDEPreferencesDomain(
        id: "inspections", title: "Inspections", symbol: "checklist",
        searchTerms: ["warnings", "severity", "code analysis", "quick fix", "lint", "probable bugs", "redundant code", "unused", "suppress", "noinspection"]
            + JavaInspectionRule.allCases.map(\.title)
    )
}
