import EditorIntelligence
import Foundation
import Penumbra
import SwiftUI
import SwiftIntelligence

/// Swift in Umbra's chrome: palette commands, Run and the gutter's play buttons through SwiftPM,
/// the symbol-palette source, and the class and target diagrams. A Swift menu shows while a Swift file is selected.
/// The index and the providers stay on `IDESwiftSupport`; the package is `IDESwiftPMProjectSystem`.
struct IDESwiftModule: IDELanguageModule {
    static let id = "swift"
    var id: String { Self.id }

    var languageServers: [IDELanguageServerDefinition] { [IDESourceKitServer.definition()] }

    private static let classDiagramPrefix = "swift:classes:"

    func commands(for workspace: IDEWorkspace) -> [EditorCommand] {
        [
            EditorCommand(
                id: "swift.showClassDiagram", title: "Swift: Show Class Diagram", group: "Swift",
                action: { [weak workspace] in workspace?.showSwiftClassDiagram() }
            ),
            EditorCommand(
                id: "swift.inspectCode", title: "Swift: Inspect Code…", group: "Swift",
                action: { [weak workspace] in workspace?.presentInspectCode(language: .swift) }
            ),
            EditorCommand(
                id: "swift.runInspectionByName", title: "Swift: Run Inspection by Name…", group: "Swift",
                action: { [weak workspace] in workspace?.presentRunInspectionByName(language: .swift) }
            ),
            EditorCommand(
                id: "swift.introduceVariable", title: "Swift: Introduce Variable…", group: "Swift",
                action: { [weak workspace] in workspace?.performRefactoring(.extractVariable) }
            ),
            EditorCommand(
                id: "swift.inlineVariable", title: "Swift: Inline Variable", group: "Swift",
                action: { [weak workspace] in workspace?.performRefactoring(.inlineVariable) }
            ),
            EditorCommand(
                id: "swift.changeSignature", title: "Swift: Change Function Signature…", group: "Swift",
                action: { [weak workspace] in workspace?.performRefactoring(.changeSignature) }
            ),
            EditorCommand(
                id: "swift.extractMethod", title: "Swift: Extract Method…", group: "Swift",
                action: { [weak workspace] in workspace?.performRefactoring(.extractMethod) }
            ),
            EditorCommand(
                id: "swift.convertIfGuard", title: "Swift: Convert Between if and guard", group: "Swift",
                action: { [weak workspace] in workspace?.performRefactoring(.convertIfGuard) }
            ),
            EditorCommand(
                id: "swift.moveToExtension", title: "Swift: Move to Extension", group: "Swift",
                action: { [weak workspace] in workspace?.performRefactoring(.moveToExtension) }
            ),
            EditorCommand(
                id: "swift.addExplicitType", title: "Swift: Add Explicit Type", group: "Swift",
                action: { [weak workspace] in workspace?.performRefactoring(.addExplicitType) }
            ),
            EditorCommand(
                id: "swift.runWithCoverage", title: "Swift: Run Tests with Coverage", group: "Swift",
                action: { [weak workspace] in workspace?.runTestsInstrumented(.coverage) }
            ),
            EditorCommand(
                id: "swift.profile", title: "Swift: Profile (Time Profiler)", group: "Swift",
                action: { [weak workspace] in workspace?.runInstrumented(.profile) }
            ),
            EditorCommand(
                id: "swift.toggleSwiftUIPreview", title: "Swift: Toggle SwiftUI Preview", group: "Swift",
                action: { [weak workspace] in workspace?.toggleSwiftUIPreview() }
            ),
            EditorCommand(
                id: "swift.refreshSwiftUIPreview", title: "Swift: Refresh SwiftUI Preview", group: "Swift",
                action: { [weak workspace] in
                    guard let workspace, workspace.isSwiftUIPreviewVisible else { return }
                    workspace.swiftUIPreview?.refresh()
                }
            ),
            EditorCommand(
                id: "swiftpm.showTargets", title: "SwiftPM: Show Targets", group: "Swift",
                action: { [weak workspace] in workspace?.showSwiftPMTargets() }
            ),
            EditorCommand(
                id: "swiftpm.build", title: "SwiftPM: Build", group: "Swift",
                action: { [weak workspace] in workspace?.swiftPM.build() }
            ),
            EditorCommand(
                id: "swiftpm.test", title: "SwiftPM: Run Tests", group: "Swift",
                action: { [weak workspace] in workspace?.swiftPM.runTasks(["test"]) }
            ),
            EditorCommand(
                id: "swiftpm.resolve", title: "SwiftPM: Resolve Packages", group: "Swift",
                action: { [weak workspace] in workspace?.swiftPM.runTasks(["resolve"]) }
            )
        ]
    }

    func toolbarItems(for workspace: IDEWorkspace) -> [IDEToolbarItem] {
        guard workspace.statusLanguage == "swift", workspace.canPreviewSwiftUI || workspace.isSwiftUIPreviewVisible else { return [] }
        return [.previewToggle(
            id: "swift.preview", isVisible: workspace.isSwiftUIPreviewVisible, help: "Toggle SwiftUI Preview", workspace: workspace
        )]
    }

    func viewMenuItems(for workspace: IDEWorkspace) -> [IDEViewMenuContribution] {
        guard workspace.statusLanguage == "swift", workspace.canPreviewSwiftUI || workspace.isSwiftUIPreviewVisible else { return [] }
        return [.previewMenuItem(id: "swift.preview", title: "SwiftUI Preview", systemImage: "swift")]
    }

    /// The Swift menu exists while a Swift file is the selected tab.
    func menu(for workspace: IDEWorkspace) -> IDEModuleMenu? {
        guard workspace.statusLanguage == "swift" else { return nil }
        return IDEModuleMenu(title: "Swift") { ref in AnyView(IDESwiftCommands(ref: ref)) }
    }

    func makeRunProvider(for workspace: IDEWorkspace) -> (any IDERunProvider)? {
        // Xcode first: an Xcode project in the folder runs its tests through the Xcode provider;
        // otherwise Swift files run through SwiftPM. The check reads the folder, so it holds at
        // window creation without waiting for the project sync.
        if let root = workspace.project.rootURL,
           IDEXcodeProjectModel.findProject(in: root) != nil {
            return IDEXcodeRunProvider(xcode: workspace.xcode, workspace: workspace)
        }
        return IDESwiftRunProvider(swiftPM: workspace.swiftPM, workspace: workspace)
    }

    func symbolPaletteSources(for workspace: IDEWorkspace) -> [any SearchEverywhereProvider] {
        let native = IDESwiftPaletteSource(
            index: workspace.swiftSupport.index,
            onOpen: { [weak workspace] url, range, inRightSplit in
                workspace?.openIndexedDeclaration(in: url, utf8NameRange: range, inRightSplit: inRightSplit)
            }
        )
        // SourceKit-LSP's workspace symbols while it is connected and has an answer, else the native index.
        return [IDEServerSymbolSource(
            connection: workspace.sourceKitConnection,
            fallback: native,
            onOpen: { [weak workspace] url, line, character, inRightSplit in
                workspace?.openServerSymbol(in: url, line: line, character: character, inRightSplit: inRightSplit)
            }
        )]
    }

    func loadDiagram(
        _ request: IDEDiagramRequest, settings: IDEDiagramSettings, workspace: IDEWorkspace
    ) async -> IDEDiagramLoad? {
        guard request.id.hasPrefix(Self.classDiagramPrefix) else { return nil }
        let path = String(request.id.dropFirst(Self.classDiagramPrefix.count))
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let text = workspace.openBufferText(for: url) ?? (try? String(contentsOf: url, encoding: .utf8))
        guard let text, let parsed = SwiftAnalysis.parse(text) else {
            return IDEDiagramLoad(document: .empty(title: request.title), failure: "This Swift file could not be read.")
        }
        let document = IDESwiftDiagram.document(model: parsed.model, fileURL: url, title: request.title, settings: settings)
        let emptyMessage = document.nodes.isEmpty ? "This file declares no types." : ""
        return IDEDiagramLoad(document: document, emptyMessage: emptyMessage)
    }
}

extension IDEWorkspace {
    fileprivate func showSwiftClassDiagram() {
        guard let document = workbench.activePane.selectedDocument, document.languageIdentifier == "swift" else {
            notifications.post("This file is not Swift.", category: .general)
            return
        }
        guard let url = document.url else {
            notifications.post("Save the file before showing its class diagram.", category: .general)
            return
        }
        let standardized = url.standardizedFileURL
        openDiagram(IDEDiagramRequest(
            id: "swift:classes:" + standardized.path,
            title: "Classes: \(standardized.lastPathComponent)",
            symbolName: "square.stack.3d.up",
            presentation: .classes
        ))
    }

    fileprivate func showSwiftPMTargets() {
        guard swiftPM.isActive else {
            notifications.post("This folder has no Package.swift.", category: .general)
            return
        }
        openDiagram(IDESwiftPMProjectSystem.dependenciesDiagramRequest())
    }
}

/// The Swift menu: the refactorings, Inspect Code, and Run with Coverage and Profile for a SwiftPM package.
private struct IDESwiftCommands: View {
    let ref: IDEWorkspaceRef

    /// Resolved when read, never stored: menu actions run long after this view was built, and a stored
    /// workspace would stay alive with them after its window closed.
    private var workspace: IDEWorkspace? { ref.workspace }

    private var preset: KeymapPreset { IDEPreferences.shared.keymapPreset }

    /// The Xcode test scheme, when the window runs Swift through Xcode.
    @State private var schemes: [String] = []

    private var xcodeProvider: IDEXcodeRunProvider? {
        workspace?.runProviders.providers.first { $0 is IDEXcodeRunProvider } as? IDEXcodeRunProvider
    }

    var body: some View {
        Menu("Refactor") {
            Button("Introduce Variable…", action: { workspace?.performRefactoring(.extractVariable) })
                .menuShortcut(.extractVariable, in: preset)
            Button("Inline Variable", action: { workspace?.performRefactoring(.inlineVariable) })
                .menuShortcut(.inlineVariable, in: preset)
            Button("Change Function Signature…", action: { workspace?.performRefactoring(.changeSignature) })
            Button("Extract Method…", action: { workspace?.performRefactoring(.extractMethod) })
                .menuShortcut(.extractMethod, in: preset)
            Divider()
            Button("Convert Between if and guard", action: { workspace?.performRefactoring(.convertIfGuard) })
            Button("Write Optional Binding Out or Shorten It", action: { workspace?.performRefactoring(.optionalBindingShorthand) })
            Button("Add Explicit Type", action: { workspace?.performRefactoring(.addExplicitType) })
            Button("Move to Extension", action: { workspace?.performRefactoring(.moveToExtension) })
        }
        Button("Inspect Code…", action: { workspace?.presentInspectCode(language: .swift) })
            .menuShortcut(.inspectCode, in: preset)
        Button("Run Inspection by Name…", action: { workspace?.presentRunInspectionByName(language: .swift) })
            .menuShortcut(.runInspectionByName, in: preset)
        if let provider = xcodeProvider {
            Menu("Scheme: \(provider.selectedScheme ?? schemes.first ?? "…")") {
                ForEach(schemes, id: \.self) { scheme in
                    Toggle(scheme, isOn: Binding(
                        get: { provider.selectedScheme ?? schemes.first == scheme },
                        set: { _ in provider.selectedScheme = scheme }
                    ))
                }
            }
            .task { schemes = await provider.schemes() }
        }
        Divider()
        Button("Run Tests with Coverage", action: { workspace?.runTestsInstrumented(.coverage) })
        Button("Profile (Time Profiler)", action: { workspace?.runInstrumented(.profile) })
        Divider()
        Button("Show Class Diagram", action: { workspace?.showSwiftClassDiagram() })
        Button("Show SwiftPM Targets", action: { workspace?.showSwiftPMTargets() })
    }
}
