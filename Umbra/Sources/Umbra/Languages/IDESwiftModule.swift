import Foundation
import Penumbra
import SwiftIntelligence

/// Swift in Umbra's chrome: palette commands, Run and the gutter's play buttons through SwiftPM,
/// the symbol-palette source, and the class and target diagrams. There is no menu-bar menu.
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

    func makeRunProvider(for workspace: IDEWorkspace) -> (any IDERunProvider)? {
        IDESwiftRunProvider(swiftPM: workspace.swiftPM, workspace: workspace)
    }

    func symbolPaletteSources(for workspace: IDEWorkspace) -> [any SearchEverywhereProvider] {
        [IDESwiftPaletteSource(
            index: workspace.swiftSupport.index,
            onOpen: { [weak workspace] url, range, inRightSplit in
                workspace?.openIndexedDeclaration(in: url, utf8NameRange: range, inRightSplit: inRightSplit)
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
