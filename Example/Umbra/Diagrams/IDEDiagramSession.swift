import DiagramKit
import Foundation
import JavaIntelligence
import AppKit
import Observation

enum IDEDiagramLoadFailure: Error, Equatable {
    case message(String)
}

/// One diagram tab: the request that produced it, the options it is drawn with, and the DiagramKit session
/// holding the document, selection and viewport. Graphs are loaded and laid out off the main actor; a newer
/// load makes an older one's result get dropped.
@MainActor
@Observable
final class IDEDiagramSession {
    enum State: Equatable {
        case loading
        case ready
        case empty(String)
        case failed(String)
    }

    let host: DiagramSession<IDEDiagramDocument>
    private(set) var request: IDEDiagramRequest
    private(set) var state: State = .loading
    private(set) var notice: String?
    private(set) var summary = ""
    private(set) var loadedAt: Date?

    var settings: IDEDiagramSettings {
        didSet { settingsDidChange(from: oldValue) }
    }

    @ObservationIgnored var loadClassGraph: ((JavaClassGraphScope, JavaClassGraphOptions) async -> JavaClassGraph)?
    @ObservationIgnored var loadModuleGraph: (() async -> Result<GradleDependencyGraph, IDEDiagramLoadFailure>)?
    @ObservationIgnored var loadLibraryGraph: ((_ projectPath: String, _ configuration: String) async -> Result<GradleDependencyGraph, IDEDiagramLoadFailure>)?
    @ObservationIgnored var openSource: ((URL) -> Void)?
    /// Opens (or reuses) another diagram tab; the Int is the least neighbour depth it should show.
    @ObservationIgnored var openDiagram: ((IDEDiagramRequest, Int) -> Void)?
    @ObservationIgnored var invalidateCaches: (() -> Void)?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var pendingFit = true
    @ObservationIgnored private var hasViewSize = false
    @ObservationIgnored private var hasLoadedOnce = false

    init(request: IDEDiagramRequest, settings: IDEDiagramSettings = .load(), defaults: UserDefaults = .standard) {
        self.request = request
        self.settings = settings
        self.defaults = defaults
        var canvas = IDEDiagramDocument.defaultCanvas
        canvas.edgeRouting = settings.routing
        var document = IDEDiagramDocument(meta: .init(title: request.title), canvas: canvas, nodes: [], edges: [])
        document.canvas = canvas
        host = DiagramSession(document: document, routing: IDEDiagramRouting.provider)
    }

    var document: IDEDiagramDocument { host.document }
    var title: String { request.title }

    var selectedNode: IDEDiagramNode? {
        guard host.selection.count == 1, let id = host.selection.first else { return nil }
        return host.document.node(id: id)
    }

    var isLoading: Bool { state == .loading }

    func cancel() {
        generation &+= 1
        loadTask?.cancel()
        loadTask = nil
    }

    func reload() {
        generation &+= 1
        let current = generation
        loadTask?.cancel()
        state = .loading
        let request = request
        let settings = settings
        loadTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.produce(request: request, settings: settings)
            guard !Task.isCancelled, current == self.generation else { return }
            self.apply(outcome)
        }
    }

    /// Reload that also drops what the workspace cached for this diagram (the Gradle runs).
    func refresh() {
        invalidateCaches?()
        reload()
    }

    func open(_ node: IDEDiagramNode) {
        guard let url = node.fileURL else { return }
        openSource?(url)
    }

    func showDiagramAround(_ node: IDEDiagramNode) {
        openDiagram?(.classes(.types([node.key])), 1)
    }

    func showLibraries(of node: IDEDiagramNode) {
        guard node.kind == .project else { return }
        let path = String(node.key.dropFirst("project:".count))
        openDiagram?(.gradleLibraries(projectPath: path, configuration: settings.libraryConfiguration), 0)
    }

    func copyName(of node: IDEDiagramNode) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(request.isClassDiagram ? node.key : node.title, forType: .string)
    }

    func canvasSizeChanged(_ size: CGSize) {
        guard size.width > 1, size.height > 1 else { return }
        host.canvasViewSize = size
        hasViewSize = true
        if pendingFit, !host.document.nodes.isEmpty {
            pendingFit = false
            host.fitViewport()
        }
    }

    func fit() {
        host.fitViewport()
    }

    func relayout() {
        guard !host.document.nodes.isEmpty else { return }
        let frames = IDEDiagramLayoutEngine.frames(for: host.document, kind: settings.layout)
        host.applyEdit(.setNodeFrames(frames))
        host.fitViewport()
    }

    /// Re-targets the Gradle library view at another configuration without opening a new tab.
    func setLibraryConfiguration(_ configuration: String) {
        guard case let .gradleLibraries(projectPath, current) = request, current != configuration else { return }
        request = .gradleLibraries(projectPath: projectPath, configuration: configuration)
        if settings.libraryConfiguration != configuration { settings.libraryConfiguration = configuration }
        reload()
    }

    var libraryConfiguration: String? {
        if case let .gradleLibraries(_, configuration) = request { return configuration }
        return nil
    }

    private struct Outcome {
        var document: IDEDiagramDocument
        var notice: String?
        var emptyMessage: String
        var failure: String?
    }

    private func produce(request: IDEDiagramRequest, settings: IDEDiagramSettings) async -> Outcome {
        let title = request.title
        let layout = settings.layout
        let routing = settings.routing
        switch request {
        case let .classes(scope):
            guard let loadClassGraph else {
                return Outcome(document: .empty(title: title), emptyMessage: "", failure: "Class diagrams are unavailable.")
            }
            let graph = await loadClassGraph(scope, settings.classOptions)
            let document = await Task.detached(priority: .userInitiated) {
                Self.laidOut(IDEDiagramDocumentBuilder.document(from: graph, title: title), layout: layout, routing: routing)
            }.value
            var notice: String?
            if graph.truncated {
                notice = "Showing \(graph.nodes.count) types; \(graph.omittedCount) more omitted. Narrow the scope to see them."
            }
            return Outcome(
                document: document,
                notice: notice,
                emptyMessage: "No Java types found for this scope. If the project was just opened, wait for indexing to finish and reload."
            )
        case .gradleModules:
            guard let loadModuleGraph else {
                return Outcome(document: .empty(title: title), emptyMessage: "", failure: "Gradle diagrams are unavailable.")
            }
            return await outcome(for: await loadModuleGraph(), title: title, layout: layout, routing: routing,
                                 emptyMessage: "This Gradle build has no project modules.")
        case let .gradleLibraries(projectPath, configuration):
            guard let loadLibraryGraph else {
                return Outcome(document: .empty(title: title), emptyMessage: "", failure: "Gradle diagrams are unavailable.")
            }
            return await outcome(for: await loadLibraryGraph(projectPath, configuration), title: title, layout: layout, routing: routing,
                                 emptyMessage: "\(configuration) has no dependencies in this project.")
        }
    }

    private func outcome(
        for result: Result<GradleDependencyGraph, IDEDiagramLoadFailure>,
        title: String,
        layout: IDEDiagramLayoutKind,
        routing: EdgeRoutingStyle,
        emptyMessage: String
    ) async -> Outcome {
        switch result {
        case let .failure(.message(text)):
            return Outcome(document: .empty(title: title), emptyMessage: emptyMessage, failure: text)
        case let .success(graph):
            let document = await Task.detached(priority: .userInitiated) {
                Self.laidOut(IDEDiagramDocumentBuilder.document(from: graph, title: title), layout: layout, routing: routing)
            }.value
            var notice: String?
            if let error = graph.error, !error.isEmpty {
                notice = error
            } else if graph.truncated {
                notice = "Showing \(graph.components.count) libraries; \(graph.omittedCount) more omitted."
            }
            return Outcome(document: document, notice: notice, emptyMessage: emptyMessage)
        }
    }

    private nonisolated static func laidOut(_ document: IDEDiagramDocument, layout: IDEDiagramLayoutKind, routing: EdgeRoutingStyle) -> IDEDiagramDocument {
        var document = document
        document.canvas.edgeRouting = routing
        return IDEDiagramLayoutEngine.laidOut(document, kind: layout)
    }

    private func apply(_ outcome: Outcome) {
        loadTask = nil
        loadedAt = Date()
        let kept = host.selection
        let previousIDs = Set(host.document.nodes.map(\.id))
        host.replaceDocument(outcome.document)
        let ids = Set(outcome.document.nodes.map(\.id))
        host.selection = kept.intersection(ids)
        host.pruneSelection()
        notice = outcome.notice
        if let failure = outcome.failure {
            state = .failed(failure)
            summary = ""
            return
        }
        if outcome.document.nodes.isEmpty {
            state = .empty(outcome.emptyMessage)
            summary = ""
            return
        }
        state = .ready
        summary = Self.summary(for: outcome.document, request: request)
        if !hasLoadedOnce || previousIDs.isEmpty || previousIDs.isDisjoint(with: ids) {
            pendingFit = true
        }
        hasLoadedOnce = true
        if pendingFit, hasViewSize {
            pendingFit = false
            host.fitViewport()
        }
    }

    private static func summary(for document: IDEDiagramDocument, request: IDEDiagramRequest) -> String {
        let nodes = document.nodes.count
        let edges = document.edges.count
        let noun = request.isClassDiagram ? (nodes == 1 ? "type" : "types") : (nodes == 1 ? "node" : "nodes")
        return "\(nodes) \(noun) · \(edges) \(edges == 1 ? "link" : "links")"
    }

    private func settingsDidChange(from old: IDEDiagramSettings) {
        settings.save(to: defaults)
        if request.isClassDiagram {
            if old.showMembers != settings.showMembers
                || old.showPrivateMembers != settings.showPrivateMembers
                || old.showExternalTypes != settings.showExternalTypes
                || old.neighbourDepth != settings.neighbourDepth
            {
                pendingFit = false
                reload()
                return
            }
        }
        if old.libraryConfiguration != settings.libraryConfiguration, case let .gradleLibraries(path, current) = request,
           current != settings.libraryConfiguration
        {
            request = .gradleLibraries(projectPath: path, configuration: settings.libraryConfiguration)
            reload()
            return
        }
        if old.routing != settings.routing {
            var canvas = host.document.canvas
            canvas.edgeRouting = settings.routing
            host.applyEdit(.setCanvasSettings(canvas), registerUndo: false)
        }
        if old.layout != settings.layout {
            relayout()
        }
    }
}

extension IDEDiagramDocument {
    nonisolated static func empty(title: String) -> IDEDiagramDocument {
        IDEDiagramDocument(meta: .init(title: title), canvas: defaultCanvas, nodes: [], edges: [])
    }
}
