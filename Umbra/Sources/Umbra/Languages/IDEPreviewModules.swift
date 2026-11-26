import Penumbra
import SwiftUI

/// Markdown, Mermaid, JSON and CSV in Umbra's chrome: the preview that covers the editor or
/// sits alongside it (a rendered page, a diagram of the value, a table), its toolbar buttons
/// and View menu items, and for Markdown the agent run and the PDF export. The previews
/// themselves live in the editor pane (`IDEEditorPaneHost`), which toggles the one that fits
/// the file's language; the intelligence is the `umbra.markdown-mentions` and `umbra.json`
/// language services, and the text tools are language-neutral (`IDETextTransforms`), so these
/// modules are chrome only.
struct IDEMarkdownModule: IDELanguageModule {
    static let id = "markdown"
    var id: String { Self.id }

    /// Markdown prose and Mermaid diagrams share the rendered-page preview.
    private func previewTitle(for workspace: IDEWorkspace) -> String {
        workspace.statusLanguage == "mermaid" ? "Mermaid Preview" : "Markdown Preview"
    }

    private func applies(_ workspace: IDEWorkspace) -> Bool {
        workspace.statusLanguage == "markdown" || workspace.statusLanguage == "mermaid"
    }

    func toolbarItems(for workspace: IDEWorkspace) -> [IDEToolbarItem] {
        guard applies(workspace) else { return [] }
        let isMermaid = workspace.statusLanguage == "mermaid"
        var items: [IDEToolbarItem] = []
        if workspace.canRunMarkdownWithAgent {
            items.append(.button(
                id: "markdown.runWithAgent", order: IDEToolbarItem.Order.agentRun, systemImage: "sparkles",
                help: "Run with Agent (selection or whole file)", tint: IDEAppearance.ColorToken.accent,
                action: { [weak workspace] in workspace?.runActiveMarkdownWithAgent() }
            ))
        }
        if workspace.isMarkdownPreviewVisible {
            items.append(.button(
                id: "markdown.exportPDF", order: IDEToolbarItem.Order.exportPreview, systemImage: "square.and.arrow.down",
                help: isMermaid ? "Export Mermaid Preview to PDF" : "Export Markdown Preview to PDF",
                action: { [weak workspace] in workspace?.exportMarkdownPreviewToPDF() }
            ))
        }
        items.append(.previewToggle(
            id: "markdown.preview", isVisible: workspace.isMarkdownPreviewVisible,
            help: isMermaid ? "Toggle Mermaid Preview" : "Toggle Markdown Preview", workspace: workspace
        ))
        return items
    }

    func viewMenuItems(for workspace: IDEWorkspace) -> [IDEViewMenuContribution] {
        // Run Markdown with Agent has always been in the menu, disabled while another kind of file is open.
        var items = [IDEViewMenuContribution(id: "markdown.runWithAgent") { ref in AnyView(IDEMarkdownRunWithAgentMenuItem(ref: ref)) }]
        if applies(workspace) {
            items.append(.previewMenuItem(id: "markdown.preview", title: previewTitle(for: workspace), systemImage: "doc.richtext"))
            items.append(IDEViewMenuContribution(id: "markdown.previewSideBySide") { ref in
                AnyView(IDESideBySidePreviewMenuItem(ref: ref))
            })
        }
        return items
    }
}

/// `.json` files: the diagram of the value.
struct IDEJSONModule: IDELanguageModule {
    static let id = "json"
    var id: String { Self.id }

    func toolbarItems(for workspace: IDEWorkspace) -> [IDEToolbarItem] {
        guard workspace.statusLanguage == "json" else { return [] }
        return [.previewToggle(
            id: "json.diagram", isVisible: workspace.isJSONDiagramVisible, help: "Toggle JSON Diagram", workspace: workspace
        )]
    }

    func viewMenuItems(for workspace: IDEWorkspace) -> [IDEViewMenuContribution] {
        guard workspace.statusLanguage == "json" else { return [] }
        return [.previewMenuItem(id: "json.diagram", title: "JSON Diagram", systemImage: "curlybraces")]
    }
}

/// `.csv`, `.tsv` and `.tab` files: the table.
struct IDECSVModule: IDELanguageModule {
    static let id = "csv"
    var id: String { Self.id }

    private func applies(_ workspace: IDEWorkspace) -> Bool {
        workspace.statusLanguage == "csv" || workspace.statusLanguage == "tsv"
    }

    func toolbarItems(for workspace: IDEWorkspace) -> [IDEToolbarItem] {
        guard applies(workspace) else { return [] }
        return [.previewToggle(
            id: "csv.table", isVisible: workspace.isCSVTableVisible, help: "Toggle CSV Table", workspace: workspace
        )]
    }

    func viewMenuItems(for workspace: IDEWorkspace) -> [IDEViewMenuContribution] {
        guard applies(workspace) else { return [] }
        return [.previewMenuItem(id: "csv.table", title: "CSV Table", systemImage: "tablecells")]
    }
}

extension IDEToolbarItem {
    /// The play / stop button that shows or hides the active file's preview.
    @MainActor
    static func previewToggle(id: String, isVisible: Bool, help: String, workspace: IDEWorkspace) -> IDEToolbarItem {
        .button(
            id: id, order: Order.preview, systemImage: isVisible ? "stop.fill" : "play.fill", help: help, isActive: isVisible,
            action: { [weak workspace] in workspace?.toggleMarkdownPreview() }
        )
    }
}

extension IDEViewMenuContribution {
    /// The View menu item that shows or hides the active file's preview (⌘B in the Sublime keymap).
    static func previewMenuItem(id: String, title: String, systemImage: String) -> IDEViewMenuContribution {
        IDEViewMenuContribution(id: id) { ref in AnyView(IDEPreviewMenuItem(ref: ref, title: title, systemImage: systemImage)) }
    }
}

private struct IDEPreviewMenuItem: View {
    let ref: IDEWorkspaceRef
    let title: String
    let systemImage: String

    /// Resolved when read, never stored: menu actions run long after this view was built, and a
    /// stored workspace would stay alive with them after its window closed.
    private var workspace: IDEWorkspace? { ref.workspace }

    private var preset: KeymapPreset { IDEPreferences.shared.keymapPreset }

    var body: some View {
        Button(title, systemImage: systemImage, action: { workspace?.toggleMarkdownPreview() })
            .menuShortcut(.markdownPreview, in: preset)
    }
}

/// View ▸ Preview Side by Side: the rendered page next to the editor, updating live while it
/// stays editable. A visible cover preview switches over; an alongside preview switches back.
private struct IDESideBySidePreviewMenuItem: View {
    let ref: IDEWorkspaceRef

    private var workspace: IDEWorkspace? { ref.workspace }

    var body: some View {
        Button(
            "Preview Side by Side",
            systemImage: "rectangle.split.2x1",
            action: { workspace?.toggleMarkdownPreviewSideBySide() }
        )
    }
}

private struct IDEMarkdownRunWithAgentMenuItem: View {
    let ref: IDEWorkspaceRef

    private var workspace: IDEWorkspace? { ref.workspace }

    private var preset: KeymapPreset { IDEPreferences.shared.keymapPreset }

    var body: some View {
        Button("Run Markdown with Agent", systemImage: "sparkles", action: { workspace?.runActiveMarkdownWithAgent() })
            .menuShortcut(.runMarkdownWithAgent, in: preset)
            .disabled(!(workspace?.canRunMarkdownWithAgent ?? false))
    }
}
