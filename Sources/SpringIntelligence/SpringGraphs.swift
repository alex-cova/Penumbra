import Foundation

public struct SpringGraphNode: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case bean(label: String)
        /// A type something injects that no bean provides in this application (a library type, or a missing bean).
        case external
        case configuration
        case scannedPackage
        /// Something an `@Import`/`@ImportResource` names that the model cannot read.
        case unknown
    }
    public let id: String
    public let title: String
    public let subtitle: String
    public let kind: Kind
    public let certainty: SpringCertainty
    public let beanID: SpringBeanID?
    public let module: String?
    public let location: SpringSourceLocation?
    public var isInCycle = false
}

public struct SpringGraphEdge: Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        /// Every input the analysis can see agrees.
        case verified
        /// Depends on a condition (profile, `@Conditional…`) or on one of several candidates.
        case conditional
        /// Several beans could satisfy it and nothing picks one.
        case ambiguous
        /// No bean found or the qualifier matches nothing.
        case unresolved
    }
    public enum Relation: Hashable, Sendable {
        case injection(SpringInjectionKind)
        case declares, importClass, importResource, componentScan
    }
    public let from: String
    public let to: String
    public let relation: Relation
    public let status: Status
    /// The parameter or field name, for the edge label.
    public let label: String
    /// Resolved at use (`Optional`, `ObjectProvider`, `@Lazy`), so it cannot create a startup cycle.
    public let isDeferred: Bool
    public var isInCycle = false
    public let location: SpringSourceLocation?
}

public struct SpringGraphSlice: Sendable {
    public var nodes: [SpringGraphNode]
    public var edges: [SpringGraphEdge]
    /// Node ids whose title or type matches the search text.
    public var matches: Set<String>
    /// True when the node limit cut the picture short.
    public var isTruncated: Bool
    /// Honest remarks (what this graph cannot know).
    public var notes: [String]
}

public struct SpringBeanGraphOptions: Equatable, Sendable {
    public enum Direction: String, CaseIterable, Sendable { case outgoing, incoming, both }
    /// Start at this bean. Without a focus the whole (filtered) graph is returned, up to `nodeLimit`.
    public var focus: SpringBeanID?
    public var direction: Direction = .both
    /// Hops from the focus; `nil` means unlimited.
    public var depth: Int? = 2
    public var modules: Set<String> = []
    public var stereotypes: Set<SpringStereotype> = []
    /// Types injected but not provided as beans (library types, missing beans).
    public var showExternal = true
    public var includeFactoryBeans = true
    public var search = ""
    public var nodeLimit = 300
    public init() {}
}

/// The bean dependency graph of one application context: nodes are bean definitions, edges are injection points resolved by
/// the model. Built once per model; `slice` answers filters and explorations from precomputed adjacency.
public struct SpringBeanGraph: Sendable {
    private let nodes: [String: SpringGraphNode]
    private let order: [String]
    private let outgoing: [String: [SpringGraphEdge]]
    private let incoming: [String: [SpringGraphEdge]]
    public let cycleCount: Int

    public init(context: SpringApplicationContext, moduleOf: (URL) -> String?) {
        let model = context.model
        var cycleOf: [String: Int] = [:]
        for (i, cycle) in model.cycles.enumerated() { for b in cycle.beans { cycleOf[b.raw] = i } }
        cycleCount = model.cycles.count
        var nodes: [String: SpringGraphNode] = [:]
        var order: [String] = []
        for bean in model.beans {
            var n = SpringGraphNode(
                id: bean.id.raw, title: bean.name, subtitle: bean.type.simpleName,
                kind: .bean(label: SpringBeanIndex.kindLabel(bean)), certainty: bean.certainty, beanID: bean.id,
                module: moduleOf(bean.location.url), location: bean.location)
            n.isInCycle = cycleOf[bean.id.raw] != nil
            nodes[n.id] = n
            order.append(n.id)
        }
        var out: [String: [SpringGraphEdge]] = [:], inc: [String: [SpringGraphEdge]] = [:]
        func add(_ e: SpringGraphEdge) { out[e.from, default: []].append(e); inc[e.to, default: []].append(e) }
        func external(_ type: SpringType, reason: String) -> String {
            let id = "external:" + type.name
            if nodes[id] == nil {
                nodes[id] = SpringGraphNode(id: id, title: type.simpleName, subtitle: reason, kind: .external, certainty: .certain,
                                            beanID: nil, module: nil, location: nil)
                order.append(id)
            }
            return id
        }
        for point in model.injectionPoints {
            guard let owner = model.bean(point.owner) else { continue }
            let from = owner.id.raw
            func edge(_ to: String, _ status: SpringGraphEdge.Status) {
                let sameCycle = cycleOf[from] != nil && cycleOf[from] == cycleOf[to]
                var e = SpringGraphEdge(from: from, to: to, relation: .injection(point.kind), status: status, label: point.name,
                                        isDeferred: point.isDeferred, location: point.location)
                e.isInCycle = sameCycle && !point.isDeferred
                add(e)
            }
            func status(for target: SpringBean) -> SpringGraphEdge.Status {
                owner.certainty.isConditional || target.certainty.isConditional ? .conditional : .verified
            }
            switch model.resolutions[point] {
            case .resolved(let b)?:
                if let t = model.bean(b) { edge(b.raw, status(for: t)) }
            case .collection(let bs)?:
                for b in bs { if let t = model.bean(b) { edge(b.raw, status(for: t)) } }
            case .ambiguous(let bs)?:
                for b in bs { edge(b.raw, .ambiguous) }
            case .uncertain(let cs, let reason)?:
                if cs.isEmpty { edge(external(point.requiredType, reason: reason), .conditional) }
                else { for b in cs { edge(b.raw, .conditional) } }
            case .missing?:
                edge(external(point.requiredType, reason: "no bean of this type"), .unresolved)
            case .unknownQualifier(let q)?:
                edge(external(point.requiredType, reason: "no bean for qualifier '\(q)'"), .unresolved)
            case nil: break
            }
        }
        self.nodes = nodes; self.order = order; outgoing = out; incoming = inc
    }

    public var nodeCount: Int { nodes.count }
    public var edgeCount: Int { outgoing.values.reduce(0) { $0 + $1.count } }

    public func node(_ id: String) -> SpringGraphNode? { nodes[id] }

    /// The part of the graph `options` asks for. A focus walks outward from that bean (breadth first) up to `depth`
    /// hops in the chosen direction; filters then drop beans (never the focus) and the edges that touched them.
    public func slice(_ options: SpringBeanGraphOptions) -> SpringGraphSlice {
        func passes(_ n: SpringGraphNode) -> Bool {
            switch n.kind {
            case .external: return options.showExternal
            case .bean(let label):
                if !options.includeFactoryBeans, label == "@Bean" { return false }
                if !options.modules.isEmpty, !(n.module.map(options.modules.contains) ?? false) { return false }
                if !options.stereotypes.isEmpty {
                    // Row stereotypes are not stored on nodes; the label is enough for the filter's purpose.
                    return options.stereotypes.contains { Self.label(of: $0) == label }
                }
                return true
            default: return true
            }
        }
        var chosen: [String] = []
        var seen = Set<String>()
        var truncated = false
        if let focus = options.focus, nodes[focus.raw] != nil {
            var frontier = [focus.raw]
            seen.insert(focus.raw); chosen.append(focus.raw)
            var depth = 0
            while !frontier.isEmpty, options.depth.map({ depth < $0 }) ?? true {
                var next: [String] = []
                for id in frontier {
                    var neighbours: [String] = []
                    if options.direction != .incoming { neighbours += (outgoing[id] ?? []).map(\.to) }
                    if options.direction != .outgoing { neighbours += (incoming[id] ?? []).map(\.from) }
                    for n in neighbours where !seen.contains(n) {
                        guard let node = nodes[n], passes(node) else { continue }
                        if chosen.count >= options.nodeLimit { truncated = true; continue }
                        seen.insert(n); chosen.append(n); next.append(n)
                    }
                }
                frontier = next
                depth += 1
            }
        } else {
            for id in order {
                guard let node = nodes[id], passes(node) else { continue }
                if chosen.count >= options.nodeLimit { truncated = true; break }
                chosen.append(id); seen.insert(id)
            }
        }
        var edges: [SpringGraphEdge] = []
        for id in chosen { for e in outgoing[id] ?? [] where seen.contains(e.to) { edges.append(e) } }
        let query = options.search.lowercased()
        let matches: Set<String> = query.isEmpty ? [] : Set(chosen.filter {
            guard let n = nodes[$0] else { return false }
            return n.title.lowercased().contains(query) || n.subtitle.lowercased().contains(query)
        })
        var notes: [String] = []
        if truncated { notes.append("Showing the first \(options.nodeLimit) beans; narrow the filters or pick a focus to see the rest.") }
        if edges.contains(where: { $0.status == .conditional }) { notes.append("Dashed edges depend on a condition or on one of several candidates.") }
        return SpringGraphSlice(nodes: chosen.compactMap { nodes[$0] }, edges: edges, matches: matches, isTruncated: truncated, notes: notes)
    }

    static func label(of s: SpringStereotype) -> String {
        switch s {
        case .restController: return "RestController"
        case .controller: return "Controller"
        case .controllerAdvice: return "ControllerAdvice"
        case .service: return "Service"
        case .repository: return "Repository"
        case .configuration: return "Configuration"
        case .springBootApplication: return "Application"
        case .component: return "Component"
        }
    }
}

/// The configuration graph of one application: configuration classes, what they import and scan, and the beans their
/// factory methods declare. It is not the bean graph: its edges say where beans *come from*, not what they use.
public struct SpringContextGraph: Sendable {
    public let nodes: [SpringGraphNode]
    public let edges: [SpringGraphEdge]
    public let notes: [String]

    public init(context: SpringApplicationContext, moduleOf: (URL) -> String?) {
        let model = context.model
        var nodes: [String: SpringGraphNode] = [:]
        var order: [String] = []
        var edges: [SpringGraphEdge] = []
        func put(_ n: SpringGraphNode) { if nodes[n.id] == nil { nodes[n.id] = n; order.append(n.id) } }
        let beansByType = Dictionary(model.beans.filter { if case .stereotype = $0.origin { return true } else { return false } }.map { ($0.type.name, $0) },
                                     uniquingKeysWith: { a, _ in a })
        func configNode(_ typeName: String) -> String {
            let id = "config:" + typeName
            if let bean = beansByType[typeName] {
                put(SpringGraphNode(id: id, title: bean.name, subtitle: bean.type.name, kind: .configuration, certainty: bean.certainty,
                                    beanID: bean.id, module: moduleOf(bean.location.url), location: bean.location))
            } else {
                put(SpringGraphNode(id: id, title: typeName.split(separator: ".").last.map(String.init) ?? typeName, subtitle: typeName,
                                    kind: .configuration, certainty: .certain, beanID: nil, module: nil, location: nil))
            }
            return id
        }
        let packages = model.beans.map { b -> String in b.type.name.split(separator: ".").dropLast().joined(separator: ".") }
        for link in model.configurationLinks {
            let from = configNode(link.from)
            switch link.kind {
            case .scan(let package):
                let id = "scan:" + package
                let count = packages.filter { $0 == package || $0.hasPrefix(package + ".") }.count
                put(SpringGraphNode(id: id, title: package, subtitle: "component scan · \(count) bean\(count == 1 ? "" : "s")",
                                    kind: .scannedPackage, certainty: .certain, beanID: nil, module: nil, location: nil))
                edges.append(SpringGraphEdge(from: from, to: id, relation: .componentScan, status: .verified, label: "scans", isDeferred: false, location: link.location))
            case .importClass(let target, let resolved):
                if resolved {
                    edges.append(SpringGraphEdge(from: from, to: configNode(target), relation: .importClass, status: .verified, label: "@Import", isDeferred: false, location: link.location))
                } else {
                    let id = "unknown:" + link.from + ":" + target
                    put(SpringGraphNode(id: id, title: target, subtitle: "not in the project's sources", kind: .unknown, certainty: .certain, beanID: nil, module: nil, location: nil))
                    edges.append(SpringGraphEdge(from: from, to: id, relation: .importClass, status: .unresolved, label: "@Import", isDeferred: false, location: link.location))
                }
            case .importResource(let locations):
                let id = "resource:" + link.from + ":" + locations.joined(separator: ",")
                put(SpringGraphNode(id: id, title: locations.first ?? "resource", subtitle: "bean definitions are not read here", kind: .unknown,
                                    certainty: .certain, beanID: nil, module: nil, location: nil))
                edges.append(SpringGraphEdge(from: from, to: id, relation: .importResource, status: .unresolved, label: "@ImportResource", isDeferred: false, location: link.location))
            }
        }
        // Factory methods: configuration class → the beans it declares.
        for bean in model.beans {
            guard case .factoryMethod(let config, _) = bean.origin else { continue }
            let from = configNode(config)
            put(SpringGraphNode(id: bean.id.raw, title: bean.name, subtitle: bean.type.simpleName, kind: .bean(label: "@Bean"), certainty: bean.certainty,
                                beanID: bean.id, module: moduleOf(bean.location.url), location: bean.location))
            edges.append(SpringGraphEdge(from: from, to: bean.id.raw, relation: .declares, status: bean.certainty.isConditional ? .conditional : .verified,
                                         label: "@Bean", isDeferred: false, location: bean.location))
        }
        if let entry = context.entry { _ = configNode(entry.typeName) }
        self.nodes = order.compactMap { nodes[$0] }
        self.edges = edges
        notes = ["Parent–child application contexts are created in code (SpringApplicationBuilder, ApplicationContext#setParent) and are not shown.",
                 "Conditional configuration is drawn dashed; custom @Conditional logic is never evaluated."]
    }
}
