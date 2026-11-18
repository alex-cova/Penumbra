import Foundation

/// What the Endpoints list can be narrowed and ordered by. Empty sets mean "any".
public struct SpringEndpointFilter: Equatable, Sendable {
    public enum Sort: String, CaseIterable, Sendable {
        case route, method, controller, module
        public var title: String { rawValue.capitalized }
    }
    public var text = ""
    public var methods: Set<String> = []
    public var modules: Set<String> = []
    public var includeInactive = true
    public var onlyProblems = false
    public var sort: Sort = .route
    public init() {}
}

/// Two endpoints Spring cannot tell apart for some request.
public struct SpringEndpointConflict: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Same path pattern and the same conditions: `RequestMappingHandlerMapping` fails at startup with "Ambiguous mapping".
        case identical
        /// Patterns that differ only in variable names (`/a/{x}`, `/a/{y}`): both match the same requests with the same
        /// specificity, so the first matching request fails with "Ambiguous handler methods".
        case equivalentVariables
    }
    public let endpoints: [SpringEndpointID]
    public let kind: Kind
}

/// The HTTP endpoints of one application context: built once from the controllers' extractions, searched without re-reading anything.
public struct SpringEndpointIndex: Sendable {
    public let contextID: String
    /// In route order (route, then method, then handler).
    public let endpoints: [SpringEndpoint]
    public let diagnostics: [SpringDiagnostic]
    public let conflicts: [SpringEndpointConflict]
    public let modules: [String]
    public let controllers: [String]

    /// The lower-cased search text of every endpoint in one buffer (`starts[i]..<starts[i + 1]`), so a search is a byte scan over
    /// contiguous memory rather than a string search per endpoint.
    private let haystack: [UInt8]
    private let starts: [Int]
    private let literalPrefixes: [String]
    private let positionByID: [SpringEndpointID: Int]
    private let problemIDs: Set<SpringEndpointID>
    private let methodOrder: [Int], controllerOrder: [Int], moduleOrder: [Int]

    public static func empty(contextID: String) -> SpringEndpointIndex {
        SpringEndpointIndex(contextID: contextID, endpoints: [], extractionDiagnostics: [])
    }

    public init(contextID: String, endpoints unsorted: [SpringEndpoint], extractionDiagnostics: [SpringDiagnostic]) {
        self.contextID = contextID
        struct Key { let route: String; let rank: Int; let title: String; let id: String }
        let keys = unsorted.map { e in
            Key(route: e.route, rank: e.conditions.methods.first.flatMap { SpringRequestConditions.methodOrder.firstIndex(of: $0) } ?? 99,
                title: e.handlerTitle, id: e.id.raw)
        }
        let order = unsorted.indices.sorted { a, b in
            let l = keys[a], r = keys[b]
            if l.route != r.route { return l.route < r.route }
            if l.rank != r.rank { return l.rank < r.rank }
            return l.title != r.title ? l.title < r.title : l.id < r.id
        }
        let sorted = order.map { unsorted[$0] }
        endpoints = sorted
        var blob: [UInt8] = []
        var offsets: [Int] = [0]
        blob.reserveCapacity(sorted.count * 96)
        for e in sorted {
            for part in [e.methodsTitle, e.route, e.controller, e.handler, e.module ?? "", e.mappingName ?? ""] + e.conditions.produces + e.conditions.consumes {
                blob.append(contentsOf: part.lowercased().utf8)
                blob.append(0x01)
            }
            offsets.append(blob.count)
        }
        haystack = blob
        starts = offsets
        literalPrefixes = sorted.map { e in
            let prefix = SpringRoute.literalPrefix(e.route)
            return prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        }
        var positions: [SpringEndpointID: Int] = [:]
        positions.reserveCapacity(sorted.count)
        for (i, e) in sorted.enumerated() { positions[e.id] = i }
        positionByID = positions
        modules = Array(Set(sorted.compactMap(\.module))).sorted()
        controllers = Array(Set(sorted.map(\.controller))).sorted()

        // Conflicts: group on the pattern's structure and every other condition, so only requests Spring cannot rank are reported.
        var groups: [String: [Int]] = [:]
        for (i, e) in sorted.enumerated() where e.confidence.isExact && !e.certainty.isInactive {
            groups[(e.route.contains("{") ? SpringRoute.structure(e.route) : e.route) + "\u{2}" + Self.conditionsKey(e.conditions), default: []].append(i)
        }
        var found: [SpringEndpointConflict] = []
        var out = extractionDiagnostics
        var seen = Set<String>()
        for (_, members) in groups.sorted(by: { $0.key < $1.key }) where members.count > 1 {
            let handlers = Set(members.map { "\(sorted[$0].controller)#\(sorted[$0].handlerSignature)" })
            guard handlers.count > 1 else { continue }
            let identical = Set(members.map { sorted[$0].route }).count < members.count
            let allCertain = members.allSatisfy { sorted[$0].certainty == .certain }
            found.append(SpringEndpointConflict(endpoints: members.map { sorted[$0].id }, kind: identical ? .identical : .equivalentVariables))
            for i in members {
                let e = sorted[i]
                let others = members.map { sorted[$0] }.filter { "\($0.controller)#\($0.handlerSignature)" != "\(e.controller)#\(e.handlerSignature)" }
                guard !others.isEmpty else { continue }
                let sameRoute = others.contains { $0.route == e.route }
                let names = Array(NSOrderedSet(array: others.map(\.handlerTitle))) as? [String] ?? []
                let list = names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and \(names.count - 3) more" : "")
                let code: String, severity: SpringDiagnosticSeverity, message: String
                if sameRoute {
                    code = SpringEndpointDiagnosticCode.ambiguous
                    severity = allCertain ? .error : .warning
                    message = "Ambiguous mapping: \(e.title) is also mapped by \(list)."
                        + (allCertain ? " Spring fails at startup with 'Ambiguous mapping'." : " Spring rejects this if both controllers are registered.")
                } else {
                    code = SpringEndpointDiagnosticCode.ambiguousVariables
                    severity = .warning
                    message = "\(e.title) differs from \(others.map(\.title).prefix(2).joined(separator: ", ")) (\(list)) only in variable names, so Spring cannot rank them: a request matching both fails with 'Ambiguous handler methods'."
                }
                let key = "\(code)|\(e.mappingLocation.url.path)|\(e.mappingLocation.byteRange.lowerBound)|\(message)"
                if seen.insert(key).inserted {
                    out.append(SpringDiagnostic(severity: severity, code: code, message: message, location: e.mappingLocation, related: []))
                }
            }
        }
        conflicts = found
        diagnostics = out
        var problems = Set<SpringEndpointID>()
        if !out.isEmpty {
            var byLocation: [SpringSourceLocation: [SpringEndpointID]] = [:]
            for e in sorted {
                byLocation[e.mappingLocation, default: []].append(e.id)
                byLocation[e.handlerLocation, default: []].append(e.id)
            }
            for d in out { problems.formUnion(byLocation[d.location] ?? []) }
        }
        problemIDs = problems
        let idx = Array(sorted.indices)
        let methodRank = sorted.map { e in e.conditions.methods.first.flatMap { SpringRequestConditions.methodOrder.firstIndex(of: $0) } ?? 99 }
        methodOrder = idx.sorted { methodRank[$0] != methodRank[$1] ? methodRank[$0] < methodRank[$1] : $0 < $1 }
        let controllerRank = Dictionary(uniqueKeysWithValues: controllers.enumerated().map { ($1, $0) })
        let controllerKey = sorted.map { controllerRank[$0.controller] ?? 0 }
        controllerOrder = idx.sorted { controllerKey[$0] != controllerKey[$1] ? controllerKey[$0] < controllerKey[$1] : $0 < $1 }
        let moduleRank = Dictionary(uniqueKeysWithValues: modules.enumerated().map { ($1, $0 + 1) })
        let moduleKey = sorted.map { $0.module.flatMap { moduleRank[$0] } ?? 0 }
        moduleOrder = idx.sorted { moduleKey[$0] != moduleKey[$1] ? moduleKey[$0] < moduleKey[$1] : $0 < $1 }
    }

    private static func conditionsKey(_ c: SpringRequestConditions) -> String {
        [c.methods, c.params, c.headers, c.consumes, c.produces].map { $0.joined(separator: ",") }.joined(separator: "|")
    }

    public func endpoint(_ id: SpringEndpointID) -> SpringEndpoint? { positionByID[id].map { endpoints[$0] } }

    /// Endpoints whose handler or mapping annotation lives in `url`.
    public func endpoints(in url: URL) -> [SpringEndpoint] {
        endpoints.filter { $0.handlerLocation.url == url || $0.mappingLocation.url == url }
    }

    /// The endpoints whose handler name or mapping annotation covers `byteOffset` of `url`.
    public func endpoints(in url: URL, atByte byteOffset: Int) -> [SpringEndpoint] {
        endpoints(in: url).filter {
            ($0.handlerLocation.url == url && ($0.handlerLocation.byteRange.contains(byteOffset) || $0.handlerLocation.byteRange.upperBound == byteOffset))
                || ($0.mappingLocation.url == url && $0.mappingLocation.byteRange.contains(byteOffset))
        }
    }

    public func diagnostics(in url: URL) -> [SpringDiagnostic] { diagnostics.filter { $0.location.url == url } }

    public func hasProblems(_ id: SpringEndpointID) -> Bool { problemIDs.contains(id) }

    /// Endpoints a concrete request could reach: the path (query and host already removed) against each route pattern, and the
    /// HTTP method when known. A mapping that accepts any method matches every method.
    public func endpoints(matchingPath path: String, method: String? = nil) -> [SpringEndpoint] {
        let clean = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let upper = method?.uppercased()
        var out: [SpringEndpoint] = []
        for (i, e) in endpoints.enumerated() {
            let prefix = literalPrefixes[i]
            guard prefix.isEmpty || clean.isEmpty || clean.hasPrefix(prefix) else { continue }
            if let upper, !e.conditions.methods.isEmpty, !e.conditions.methods.contains(upper) { continue }
            if SpringRoute.matches(pattern: e.route, path: clean) { out.append(e) }
        }
        return out
    }

    /// Endpoints matching `filter`, in the requested order. Every word of the search text must appear in the method, route,
    /// controller, handler, module, name or a produced/consumed type.
    public func search(_ filter: SpringEndpointFilter) -> [SpringEndpoint] {
        let words = filter.text.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let order: [Int]
        switch filter.sort {
        case .route: order = Array(endpoints.indices)
        case .method: order = methodOrder
        case .controller: order = controllerOrder
        case .module: order = moduleOrder
        }
        var out: [SpringEndpoint] = []
        let needles = words.map { Array($0.utf8) }
        haystack.withUnsafeBufferPointer { hay in
            for i in order {
                let e = endpoints[i]
                if !needles.isEmpty, let base = hay.baseAddress {
                    let lo = starts[i], len = starts[i + 1] - lo
                    var matched = true
                    for n in needles where memmem(base + lo, len, n, n.count) == nil { matched = false; break }
                    if !matched { continue }
                }
                if !filter.methods.isEmpty {
                    let m = e.conditions.methods.isEmpty ? ["ANY"] : e.conditions.methods
                    if filter.methods.isDisjoint(with: m) { continue }
                }
                if !filter.modules.isEmpty, !(e.module.map(filter.modules.contains) ?? false) { continue }
                if !filter.includeInactive, e.certainty.isInactive { continue }
                if filter.onlyProblems, !problemIDs.contains(e.id) { continue }
                out.append(e)
            }
        }
        return out
    }
}
