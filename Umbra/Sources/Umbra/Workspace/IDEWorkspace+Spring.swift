import AppKit
import EditorIntelligence
import Foundation
import SpringIntelligence

/// What the Spring tool window, the editor gutter and the diagrams ask of the window: open a place, run Find Usages for a bean,
/// open a graph, reveal a bean.
extension IDEWorkspace {
    /// Loads (or keeps) the tool window's model for the current project.
    func refreshSpring() {
        springStore.refresh(indexer: javaSupport.springIndexer)
        Task { await javaSupport.mirrorSpringModules() }
    }

    /// Whether the Spring tool window is offered: a Spring module was detected in the build model.
    var hasSpringProject: Bool { javaSupport.hasSpring }

    /// Opens the source at a Spring location (a bean, an injection point, an import, a diagnostic).
    func openSpringLocation(_ location: SpringSourceLocation, title: String) {
        guard let target = location.editorLocation(displayName: title) else {
            notifications.post("Could not read \(location.url.lastPathComponent).", category: .general)
            return
        }
        _ = openNavigationLocation(target)
    }

    func openSpringBean(_ id: SpringBeanID, in store: IDESpringStore) {
        guard let bean = store.currentContext?.context.model.bean(id) else { return }
        openSpringLocation(bean.location, title: bean.name)
    }

    func openSpringConfigFile(_ url: URL) {
        Task { await openDocument(from: url) }
    }

    /// Find Usages of the bean's declaration through the language's own navigation, which adds the bean's injection points.
    func findSpringBeanUsages(_ id: SpringBeanID, in store: IDESpringStore) {
        guard let bean = store.currentContext?.context.model.bean(id) else { return }
        openSpringLocation(bean.location, title: bean.name)
        // The editor has moved to the declaration; Find Usages acts on the caret there.
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = self.host(for: self.workbench.activePane.id).intelligenceController?.navigate(kind: .references)
        }
    }

    /// Opens the bean dependency graph of an application, optionally around one bean.
    func openSpringBeanGraph(focus: SpringBeanID?, direction: SpringBeanGraphOptions.Direction, store: IDESpringStore, contextID: String? = nil) {
        guard let contextID = contextID ?? store.currentContext?.id else { return }
        openDiagram(IDESpringDiagramRequest.beanGraph(contextID: contextID, focus: focus, direction: direction, depth: store.graphOptions.depth))
    }

    func openSpringContextGraph(contextID: String) {
        openDiagram(IDESpringDiagramRequest.contextGraph(contextID: contextID))
    }

    func copySpringText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Opens a new `.http` buffer with a request for the endpoint. Nothing is sent: the user reads it, fills in the sample values
    /// and runs it. The base URL comes from `server.port` when configuration names one, else it is an explicit placeholder.
    func generateSpringHTTPRequest(_ endpoint: SpringEndpoint, config: SpringConfigModel?) {
        let base = SpringHTTPRequest.baseURL(config: config, stack: endpoint.stack)
        openUntitled(displayName: SpringHTTPRequest.suggestedName(for: endpoint),
                     text: SpringHTTPRequest.render(endpoint, base: base, config: config), languageIdentifier: "http")
    }

    /// Find Usages of the handler: requests in `.http` files and tests that the route matches, through the language's navigation.
    func findSpringEndpointReferences(_ endpoint: SpringEndpoint) {
        openSpringLocation(endpoint.handlerLocation, title: endpoint.handlerTitle)
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = self.host(for: self.workbench.activePane.id).intelligenceController?.navigate(kind: .references)
        }
    }

    /// What Return does in the Endpoints list: open the selected endpoint's handler.
    @discardableResult
    func openSelectedSpringEndpoint(in store: IDESpringStore) -> Bool {
        guard let endpoint = store.selectedEndpoint else { return false }
        openSpringLocation(endpoint.handlerLocation, title: endpoint.handlerTitle)
        return true
    }

    func revealSpringApplication(_ contextID: String, in store: IDESpringStore) {
        store.selectedContextID = contextID
        store.section = .applications
    }

    /// Commands a gutter marker menu issues (`SpringMarkers.Command`). Unknown ids are ignored.
    func performMarkerCommand(_ command: CodeActionCommand) {
        switch command.id {
        case SpringMarkers.Command.reveal:
            guard command.arguments.count >= 2 else { return }
            showSidebarTab(.spring)
            refreshSpring()
            springStore.reveal(bean: SpringBeanID(raw: command.arguments[1]), contextID: command.arguments[0])
        case SpringMarkers.Command.dependencyGraph:
            guard command.arguments.count >= 2 else { return }
            openDiagram(IDESpringDiagramRequest.beanGraph(contextID: command.arguments[0], focus: SpringBeanID(raw: command.arguments[1]),
                                                          direction: .both, depth: springStore.graphOptions.depth))
        case SpringMarkers.Command.revealEndpoint:
            guard command.arguments.count >= 2 else { return }
            showSidebarTab(.spring)
            refreshSpring()
            springStore.reveal(endpoint: SpringEndpointID(raw: command.arguments[1]), contextID: command.arguments[0])
        case SpringMarkers.Command.copyText:
            guard let text = command.arguments.first else { return }
            copySpringText(text)
        case SpringMarkers.Command.generateHTTPRequest:
            guard command.arguments.count >= 2 else { return }
            let store = javaSupport.springIndexer.store
            let (contextID, endpointID) = (command.arguments[0], SpringEndpointID(raw: command.arguments[1]))
            Task { @MainActor [weak self] in
                guard let endpoint = await store.endpointIndex(contextID: contextID)?.endpoint(endpointID) else { return }
                self?.generateSpringHTTPRequest(endpoint, config: await store.config())
            }
        case SpringMarkers.Command.contextGraph:
            guard let context = command.arguments.first else { return }
            openSpringContextGraph(contextID: context)
        default:
            break
        }
    }
}
