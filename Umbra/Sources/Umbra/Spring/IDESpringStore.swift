import EditorIntelligence
import Foundation
import Observation
import SpringIntelligence

/// What the Spring tool window shows for the window's project. Built off the main actor from the indexer's model and kept until
/// a Spring-relevant change (`SpringProjectModel.revision` / `configRevision`), so opening the panel again never scans anything.
struct IDESpringSnapshot: Sendable {
    struct ContextData: Sendable, Identifiable {
        var id: String { context.id }
        let context: SpringApplicationContext
        let beans: SpringBeanIndex
        let beanGraph: SpringBeanGraph
        let contextGraph: SpringContextGraph
        let endpoints: SpringEndpointIndex
    }
    let revision: Int
    let configRevision: Int
    let endpointRevision: Int
    let contexts: [ContextData]
    let modules: [SpringModuleInfo]
    let config: SpringConfigModel
    /// Diagnostics of the configuration files, by file, for the Configuration section.
    let configDiagnostics: [URL: [SpringDiagnostic]]
}

/// A section of the Spring tool window.
enum IDESpringSection: String, CaseIterable, Identifiable {
    case applications, beans, endpoints, configuration, runtime
    var id: String { rawValue }
    var title: String {
        switch self {
        case .applications: "Applications"
        case .beans: "Beans"
        case .endpoints: "Endpoints"
        case .configuration: "Configuration"
        case .runtime: "Runtime"
        }
    }
    var symbol: String {
        switch self {
        case .applications: "app.badge"
        case .beans: "leaf"
        case .endpoints: "network"
        case .configuration: "gearshape"
        case .runtime: "waveform.path.ecg"
        }
    }
}

/// The tool window's state: which section, which application, the bean filter and selection. The parts the user would expect to find
/// again (section, application, search text) persist; the loaded data does not, it is rebuilt from the index.
@MainActor
@Observable
final class IDESpringStore {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case notSpring
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var snapshot: IDESpringSnapshot?
    /// How many snapshots were built (a valid snapshot is kept, so reopening the panel does not add one).
    @ObservationIgnored private(set) var buildCount = 0

    var section: IDESpringSection { didSet { defaults.set(section.rawValue, forKey: Keys.section) } }
    var selectedContextID: String? { didSet { defaults.set(selectedContextID, forKey: Keys.context) } }
    var filter: SpringBeanFilter { didSet { defaults.set(filter.text, forKey: Keys.filterText) } }
    var selectedBeanID: SpringBeanID?
    var endpointFilter: SpringEndpointFilter { didSet { defaults.set(endpointFilter.text, forKey: Keys.endpointText) } }
    var selectedEndpointID: SpringEndpointID?
    /// List the endpoints of every application, not only the selected one.
    var endpointScopeIsAll = false
    var groupEndpointsByController: Bool { didSet { defaults.set(groupEndpointsByController, forKey: Keys.groupEndpoints) } }
    var graphOptions = SpringBeanGraphOptions()

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    private enum Keys {
        static let section = "com.umbra.editor.spring.section"
        static let context = "com.umbra.editor.spring.context"
        static let filterText = "com.umbra.editor.spring.filterText"
        static let endpointText = "com.umbra.editor.spring.endpointText"
        static let groupEndpoints = "com.umbra.editor.spring.groupEndpoints"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        section = defaults.string(forKey: Keys.section).flatMap(IDESpringSection.init(rawValue:)) ?? .beans
        selectedContextID = defaults.string(forKey: Keys.context)
        var f = SpringBeanFilter()
        f.text = defaults.string(forKey: Keys.filterText) ?? ""
        filter = f
        var e = SpringEndpointFilter()
        e.text = defaults.string(forKey: Keys.endpointText) ?? ""
        endpointFilter = e
        groupEndpointsByController = defaults.bool(forKey: Keys.groupEndpoints)
    }

    var currentContext: IDESpringSnapshot.ContextData? {
        guard let snapshot else { return nil }
        return snapshot.contexts.first { $0.id == selectedContextID } ?? snapshot.contexts.first
    }

    var rows: [SpringBeanRow] { currentContext?.beans.search(filter) ?? [] }

    /// Endpoints matching the filter: of the selected application, or of every one (grouped by application) when asked.
    var endpointRows: [SpringEndpoint] {
        guard let snapshot else { return [] }
        if endpointScopeIsAll { return snapshot.contexts.flatMap { $0.endpoints.search(endpointFilter) } }
        return currentContext?.endpoints.search(endpointFilter) ?? []
    }

    var selectedEndpoint: SpringEndpoint? {
        guard let id = selectedEndpointID, let snapshot else { return nil }
        for c in snapshot.contexts { if let e = c.endpoints.endpoint(id) { return e } }
        return nil
    }

    func hasProblems(_ endpoint: SpringEndpoint) -> Bool {
        snapshot?.contexts.first { $0.id == endpoint.contextID }?.endpoints.hasProblems(endpoint.id) ?? false
    }

    /// The problems that belong to an endpoint: its mapping, its handler and its parameters.
    func diagnostics(for endpoint: SpringEndpoint) -> [SpringDiagnostic] {
        guard let index = snapshot?.contexts.first(where: { $0.id == endpoint.contextID })?.endpoints else { return [] }
        let places = Set([endpoint.mappingLocation, endpoint.handlerLocation] + (endpoint.classMappingLocation.map { [$0] } ?? []) + endpoint.parameters.map(\.location))
        return index.diagnostics.filter { places.contains($0.location) }
    }

    /// Selects an endpoint (from the gutter or the inspector) and shows it in the Endpoints section.
    func reveal(endpoint id: SpringEndpointID, contextID: String?) {
        if let contextID { selectedContextID = contextID }
        section = .endpoints
        endpointScopeIsAll = false
        var f = endpointFilter; f.text = ""; endpointFilter = f
        selectedEndpointID = id
    }

    /// Waits for the load in flight (tests, and callers that need the data before acting).
    func waitForLoad() async { await loadTask?.value }

    /// Loads (or re-loads after a change) the snapshot. A snapshot whose revisions still match the index is kept as is.
    func refresh(indexer: SpringWorkspaceIndexer) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let store = indexer.store
            let isActive = await indexer.isActive
            guard isActive else {
                self?.finish(snapshot: nil, phase: .notSpring)
                return
            }
            let revision = await store.revision, configRevision = await store.configRevision, endpointRevision = await store.endpointRevision
            if let current = self?.snapshot, current.revision == revision, current.configRevision == configRevision, current.endpointRevision == endpointRevision, self?.phase == .ready { return }
            self?.phase = self?.snapshot == nil ? .loading : (self?.phase ?? .loading)
            let modules = await indexer.modules
            let built = await Task.detached(priority: .userInitiated) { () -> IDESpringSnapshot in
                let contexts = await store.contexts()
                let config = await store.config()
                let endpointIndexes = await store.endpointIndexes()
                let resolver = SpringModuleResolver(modules: modules)
                let moduleOf: @Sendable (URL) -> String? = { resolver.owner(of: $0) }
                let data = contexts.map {
                    IDESpringSnapshot.ContextData(
                        context: $0, beans: SpringBeanIndex(context: $0, moduleOf: moduleOf),
                        beanGraph: SpringBeanGraph(context: $0, moduleOf: moduleOf),
                        contextGraph: SpringContextGraph(context: $0, moduleOf: moduleOf),
                        endpoints: endpointIndexes.first(where: { [id = $0.id] index in index.contextID == id }) ?? .empty(contextID: $0.id))
                }
                var diagnostics: [URL: [SpringDiagnostic]] = [:]
                for file in config.files { let d = config.diagnostics(for: file.url); if !d.isEmpty { diagnostics[file.url] = d } }
                return IDESpringSnapshot(revision: revision, configRevision: configRevision, endpointRevision: endpointRevision, contexts: data, modules: modules,
                                         config: config, configDiagnostics: diagnostics)
            }.value
            if Task.isCancelled { return }
            self?.buildCount += 1
            self?.finish(snapshot: built, phase: .ready)
        }
    }

    private func finish(snapshot: IDESpringSnapshot?, phase: Phase) {
        self.snapshot = snapshot
        self.phase = phase
        if let snapshot, !snapshot.contexts.contains(where: { $0.id == selectedContextID }) { selectedContextID = snapshot.contexts.first?.id }
        if let selected = selectedBeanID, currentContext?.context.model.bean(selected) == nil { selectedBeanID = nil }
        if snapshot != nil, selectedEndpointID != nil, selectedEndpoint == nil { selectedEndpointID = nil }
    }

    /// Selects a bean (from the editor gutter or the inspector) and shows it in the Beans section.
    func reveal(bean: SpringBeanID, contextID: String?) {
        if let contextID { selectedContextID = contextID }
        section = .beans
        var f = filter; f.text = ""; filter = f
        selectedBeanID = bean
    }

    func inspection(for id: SpringBeanID) -> SpringBeanInspection? {
        currentContext.flatMap { SpringBeanInspection(bean: id, in: $0.context.model) }
    }
}
