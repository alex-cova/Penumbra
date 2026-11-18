import EditorIntelligence
import Penumbra
import SwiftUI

/// Spring's contribution to the window: the Spring sidebar tab (offered only when a Spring module was detected), a few
/// commands, and the bean and context graphs. The semantic model itself lives in `SpringIntelligence`; this is presentation.
@MainActor
struct IDESpringModule: IDELanguageModule {
    let id = "spring"

    var sidebarTabs: [IDESidebarTabDescriptor] {
        [IDESidebarTabDescriptor(
            tab: .spring, title: "Spring", systemImage: "leaf", order: 45, tint: .green,
            isAvailable: { $0.hasSpringProject },
            badge: { workspace in workspace.springStore.snapshot?.contexts.reduce(0) { $0 + $1.context.model.diagnostics.filter { $0.severity == .error }.count } ?? 0 },
            onShow: { $0.refreshSpring() },
            content: { _ in AnyView(IDESpringPanel()) }
        )]
    }

    func commands(for workspace: IDEWorkspace) -> [EditorCommand] {
        guard workspace.hasSpringProject else { return [] }
        return [
            EditorCommand(id: "app.spring.show", title: "Spring: Show Tool Window", group: "Spring",
                          action: { [weak workspace] in workspace?.showSidebarTab(.spring); workspace?.refreshSpring() }),
            EditorCommand(id: "app.spring.contextGraph", title: "Spring: Show Application Context Graph", group: "Spring",
                          action: { [weak workspace] in
                              guard let workspace else { return }
                              workspace.refreshSpring()
                              if let id = workspace.springStore.currentContext?.id { workspace.openSpringContextGraph(contextID: id) }
                          }),
            EditorCommand(id: "app.spring.beanGraph", title: "Spring: Show Bean Dependency Graph", group: "Spring",
                          action: { [weak workspace] in
                              guard let workspace else { return }
                              workspace.refreshSpring()
                              workspace.openSpringBeanGraph(focus: nil, direction: .both, store: workspace.springStore)
                          }),
        ]
    }

    func loadDiagram(_ request: IDEDiagramRequest, settings: IDEDiagramSettings, workspace: IDEWorkspace) async -> IDEDiagramLoad? {
        await IDESpringDiagram.load(request, workspace: workspace)
    }
}
