import DatabaseKit
import Penumbra
import SwiftUI

/// MySQL, PostgreSQL and MongoDB: the Database sidebar, query consoles and the results tab.
struct IDEDatabaseModule: IDELanguageModule {
    static let id = "database"
    var id: String { Self.id }

    func commands(for workspace: IDEWorkspace) -> [EditorCommand] {
        [
            EditorCommand(
                id: "app.database.newDataSource", title: "Database: New Data Source", group: "Database",
                action: { [weak workspace] in workspace?.showNewDatabaseConnection() }
            ),
            EditorCommand(
                id: "app.database.newQuery", title: "Database: New Query Console", group: "Database",
                action: { [weak workspace] in workspace?.openDatabaseQueryConsole() }
            ),
            EditorCommand(
                id: "app.database.execute", title: "Database: Execute Statement or Selection", group: "Database",
                action: { [weak workspace] in workspace?.executeDatabaseConsole() }
            ),
            EditorCommand(
                id: "app.database.executeAll", title: "Database: Execute All", group: "Database",
                action: { [weak workspace] in workspace?.executeDatabaseConsole(all: true) }
            ),
            EditorCommand(
                id: "app.database.cancel", title: "Database: Cancel Statement", group: "Database",
                action: { [weak workspace] in workspace?.cancelDatabaseStatement() }
            ),
            EditorCommand(
                id: "app.database.openSQLite", title: "Database: Open SQLite File…", group: "Database",
                action: { [weak workspace] in workspace?.openSQLiteFile() }
            ),
            EditorCommand(
                id: "app.database.newSQLite", title: "Database: New SQLite Database…", group: "Database",
                action: { [weak workspace] in workspace?.newSQLiteDatabase() }
            )
        ]
    }

    func toolWindows(for workspace: IDEWorkspace) -> [IDEToolWindow] {
        guard workspace.databaseSupport.showsResultsTab else { return [] }
        return [workspace.bottomToolWindow(
            .databaseResults, "tablecells", "Query Results", nil, .blue, .trailingBottom,
            order: IDEToolWindow.Order.databaseResults
        )]
    }

    func bottomTabs(for workspace: IDEWorkspace) -> [IDEBottomTabContribution] {
        guard workspace.databaseSupport.showsResultsTab else { return [] }
        return [IDEBottomTabContribution(
            tab: .databaseResults,
            order: IDEBottomPanelTab.Order.databaseResults,
            item: { workspace in
                AnyView(IDEDatabaseResultsTabItem(
                    isSelected: workspace.isBottomTabSelected(.databaseResults),
                    isRunning: workspace.databaseSupport.isRunning,
                    onSelect: { [weak workspace] in workspace?.showBottomTab(.databaseResults) }
                ))
            },
            content: { workspace in
                AnyView(IDEDatabaseResultView(
                    support: workspace.databaseSupport,
                    consoleID: workspace.isDatabaseConsoleActive ? workspace.workbench.activePane.selectedDocument?.id : nil
                ))
            }
        )]
    }

    var sidebarTabs: [IDESidebarTabDescriptor] {
        [
            IDESidebarTabDescriptor(
                tab: .database, title: "Database", systemImage: "cylinder.split.1x2",
                order: IDESidebarTabs.Order.database, tint: .blue,
                content: { _ in AnyView(IDEDatabaseSidebar()) }
            )
        ]
    }

    func menu(for workspace: IDEWorkspace) -> IDEModuleMenu? {
        IDEModuleMenu(title: "Database") { ref in AnyView(IDEDatabaseCommands(ref: ref)) }
    }

    func loadDiagram(
        _ request: IDEDiagramRequest, settings _: IDEDiagramSettings, workspace: IDEWorkspace
    ) async -> IDEDiagramLoad? {
        guard let connectionID = IDEDatabaseDiagram.connectionID(from: request) else { return nil }
        return await IDEDatabaseDiagram.load(connectionID: connectionID, workspace: workspace)
    }

    func toolbarItems(for workspace: IDEWorkspace) -> [IDEToolbarItem] {
        // While a statement runs, the play button becomes a stop button for that statement.
        if workspace.databaseSupport.isRunning {
            return [.button(
                id: "database.cancel", order: IDEToolbarItem.Order.send + 1, systemImage: "stop.fill",
                help: "Cancel Statement", tint: IDEAppearance.ColorToken.error,
                action: { [weak workspace] in workspace?.cancelDatabaseStatement() }
            )]
        }
        guard workspace.isDatabaseConsoleActive else { return [] }
        return [.button(
            id: "database.execute", order: IDEToolbarItem.Order.send + 1, systemImage: "play.fill",
            help: "Execute Statement or Selection", tint: IDEAppearance.ColorToken.run,
            action: { [weak workspace] in workspace?.executeDatabaseConsole() }
        )]
    }
}

extension IDEBottomPanelTab {
    /// The page of rows from the last database statement.
    static let databaseResults = IDEBottomPanelTab("databaseResults")
}

extension IDESidebarTab {
    static let database = IDESidebarTab(rawValue: "database")
}

private struct IDEDatabaseCommands: View {
    let ref: IDEWorkspaceRef

    private var workspace: IDEWorkspace? { ref.workspace }

    private var preset: KeymapPreset { IDEPreferences.shared.keymapPreset }

    var body: some View {
        Button("New Data Source…", action: { workspace?.showNewDatabaseConnection() })
        Button("Open SQLite File…", action: { workspace?.openSQLiteFile() })
        Button("New SQLite Database…", action: { workspace?.newSQLiteDatabase() })
        Button("New Query Console", action: { workspace?.openDatabaseQueryConsole() })
        Button("Execute Statement or Selection", action: { workspace?.executeDatabaseConsole() })
            .menuShortcut(.executeDatabaseStatement, in: preset)
            .disabled(!(workspace?.isDatabaseConsoleActive ?? false) || (workspace?.databaseSupport.isRunning ?? false))
        Button("Execute All", action: { workspace?.executeDatabaseConsole(all: true) })
            .menuShortcut(.executeAllDatabaseStatements, in: preset)
            .disabled(!(workspace?.isDatabaseConsoleActive ?? false) || (workspace?.databaseSupport.isRunning ?? false))
        Button("Cancel Statement", action: { workspace?.cancelDatabaseStatement() })
            .menuShortcut(.cancelDatabaseStatement, in: preset)
            .disabled(!(workspace?.databaseSupport.isRunning ?? false))
        Button("Show Query Results", action: { workspace?.showDatabaseResults() })
    }
}

private struct IDEDatabaseResultsTabItem: View {
    let isSelected: Bool
    let isRunning: Bool
    let onSelect: () -> Void

    var body: some View {
        IDEChromeTabItem(title: "Query Results", isSelected: isSelected, onSelect: onSelect) {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
            }
        } trailing: {
            EmptyView()
        }
    }
}
