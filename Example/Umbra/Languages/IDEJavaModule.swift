import JavaIntelligence
import Penumbra
import SwiftUI

/// Java in Umbra's chrome: the Java palette commands, the Java menu, the Java and Inspections settings
/// pages, the Debug, Test Results, Hierarchy and Call Hierarchy tool windows, the Run tab and the
/// Breakpoints sidebar tab. The intelligence is `JavaLanguageService`; Run and Test are
/// `IDEJavaRunProvider` (made by `makeRunProvider`), and the Gradle project, its sidebar and its console
/// are `IDEGradleProjectSystem`'s. The debugger is the workspace's (Java-only).
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
                          action: { [weak workspace] in workspace?.reloadProject() }),
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

    func toolbarItems(for workspace: IDEWorkspace) -> [IDEToolbarItem] {
        typealias Order = IDEToolbarItem.Order
        var items = [IDEToolbarItem(id: "java.runConfigurations", order: Order.runConfigurations, content: .custom(AnyView(IDERunConfigurationMenu())))]
        let canRun = workspace.runFileCanRun
        let isRunActive = workspace.isRunActive
        if canRun {
            items.append(.button(
                id: "java.run", order: Order.run, systemImage: "play.fill", help: workspace.runHelp,
                tint: IDEAppearance.ColorToken.run, action: { [weak workspace] in workspace?.runActiveFile() }
            ))
            let canDebug = workspace.runFileCanDebug
            items.append(.button(
                id: "java.debug", order: Order.debug, systemImage: "ladybug.fill", help: workspace.debugHelp,
                tint: canDebug ? IDEAppearance.ColorToken.run : nil, isEnabled: canDebug,
                action: { [weak workspace] in workspace?.debugActiveFile() }
            ))
        }
        // Stays up while something runs, even after switching to a file that can't run.
        if canRun || isRunActive {
            items.append(.button(
                id: "java.stop", order: Order.stop, systemImage: "stop.fill", help: "Stop",
                tint: isRunActive ? IDEAppearance.ColorToken.error : nil, isEnabled: isRunActive,
                action: { [weak workspace] in workspace?.stopRunning() }
            ))
        }
        if workspace.javaFileCanTest {
            items.append(.button(
                id: "java.runTests", order: Order.tests, systemImage: "flask", help: "Run Tests",
                action: { [weak workspace] in workspace?.runActiveJavaTests() }
            ))
        }
        return items
    }

    func statusItems(for workspace: IDEWorkspace) -> [IDEStatusItem] {
        guard workspace.showsJDKPicker else { return [] }
        return [IDEStatusItem(id: "java.jdk", placement: .trailing, order: 100, content: AnyView(IDEJDKStatusItem()))]
    }

    func makeRunProvider(for workspace: IDEWorkspace) -> (any IDERunProvider)? {
        IDEJavaRunProvider(host: workspace, java: workspace.javaSupport)
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
        return windows
    }

    func bottomTabs(for workspace: IDEWorkspace) -> [IDEBottomTabContribution] {
        typealias Order = IDEBottomPanelTab.Order
        var tabs: [IDEBottomTabContribution] = []
        if workspace.showsRunTab {
            tabs.append(IDEBottomTabContribution(
                tab: .run, order: Order.run,
                item: { workspace in
                    AnyView(IDERunTabItem(
                        isSelected: workspace.isBottomTabSelected(.run),
                        isRunning: workspace.runs.isAnyActive,
                        onSelect: { [weak workspace] in workspace?.showBottomTab(.run) }
                    ))
                },
                content: { _ in AnyView(IDERunPanel()) },
                controls: { _ in AnyView(IDERunControls()) }
            ))
        }
        if workspace.showsTypeHierarchyTab {
            tabs.append(IDEBottomTabContribution(
                tab: .typeHierarchy, order: Order.typeHierarchy,
                item: { workspace in
                    AnyView(IDETypeHierarchyTabItem(
                        title: workspace.typeHierarchy.root.map { "Hierarchy · \($0.name)" } ?? "Hierarchy",
                        isSelected: workspace.isBottomTabSelected(.typeHierarchy),
                        onSelect: { [weak workspace] in workspace?.showBottomTab(.typeHierarchy) }
                    ))
                },
                content: { _ in AnyView(IDETypeHierarchyPanel()) }
            ))
        }
        if workspace.showsTestResultsTab {
            tabs.append(IDEBottomTabContribution(
                tab: .testResults, order: Order.testResults,
                item: { workspace in
                    let results = workspace.testResults
                    let total = results.passedCount + results.failedCount + results.skippedCount
                    return AnyView(IDETestResultsTabItem(
                        title: results.isRunning ? "Tests · …" : "Tests · \(results.passedCount)/\(total)",
                        isSelected: workspace.isBottomTabSelected(.testResults),
                        onSelect: { [weak workspace] in workspace?.showBottomTab(.testResults) }
                    ))
                },
                content: { _ in AnyView(IDETestResultsPanel()) }
            ))
        }
        if workspace.showsDebugTab {
            tabs.append(IDEBottomTabContribution(
                tab: .debug, order: Order.debug,
                item: { workspace in
                    AnyView(IDEDebugTabItem(
                        isSelected: workspace.isBottomTabSelected(.debug),
                        onSelect: { [weak workspace] in workspace?.showBottomTab(.debug) }
                    ))
                },
                content: { _ in AnyView(IDEDebugPanel()) }
            ))
        }
        if workspace.showsCallHierarchyTab {
            tabs.append(IDEBottomTabContribution(
                tab: .callHierarchy, order: Order.callHierarchy,
                item: { workspace in
                    AnyView(IDECallHierarchyTabItem(
                        title: workspace.callHierarchy.root.map { "Calls · \($0.name)" } ?? "Calls",
                        isSelected: workspace.isBottomTabSelected(.callHierarchy),
                        onSelect: { [weak workspace] in workspace?.showBottomTab(.callHierarchy) }
                    ))
                },
                content: { _ in AnyView(IDECallHierarchyPanel()) }
            ))
        }
        return tabs
    }

    /// The Java menu exists for a Java file or a Gradle project, the same condition as the JDK picker.
    func menu(for workspace: IDEWorkspace) -> IDEModuleMenu? {
        guard workspace.showsJDKPicker else { return nil }
        return IDEModuleMenu(title: "Java") { ref in AnyView(IDEJavaCommands(ref: ref)) }
    }

    var sidebarTabs: [IDESidebarTabDescriptor] {
        [
            IDESidebarTabDescriptor(
                tab: .breakpoints, title: "Breakpoints", systemImage: "circle.fill",
                order: IDESidebarTabs.Order.breakpoints,
                // The breakpoint glyph is a dot: at the size of the other icons it reads as a blob.
                iconSize: 8, iconColor: IDEAppearance.ColorToken.error, tint: .red,
                badge: { $0.breakpoints.count },
                content: { _ in AnyView(IDEBreakpointsPanel()) }
            )
        ]
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
                .disabled(!(workspace?.gradle.isActive ?? false))
            Button("Show Gradle Dependency Diagram") { workspace?.showGradleDependencyDiagram() }
                .disabled(!(workspace?.gradle.isActive ?? false))
        }
        Divider()
        Button("Optimize Imports", action: { workspace?.optimizeImports() })
        Divider()
        Menu("Project JDK") {
            IDEJDKMenuFromRef(ref: ref)
        }
        Button("Build Project", systemImage: "hammer", action: { workspace?.buildGradleProject() })
            .disabled(!(workspace?.gradle.isActive ?? false))
        Button("Reload Gradle Project", action: { workspace?.reloadProject() })
            .disabled(!(workspace?.gradle.isActive ?? false))
        Button("Show Gradle Output", action: { workspace?.showGradleOutput() })
            .disabled(workspace?.gradle.console.lines.isEmpty ?? true)
    }
}

extension IDESidebarTab {
    static let breakpoints = IDESidebarTab(rawValue: "breakpoints")
}

extension IDEBottomPanelTab {
    /// The consoles of programs started with Run.
    static let run = IDEBottomPanelTab("run")
    /// The supertype/subtype tree of the type last asked for with ⌃H.
    static let typeHierarchy = IDEBottomPanelTab("typeHierarchy")
    /// The results of the last test run.
    static let testResults = IDEBottomPanelTab("testResults")
    /// Debugger call stack and variables.
    static let debug = IDEBottomPanelTab("debug")
    /// Callers and callees of the method last asked for.
    static let callHierarchy = IDEBottomPanelTab("callHierarchy")
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
