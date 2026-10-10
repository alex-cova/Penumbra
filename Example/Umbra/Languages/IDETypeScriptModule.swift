import Foundation
import Penumbra

/// TypeScript in Umbra's chrome: palette commands, the symbol-palette source, the one-file class
/// diagram, and Run for TypeScript and JavaScript through the npm project. There is no menu-bar menu.
/// The index and the providers stay on `IDETypeScriptSupport`.
struct IDETypeScriptModule: IDELanguageModule {
    static let id = "typescript"
    var id: String { Self.id }

    private static let classDiagramPrefix = "typescript:classes:"

    func commands(for workspace: IDEWorkspace) -> [EditorCommand] {
        [
            EditorCommand(
                id: "typescript.showClassDiagram", title: "TypeScript: Show Class Diagram", group: "TypeScript",
                action: { [weak workspace] in workspace?.showTypeScriptClassDiagram() }
            ),
            EditorCommand(
                id: "npm.showDependencies", title: "npm: Show Dependencies", group: "TypeScript",
                action: { [weak workspace] in workspace?.showNpmDependencies() }
            )
        ]
    }

    func makeRunProvider(for workspace: IDEWorkspace) -> (any IDERunProvider)? {
        IDENpmRunProvider(npm: workspace.npm, workspace: workspace)
    }

    func symbolPaletteSources(for workspace: IDEWorkspace) -> [any SearchEverywhereProvider] {
        [IDETypeScriptPaletteSource(
            index: workspace.typescriptSupport.index,
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
        guard let text, let parsed = TypeScriptAnalysis.parse(text) else {
            return IDEDiagramLoad(document: .empty(title: request.title), failure: "This TypeScript file could not be read.")
        }
        let document = IDETypeScriptDiagram.document(model: parsed.model, fileURL: url, title: request.title, settings: settings)
        let emptyMessage = document.nodes.isEmpty ? "This file declares no types." : ""
        return IDEDiagramLoad(document: document, emptyMessage: emptyMessage)
    }
}

extension IDEWorkspace {
    fileprivate func showTypeScriptClassDiagram() {
        guard let document = workbench.activePane.selectedDocument, document.languageIdentifier == "typescript" else {
            notifications.post("This file is not TypeScript.", category: .general)
            return
        }
        guard let url = document.url else {
            notifications.post("Save the file before showing its class diagram.", category: .general)
            return
        }
        let standardized = url.standardizedFileURL
        openDiagram(IDEDiagramRequest(
            id: "typescript:classes:" + standardized.path,
            title: "Classes: \(standardized.lastPathComponent)",
            symbolName: "square.stack.3d.up",
            presentation: .classes
        ))
    }

    fileprivate func showNpmDependencies() {
        guard npm.isActive else {
            notifications.post("This folder has no package.json.", category: .general)
            return
        }
        openDiagram(IDENpmProjectSystem.dependenciesDiagramRequest())
    }
}
