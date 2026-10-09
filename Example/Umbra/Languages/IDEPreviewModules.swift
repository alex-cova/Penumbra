import Penumbra
import SwiftUI

/// Markdown, JSON and CSV in Umbra's chrome: the preview that covers the editor (a rendered page, a
/// diagram of the value, a table), its toolbar button and View menu item, and for Markdown the
/// agent run and the PDF export. The previews themselves live in the editor pane
/// (`IDEEditorPaneHost`), which toggles the one that fits the file's language; the intelligence is
/// the `umbra.markdown-mentions` and `umbra.json` language services, and the text tools are
/// language-neutral (`IDETextTransforms`), so these modules are chrome only.
struct IDEMarkdownModule: IDELanguageModule {
    static let id = "markdown"
    var id: String { Self.id }

    func toolbarItems(for workspace: IDEWorkspace) -> [IDEToolbarItem] {
        guard workspace.statusLanguage == "markdown" else { return [] }
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
                help: "Export Markdown Preview to PDF",
                action: { [weak workspace] in workspace?.exportMarkdownPreviewToPDF() }
            ))
        }
        items.append(.previewToggle(
            id: "markdown.preview", isVisible: workspace.isMarkdownPreviewVisible, help: "Toggle Markdown Preview", workspace: workspace
        ))
        return items
    }

    func viewMenuItems(for workspace: IDEWorkspace) -> [IDEViewMenuContribution] {
        // Run Markdown with Agent has always been in the menu, disabled while another kind of file is open.
        var items = [IDEViewMenuContribution(id: "markdown.runWithAgent") { ref in AnyView(IDEMarkdownRunWithAgentMenuItem(ref: ref)) }]
        if workspace.statusLanguage == "markdown" {
            items.append(.previewMenuItem(id: "markdown.preview", title: "Markdown Preview", systemImage: "doc.richtext"))
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
