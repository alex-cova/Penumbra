import Foundation

/// A bean as the tool window lists it: everything the table shows, precomputed so search and sorting never touch the model.
public struct SpringBeanRow: Identifiable, Hashable, Sendable {
    public let id: SpringBeanID
    public let name: String
    public let typeName: String
    public let simpleType: String
    public let kindLabel: String
    public let stereotypes: Set<SpringStereotype>
    public let scope: String
    public let qualifiers: [String]
    public let isPrimary: Bool
    public let isFallback: Bool
    public let certainty: SpringCertainty
    /// The configuration class of a `@Bean` method, or the file's class for a stereotype bean.
    public let configurationSource: String
    public let module: String?
    public let dependencyCount: Int
    public let consumerCount: Int
    public let location: SpringSourceLocation
    fileprivate let haystack: String
}

/// What the Beans list can be narrowed by. Empty sets mean "any".
public struct SpringBeanFilter: Equatable, Sendable {
    public enum ConditionalState: String, CaseIterable, Sendable { case any, certain, conditional, inactive }
    public var text = ""
    public var stereotypes: Set<SpringStereotype> = []
    public var includeFactoryBeans = true
    public var modules: Set<String> = []
    public var conditional: ConditionalState = .any
    public var onlyProblems = false
    public init() {}
}

/// The Beans list of one application context: built once per model, searched without re-reading it.
public struct SpringBeanIndex: Sendable {
    public let contextID: String
    public let rows: [SpringBeanRow]
    private let problemBeans: Set<SpringBeanID>

    public init(context: SpringApplicationContext, moduleOf: (URL) -> String?) {
        let model = context.model
        var dependencies: [SpringBeanID: Int] = [:]
        var consumers: [SpringBeanID: Set<SpringBeanID>] = [:]
        for point in model.injectionPoints {
            dependencies[point.owner, default: 0] += 1
            let targets: [SpringBeanID]
            switch model.resolutions[point] {
            case .resolved(let b)?: targets = [b]
            case .collection(let bs)?, .ambiguous(let bs)?: targets = bs
            case .uncertain(let cs, _)?: targets = cs
            default: targets = []
            }
            for t in targets { consumers[t, default: []].insert(point.owner) }
        }
        var problems = Set<SpringBeanID>()
        for d in model.diagnostics { problems.formUnion(d.related) }
        for p in model.injectionPoints {
            switch model.resolutions[p] {
            case .missing?, .ambiguous?, .unknownQualifier?: problems.insert(p.owner)
            default: break
            }
        }
        problemBeans = problems
        contextID = context.id
        let keyed = model.beans.map { bean -> (SpringBeanRow, String) in
            let conf: String
            switch bean.origin {
            case .factoryMethod(let c, _): conf = c
            case .stereotype: conf = bean.type.name
            }
            let row = SpringBeanRow(
                id: bean.id, name: bean.name, typeName: bean.type.name, simpleType: bean.type.simpleName,
                kindLabel: Self.kindLabel(bean), stereotypes: bean.stereotypes, scope: bean.scope, qualifiers: bean.qualifiers,
                isPrimary: bean.isPrimary, isFallback: bean.isFallback, certainty: bean.certainty, configurationSource: conf,
                module: moduleOf(bean.location.url), dependencyCount: dependencies[bean.id] ?? 0,
                consumerCount: consumers[bean.id]?.count ?? 0, location: bean.location,
                haystack: ([bean.name, bean.type.name, conf] + bean.qualifiers + bean.aliases).joined(separator: "\u{1}").lowercased())
            return (row, bean.name.lowercased())
        }
        // Sorted on a key computed once per bean, not lowercased inside every comparison.
        rows = keyed.sorted { ($0.1, $0.0.id.raw) < ($1.1, $1.0.id.raw) }.map(\.0)
    }

    static func kindLabel(_ bean: SpringBean) -> String {
        if case .factoryMethod = bean.origin { return "@Bean" }
        let s = bean.stereotypes
        if s.contains(.springBootApplication) { return "Application" }
        if s.contains(.restController) { return "RestController" }
        if s.contains(.controllerAdvice) { return "ControllerAdvice" }
        if s.contains(.controller) { return "Controller" }
        if s.contains(.service) { return "Service" }
        if s.contains(.repository) { return "Repository" }
        if s.contains(.configuration) { return "Configuration" }
        if case .stereotype(let a) = bean.origin, a.hasSuffix(".Import") { return "@Import" }
        return "Component"
    }

    /// Rows matching `filter`. Every word of the search text must appear in the name, type, configuration class or a
    /// qualifier (case-insensitive); the order of `rows` is kept.
    public func search(_ filter: SpringBeanFilter) -> [SpringBeanRow] {
        let words = filter.text.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        return rows.filter { row in
            if !words.allSatisfy({ row.haystack.contains($0) }) { return false }
            if !filter.stereotypes.isEmpty, row.stereotypes.isDisjoint(with: filter.stereotypes) { return false }
            if !filter.includeFactoryBeans, row.kindLabel == "@Bean" { return false }
            if !filter.modules.isEmpty, !(row.module.map(filter.modules.contains) ?? false) { return false }
            switch filter.conditional {
            case .any: break
            case .certain: if row.certainty != .certain { return false }
            case .conditional: if !row.certainty.isConditional { return false }
            case .inactive: if !row.certainty.isInactive { return false }
            }
            if filter.onlyProblems, !problemBeans.contains(row.id) { return false }
            return true
        }
    }

    public var modules: [String] { Array(Set(rows.compactMap(\.module))).sorted() }
}

/// Everything the Bean Inspector shows for one bean. Each part carries the location to open.
public struct SpringBeanInspection: Sendable {
    public struct Dependency: Hashable, Sendable {
        public enum Status: Hashable, Sendable {
            case verified, conditional, ambiguous, unresolved(String)
        }
        public let point: SpringInjectionPoint
        public let requiredType: String
        public let status: Status
        public let targets: [SpringBean]
    }
    public struct Consumer: Hashable, Sendable {
        public let ownerName: String
        public let point: SpringInjectionPoint
        /// False when the bean is one of several candidates (ambiguous or conditional), not the certain match.
        public let isCertain: Bool
    }
    public let bean: SpringBean
    public let origin: String
    public let conditions: [String]
    public let dependencies: [Dependency]
    public let consumers: [Consumer]
    /// The `@Configuration` class that declares this bean, or the bean's own class for a stereotype bean.
    public let configurationClass: String
    public let diagnostics: [SpringDiagnostic]

    public init?(bean id: SpringBeanID, in model: SpringModel) {
        guard let bean = model.bean(id) else { return nil }
        self.bean = bean
        switch bean.origin {
        case .stereotype(let a):
            origin = "Component class (@\(a.split(separator: ".").last.map(String.init) ?? a))"
            configurationClass = bean.type.name
        case .factoryMethod(let c, let m):
            origin = "@Bean method \(m)() of \(c.split(separator: ".").last.map(String.init) ?? c)"
            configurationClass = c
        }
        switch bean.certainty {
        case .certain: conditions = []
        case .conditional(let r): conditions = r
        case .inactive(let r): conditions = r
        }
        var deps: [Dependency] = []
        var cons: [Consumer] = []
        for point in model.injectionPoints(of: id) {
            let targets: [SpringBean]
            let status: Dependency.Status
            switch model.resolutions[point] {
            case .resolved(let b)?:
                targets = [model.bean(b)].compactMap { $0 }
                status = (targets.first?.certainty.isConditional ?? false) || bean.certainty.isConditional ? .conditional : .verified
            case .collection(let bs)?:
                targets = bs.compactMap(model.bean); status = .verified
            case .ambiguous(let bs)?:
                targets = bs.compactMap(model.bean); status = .ambiguous
            case .uncertain(let cs, let reason)?:
                targets = cs.compactMap(model.bean); status = cs.isEmpty ? .unresolved(reason) : .conditional
            case .missing?: targets = []; status = .unresolved("no bean of this type")
            case .unknownQualifier(let q)?: targets = []; status = .unresolved("no bean answers to qualifier '\(q)'")
            case nil: targets = []; status = .unresolved("not analysed")
            }
            deps.append(Dependency(point: point, requiredType: SpringModelBuilder.display(point.requiredType), status: status, targets: targets))
        }
        for point in model.consumers(of: id) {
            var isCertain = false
            if case .resolved(let b)? = model.resolutions[point], b == id { isCertain = true }
            cons.append(Consumer(ownerName: model.bean(point.owner)?.name ?? point.owner.raw, point: point, isCertain: isCertain))
        }
        dependencies = deps
        consumers = cons
        let pointLocations = Set(deps.map(\.point.location))
        var seen = Set<SpringDiagnostic>()
        diagnostics = model.diagnostics.filter {
            ($0.related.contains(id) || $0.location == bean.location || pointLocations.contains($0.location)) && seen.insert($0).inserted
        }
    }
}
