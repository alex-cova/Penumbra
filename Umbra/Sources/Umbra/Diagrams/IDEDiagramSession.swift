import DiagramKit
import Foundation
import AppKit
import Observation

enum IDEDiagramLoadFailure: Error, Equatable {
    case message(String)
}

/// One diagram tab: the request that produced it, the options it is drawn with, and the DiagramKit session
/// holding the document, selection and viewport. The opener supplies the document through ``load``; layout
/// runs off the main actor, and a newer load makes an older one's result get dropped.
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

    /// Builds the document for this tab. Nil means the diagram cannot be drawn.
    @ObservationIgnored var load: (@MainActor (IDEDiagramRequest, IDEDiagramSettings) async -> IDEDiagramLoad)?
    /// The editor buffer a JSON preview draws. Read on the main actor when a load starts.
    @ObservationIgnored var loadJSONText: (() -> String)?
    @ObservationIgnored var openSource: ((URL) -> Void)?
    /// Opens (or reuses) another diagram tab; the Int is the least neighbour depth it should show.
    @ObservationIgnored var openDiagram: ((IDEDiagramRequest, Int) -> Void)?
    /// A diagram of the type a node stands for, and the least neighbour depth that tab should show.
    @ObservationIgnored var relatedTypeDiagram: ((IDEDiagramNode) -> (IDEDiagramRequest, Int)?)?
    /// A dependency diagram for a project node, using the configuration the toolbar has selected.
    @ObservationIgnored var relatedDependencyDiagram: ((IDEDiagramNode, String) -> IDEDiagramRequest?)?
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
        guard let (request, depth) = relatedTypeDiagram?(node) else { return }
        openDiagram?(request, depth)
    }

    func showLibraries(of node: IDEDiagramNode) {
        guard let request = relatedDependencyDiagram?(node, settings.libraryConfiguration) else { return }
        openDiagram?(request, 0)
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

    /// Re-targets a dependency diagram at another configuration without opening a new tab.
    /// The settings change reloads the tab once.
    func setLibraryConfiguration(_ configuration: String) {
        guard request.offersConfigurationPicker, settings.libraryConfiguration != configuration else { return }
        settings.libraryConfiguration = configuration
    }

    var libraryConfiguration: String? {
        request.offersConfigurationPicker ? settings.libraryConfiguration : nil
    }

    /// Points a JSON preview at another file without dropping the viewport. The next reload reads
    /// the buffer through ``loadJSONText``.
    func setJSONPreviewTitle(_ title: String) {
        guard request.isJSONPreview, request.title != title else { return }
        request = .jsonPreview(title: title)
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
        if request.isJSONPreview {
            let text = loadJSONText?() ?? ""
            let built = await Task.detached(priority: .userInitiated) {
                let parsed = JSONDiagramBuilder.build(text: text, title: title)
                let document = parsed.failure == nil
                    ? Self.laidOut(parsed.document, layout: layout, routing: routing)
                    : parsed.document
                return JSONDiagramBuild(document: document, notice: parsed.notice, failure: parsed.failure)
            }.value
            return Outcome(
                document: built.document,
                notice: built.notice,
                emptyMessage: "This JSON value has nothing to draw.",
                failure: built.failure
            )
        }
        guard let load else {
            return Outcome(document: .empty(title: title), emptyMessage: "", failure: "This diagram is unavailable.")
        }
        let loaded = await load(request, settings)
        guard loaded.failure == nil else {
            return Outcome(
                document: loaded.document, notice: loaded.notice, emptyMessage: loaded.emptyMessage, failure: loaded.failure
            )
        }
        let document = await Task.detached(priority: .userInitiated) {
            Self.laidOut(loaded.document, layout: layout, routing: routing)
        }.value
        return Outcome(document: document, notice: loaded.notice, emptyMessage: loaded.emptyMessage)
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
        let noun: String
        if request.isClassDiagram {
            noun = nodes == 1 ? "type" : "types"
        } else if request.isJSONPreview {
            noun = nodes == 1 ? "value" : "values"
        } else {
            noun = nodes == 1 ? "node" : "nodes"
        }
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
        if request.offersConfigurationPicker, old.libraryConfiguration != settings.libraryConfiguration {
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
