import SwiftUI

struct IDEDatabaseWindowSheets: ViewModifier {
    let workspace: IDEWorkspace

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(
                get: { workspace.databaseSupport.editor },
                set: { workspace.databaseSupport.editor = $0 }
            )) { editor in
                IDEDatabaseConnectionSheet(
                    editor: editor,
                    support: workspace.databaseSupport,
                    onCancel: { workspace.databaseSupport.editor = nil }
                )
                .environment(workspace)
                .preferredColorScheme(IDEAppearance.preferredColorScheme)
            }
            .sheet(item: Binding(
                get: { workspace.databaseParameterPrompt },
                set: { workspace.databaseParameterPrompt = $0 }
            )) { prompt in
                IDEDatabaseParameterSheet(prompt: prompt)
                    .preferredColorScheme(IDEAppearance.preferredColorScheme)
            }
            .sheet(item: Binding(
                get: { workspace.databaseSupport.productionPrompt },
                set: { value in
                    if value == nil { workspace.databaseSupport.productionPrompt?.resolve(false) }
                }
            )) { prompt in
                IDEDatabaseProductionSheet(prompt: prompt)
                    .preferredColorScheme(IDEAppearance.preferredColorScheme)
            }
            .sheet(item: Binding(
                get: { workspace.databaseSchemaDraft },
                set: { workspace.databaseSchemaDraft = $0 }
            )) { draft in
                IDEDatabaseSchemaSheet(draft: draft, onOpen: workspace.openDatabaseSchemaDraft,
                                       loadSQLite: workspace.loadDatabaseSQLiteRebuild)
                    .preferredColorScheme(IDEAppearance.preferredColorScheme)
            }
    }
}
