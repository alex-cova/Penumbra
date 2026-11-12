import SwiftUI

/// The window's titlebar row, drawn on the window frame above the floating panels. Leading: the
/// traffic-light gutter (`Spacing.trafficLightsInset`, reserved only here), the left / bottom /
/// right panel toggles. Center: the project name and git branch. Trailing: document actions
/// (build, run, preview) and the global ones (Go to File, Actions, Settings). The two sides share
/// the width equally so the title stays centered in the window. The path-and-symbol breadcrumb
/// lives in the status bar.
struct IDEToolbarPanel: View {
    @Environment(IDEWorkspace.self) private var workspace

    var body: some View {
        let _ = IDEBodyDiagnostics.note("IDEToolbarPanel")
        if workspace.isAIMode {
            IDEAIToolbarRow()
        } else {
            IDEToolbarEditorRow()
        }
    }
}

#Preview {
    IDEToolbarPanel()
        .environment({
            let workspace = IDEWorkspace()
            let paneID = UUID()
            workspace.tabsByPane = [
                paneID: [
                    IDETabRow(id: UUID(), title: "Editor.swift", isDirty: true, isSelected: true)
                ]
            ]
            return workspace
        }())
        .frame(width: 720, height: IDEAppearance.Spacing.titlebarMinHeight)
        .preferredColorScheme(IDEAppearance.preferredColorScheme)
}
