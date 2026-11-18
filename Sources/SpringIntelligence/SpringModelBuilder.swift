import Foundation
import JavaIntelligence

/// Which classes an application context registers. `.all` (no application class, or tests) registers every
/// stereotype class it is given; `.scan` follows Spring: a class is a bean only inside a scanned package or when
/// imported (`@Import`), so a class in a shared module that no scan reaches is not a bean of that application.
public enum SpringBeanScope: Sendable, Equatable {
    case all
    case scan(packages: Set<String>, imported: Set<String>)

    func admits(package: String, type: String) -> Bool {
        switch self {
        case .all: return true
        case .scan(let packages, let imported):
            return imported.contains(type) || packages.contains { package == $0 || package.hasPrefix($0 + ".") }
        }
    }
    func imports(_ type: String) -> Bool {
        if case .scan(_, let imported) = self { return imported.contains(type) }
        return false
    }
}

/// One immutable result of analysing the project's sources.
public struct SpringModel: Sendable {
    public let beans: [SpringBean]
    public let injectionPoints: [SpringInjectionPoint]
    public let resolutions: [SpringInjectionPoint: SpringResolution]
    public let diagnostics: [SpringDiagnostic]
    public let cycles: [SpringDependencyCycle]
    /// Classes that carry `@SpringBootApplication` (directly or composed).
    public let applications: [SpringApplicationEntry]
    /// Active beans assignable to each injection point's type, before any qualifier is applied.
    public let typeCandidates: [SpringInjectionPoint: [SpringBeanID]]
    /// Profile names written in `@Profile` annotations (without `!`).
    public let declaredProfiles: Set<String>
    /// Properties bound by the project's own `@ConfigurationProperties` classes (a source-derived stand-in for
    /// generated metadata, which only exists after a build).
    public let configurationProperties: [SpringPropertyMetadata]
    /// `@ConfigurationProperties` classes by prefix, for navigation between a prefix and its class.
    public let configurationPrefixes: [SpringConfigurationPrefix]
    /// `${placeholder}`s inside `@Value` annotations.
    public let valueReferences: [SpringValueReference]
    /// For an injection point with no candidate: project classes that implement its type but are not beans.
    public let unregistered: [SpringInjectionPoint: [SpringUnregisteredType]]
    /// Packages that `@ComponentScan` / `@SpringBootApplication` on registered configuration classes ask to scan, and
    /// classes their `@Import` names. A context grows its scope by feeding these back until nothing new appears.
    let discoveredScanPackages: Set<String>
    let discoveredImports: Set<String>
    /// `@ComponentScan`, `@Import` and `@ImportResource` on registered configuration classes, for the context graph.
    public let configurationLinks: [SpringConfigurationLink]
    private let beanIndex: [SpringBeanID: SpringBean]
    /// Injection points by owning bean and consumers by bean, built once so the inspector and the markers never scan every point.
    private let pointsByOwner: [SpringBeanID: [SpringInjectionPoint]]
    private let consumerIndex: [SpringBeanID: [SpringInjectionPoint]]

    init(beans: [SpringBean], injectionPoints: [SpringInjectionPoint], resolutions: [SpringInjectionPoint: SpringResolution],
         diagnostics: [SpringDiagnostic], cycles: [SpringDependencyCycle], applications: [SpringApplicationEntry],
         typeCandidates: [SpringInjectionPoint: [SpringBeanID]], declaredProfiles: Set<String>,
         configurationProperties: [SpringPropertyMetadata], configurationPrefixes: [SpringConfigurationPrefix],
         valueReferences: [SpringValueReference], unregistered: [SpringInjectionPoint: [SpringUnregisteredType]] = [:],
         discoveredScanPackages: Set<String> = [], discoveredImports: Set<String> = [],
         configurationLinks: [SpringConfigurationLink] = []) {
        self.configurationLinks = configurationLinks
        self.unregistered = unregistered
        self.discoveredScanPackages = discoveredScanPackages
        self.discoveredImports = discoveredImports
        self.beans = beans
        self.injectionPoints = injectionPoints
        self.resolutions = resolutions
        self.diagnostics = diagnostics
        self.cycles = cycles
        self.applications = applications
        self.typeCandidates = typeCandidates
        self.declaredProfiles = declaredProfiles
        self.configurationProperties = configurationProperties
        self.configurationPrefixes = configurationPrefixes
        self.valueReferences = valueReferences
        beanIndex = Dictionary(beans.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var owners: [SpringBeanID: [SpringInjectionPoint]] = [:]
        var consumers: [SpringBeanID: [SpringInjectionPoint]] = [:]
        for point in injectionPoints {
            owners[point.owner, default: []].append(point)
            let targets: [SpringBeanID]
            switch resolutions[point] {
            case .resolved(let b)?: targets = [b]
            case .collection(let bs)?, .ambiguous(let bs)?: targets = bs
            case .uncertain(let cs, _)?: targets = cs
            default: targets = []
            }
            for t in targets { consumers[t, default: []].append(point) }
        }
        pointsByOwner = owners
        consumerIndex = consumers
    }

    /// The injection points a bean declares (constructor, fields, methods, `@Bean` parameters).
    public func injectionPoints(of id: SpringBeanID) -> [SpringInjectionPoint] { pointsByOwner[id] ?? [] }

    public static let empty = SpringModel(beans: [], injectionPoints: [], resolutions: [:], diagnostics: [], cycles: [],
                                          applications: [], typeCandidates: [:], declaredProfiles: [],
                                          configurationProperties: [], configurationPrefixes: [], valueReferences: [])

    public func bean(_ id: SpringBeanID) -> SpringBean? { beanIndex[id] }
}

extension SpringModel {
    /// The injection point whose declared name covers `byteOffset` in `url`.
    public func injectionPoint(in url: URL, atByte byteOffset: Int) -> SpringInjectionPoint? {
        injectionPoints.first { $0.location.url == url && ($0.nameRange.contains(byteOffset) || $0.nameRange.upperBound == byteOffset) }
    }

    /// Points whose resolution is `id` (certainly or as one of several candidates).
    public func consumers(of id: SpringBeanID) -> [SpringInjectionPoint] { consumerIndex[id] ?? [] }

    /// The beans an injection point may be satisfied by (empty when none is known).
    public func candidates(for point: SpringInjectionPoint) -> [SpringBean] {
        let ids: [SpringBeanID]
        switch resolutions[point] {
        case .resolved(let b)?: ids = [b]
        case .collection(let bs)?, .ambiguous(let bs)?: ids = bs
        case .uncertain(let cs, _)?: ids = cs
        default: ids = []
        }
        return ids.compactMap(bean)
    }
}

public struct SpringConfigurationPrefix: Hashable, Sendable {
    public let prefix: String
    public let typeName: String
    public let location: SpringSourceLocation
}

public struct SpringValueReference: Hashable, Sendable {
    public let key: String
    public let hasDefault: Bool
    /// The whole `@Value(...)` annotation.
    public let location: SpringSourceLocation
}

public enum SpringPlaceholder {
    public struct Found: Hashable, Sendable { public let key: String; public let hasDefault: Bool; public let keyRange: Range<Int> }

    /// Simple (non-nested) `${key}` / `${key:default}` placeholders of `text`, with the key's UTF-16 range.
    public static func scan(_ text: String) -> [Found] {
        let chars = Array(text.utf16)
        var out: [Found] = []
        var i = 0
        while i + 1 < chars.count {
            if chars[i] == 0x24, chars[i + 1] == 0x7B {          // "${"
                var depth = 1, j = i + 2, colon: Int?
                while j < chars.count, depth > 0 {
                    if chars[j] == 0x7B { depth += 1 }
                    else if chars[j] == 0x7D { depth -= 1 }
                    else if chars[j] == 0x3A, depth == 1, colon == nil { colon = j }
                    j += 1
                }
                if depth == 0 {
                    let end = colon ?? (j - 1)
                    let key = String(decoding: chars[(i + 2)..<end], as: UTF16.self)
                    if !key.isEmpty, !key.contains("${"), !key.contains("#{") {
                        out.append(Found(key: key.trimmingCharacters(in: .whitespaces), hasDefault: colon != nil, keyRange: (i + 2)..<end))
                    }
                    i = j
                    continue
                }
            }
            i += 1
        }
        return out
    }
}

public struct SpringApplicationEntry: Hashable, Sendable {
    public let typeName: String
    public let location: SpringSourceLocation
}

/// Builds a ``SpringModel`` from per-file ``JavaFileDeclarations``. Pure: no I/O, no parsing.
///
/// Spring semantics that are deliberate simplifications, each documented where it applies:
/// - Library annotations are matched through ``SpringAnnotationRegistry``; unknown library
///   annotations imply nothing.
/// - Type matching is by erasure plus directly declared type arguments; arguments reached through
///   a chain of generic supertypes are treated as unknown (match), never as a mismatch.
/// - A missing candidate is reported only when the required type is declared in the project and no
///   `@Import`/`@ImportResource` could register something this model cannot see.
struct SpringModelBuilder {
    let files: [URL: JavaFileDeclarations]
    let activeProfiles: Set<String>?
    let scope: SpringBeanScope

    struct Context { let url: URL; let file: JavaFileDeclarations }

    /// The source files in a stable order, sorted once: comparing `URL.path` is costly and every build walks the files twice.
    private let sortedURLs: [URL]
    private(set) var typeIndex: [String: (type: JavaAnnotatedType, ctx: Context)] = [:]
    private var stereotypeMemo: [String: Set<SpringStereotype>] = [:]

    init(files: [URL: JavaFileDeclarations], activeProfiles: Set<String>?, scope: SpringBeanScope = .all) {
        self.files = files
        self.activeProfiles = activeProfiles
        self.scope = scope
        sortedURLs = files.keys.map { ($0.path, $0) }.sorted { $0.0 < $1.0 }.map(\.1)
        for (url, file) in files {
            for type in file.types { typeIndex[type.qualifiedName] = (type, Context(url: url, file: file)) }
        }
    }

    // MARK: Name resolution

    func qualifyAnnotation(_ name: String, _ ctx: Context) -> String {
        if name.contains(".") { return name }
        let f = ctx.file
        if let i = f.imports.first(where: { !$0.isStatic && !$0.isOnDemand && $0.qualifiedName.hasSuffix("." + name) }) {
            return i.qualifiedName
        }
        let samePackage = f.packageName.isEmpty ? name : f.packageName + "." + name
        if typeIndex[samePackage] != nil { return samePackage }
        for i in f.imports where i.isOnDemand && !i.isStatic {
            let candidate = i.qualifiedName + "." + name
            if SpringAnnotationRegistry.stereotypes[candidate] != nil || typeIndex[candidate] != nil
                || knownLibraryAnnotation(candidate) || SpringAnnotationRegistry.conditionalPrefix.hasPrefix(i.qualifiedName + ".")
                && name.hasPrefix("Conditional") { return candidate }
        }
        return name
    }

    private func knownLibraryAnnotation(_ q: String) -> Bool {
        SpringWebAnnotations.isSpringWeb(q) || SpringWebAnnotations.isConstraint(q) || SpringWebAnnotations.validAnnotations.contains(q) || [SpringAnnotationRegistry.beanMethod, SpringAnnotationRegistry.autowired, SpringAnnotationRegistry.qualifier,
         SpringAnnotationRegistry.primary, SpringAnnotationRegistry.lazy, SpringAnnotationRegistry.scope,
         SpringAnnotationRegistry.profile, SpringAnnotationRegistry.fallback, SpringAnnotationRegistry.conditional,
         SpringAnnotationRegistry.importAnnotation, SpringAnnotationRegistry.importResource,
         SpringAnnotationRegistry.value, SpringAnnotationRegistry.configurationProperties,
         SpringAnnotationRegistry.componentScan].contains(q)
            || (q.hasPrefix(SpringAnnotationRegistry.conditionalPrefix) && q.dropFirst(SpringAnnotationRegistry.conditionalPrefix.count - "Conditional".count).hasPrefix("Conditional"))
    }

    func resolve(_ ref: JavaTypeRef, _ ctx: Context, enclosing: String?) -> SpringType {
        switch ref {
        case .primitive(let p): return SpringType(name: p.rawValue, isResolved: true, arguments: [])
        case .void: return SpringType(name: "void", isResolved: true, arguments: [])
        case .array(let e):
            let inner = resolve(e, ctx, enclosing: enclosing)
            return SpringType(name: inner.name + "[]", isResolved: inner.isResolved, arguments: [inner])
        case .classType(let q, let args, _):
            return SpringType(name: q, isResolved: true, arguments: args.map { resolveArgument($0, ctx, enclosing: enclosing) })
        case .unresolved(let simple, let args):
            let arguments = args.map { resolveArgument($0, ctx, enclosing: enclosing) }
            if let q = qualifySimple(simple, ctx, enclosing: enclosing) {
                return SpringType(name: q, isResolved: true, arguments: arguments)
            }
            return SpringType(name: simple, isResolved: false, arguments: arguments)
        case .typeVariable(let n): return SpringType(name: n, isResolved: false, arguments: [])
        case .wildcard: return SpringType(name: "?", isResolved: false, arguments: [])
        }
    }

    private func resolveArgument(_ arg: JavaTypeArgument, _ ctx: Context, enclosing: String?) -> SpringType {
        switch arg {
        case .type(let t): return resolve(t, ctx, enclosing: enclosing)
        case .wildcard: return SpringType(name: "?", isResolved: false, arguments: [])
        }
    }

    private func qualifySimple(_ simple: String, _ ctx: Context, enclosing: String?) -> String? {
        if simple.contains(".") {
            // `Outer.Inner` written with a project outer, or a package-qualified name.
            if typeIndex[simple] != nil { return simple }
            let head = String(simple.split(separator: ".")[0])
            if let q = qualifySimple(head, ctx, enclosing: enclosing) { return q + simple.dropFirst(head.count) }
            return simple
        }
        var outer = enclosing
        while let o = outer {
            if typeIndex["\(o).\(simple)"] != nil { return "\(o).\(simple)" }
            outer = o.contains(".") ? String(o[..<o.lastIndex(of: ".")!]) : nil
        }
        let f = ctx.file
        if let i = f.imports.first(where: { !$0.isStatic && !$0.isOnDemand && $0.qualifiedName.hasSuffix("." + simple) }) {
            return i.qualifiedName
        }
        let samePackage = f.packageName.isEmpty ? simple : f.packageName + "." + simple
        if typeIndex[samePackage] != nil { return samePackage }
        for i in f.imports where i.isOnDemand && !i.isStatic && typeIndex[i.qualifiedName + "." + simple] != nil {
            return i.qualifiedName + "." + simple
        }
        if SpringAnnotationRegistry.javaUtil.contains(simple),
           f.imports.contains(where: { $0.isOnDemand && !$0.isStatic && $0.qualifiedName == "java.util" }) {
            return "java.util." + simple
        }
        if SpringAnnotationRegistry.javaLang.contains(simple) { return "java.lang." + simple }
        return nil
    }

    // MARK: Stereotypes (meta-annotations)

    /// Read-only form of ``stereotypes(ofAnnotation:visiting:)`` for non-mutating callers (no memo).
    private func stereotypes(ofAnnotationNoMutation qualified: String, visiting: Set<String> = []) -> Set<SpringStereotype> {
        if let known = SpringAnnotationRegistry.stereotypes[qualified] { return known }
        guard !visiting.contains(qualified), let entry = typeIndex[qualified], entry.type.kind == .annotationKind else { return [] }
        var result: Set<SpringStereotype> = []
        for meta in entry.type.annotations {
            result.formUnion(stereotypes(ofAnnotationNoMutation: qualifyAnnotation(meta.name, entry.ctx), visiting: visiting.union([qualified])))
        }
        return result
    }

    private mutating func stereotypes(ofAnnotation qualified: String, visiting: Set<String> = []) -> Set<SpringStereotype> {
        if let known = SpringAnnotationRegistry.stereotypes[qualified] { return known }
        if let memo = stereotypeMemo[qualified] { return memo }
        guard !visiting.contains(qualified), let entry = typeIndex[qualified], entry.type.kind == .annotationKind else { return [] }
        var result: Set<SpringStereotype> = []
        for meta in entry.type.annotations {
            result.formUnion(stereotypes(ofAnnotation: qualifyAnnotation(meta.name, entry.ctx), visiting: visiting.union([qualified])))
        }
        stereotypeMemo[qualified] = result
        return result
    }

    /// The first annotation on `annotations` that yields stereotypes, with them.
    private mutating func stereotypeAnnotation(
        _ annotations: [JavaAnnotationUse], _ ctx: Context
    ) -> (annotation: JavaAnnotationUse, qualified: String, stereotypes: Set<SpringStereotype>)? {
        for a in annotations {
            let q = qualifyAnnotation(a.name, ctx)
            let s = stereotypes(ofAnnotation: q)
            if !s.isEmpty { return (a, q, s) }
        }
        return nil
    }

    // MARK: Conditions

    private mutating func certainty(of annotations: [JavaAnnotationUse], _ ctx: Context) -> SpringCertainty {
        var conditional: [String] = []
        var inactive: [String] = []
        for a in annotations {
            let q = qualifyAnnotation(a.name, ctx)
            if q == SpringAnnotationRegistry.profile {
                let expressions = a["value"]?.strings ?? []
                guard let active = activeProfiles else {
                    conditional.append("@Profile(\(expressions.joined(separator: ", "))): active profiles unknown")
                    continue
                }
                if !expressions.contains(where: { Self.profileMatches($0, active) }) {
                    inactive.append("@Profile(\(expressions.joined(separator: ", "))) does not match active profiles \(active.sorted())")
                }
            } else if q == SpringAnnotationRegistry.conditional {
                conditional.append("@Conditional: custom condition cannot be evaluated statically")
            } else if q.hasPrefix(SpringAnnotationRegistry.conditionalPrefix) {
                conditional.append("@\(a.simpleName): evaluated at startup")
            }
        }
        if !inactive.isEmpty { return .inactive(reasons: inactive) }
        return conditional.isEmpty ? .certain : .conditional(reasons: conditional)
    }

    /// `"a"`, `"!a"`; compound `a & b` / `a | b` expressions are evaluated left to right with Spring's
    /// operators (`&`, `|`, `!`, parentheses unsupported → treated as matching, i.e. never wrongly inactive).
    static func profileMatches(_ expression: String, _ active: Set<String>) -> Bool {
        let e = expression.trimmingCharacters(in: .whitespaces)
        if e.contains("(") { return true }
        if e.contains("|") { return e.split(separator: "|").contains { profileMatches(String($0), active) } }
        if e.contains("&") { return e.split(separator: "&").allSatisfy { profileMatches(String($0), active) } }
        if e.hasPrefix("!") { return !active.contains(String(e.dropFirst()).trimmingCharacters(in: .whitespaces)) }
        return active.contains(e)
    }

    // MARK: Application entry points

    /// The `@SpringBootApplication` classes (direct or composed), found without building a model: one pass over the
    /// annotations, which is all `contexts()` needs to decide how many applications there are.
    mutating func findApplications() -> [SpringApplicationEntry] {
        var found: [SpringApplicationEntry] = []
        for url in sortedURLs {
            guard let file = files[url] else { continue }
            let ctx = Context(url: url, file: file)
            for type in file.types where type.kind == .classKind && !type.annotations.isEmpty {
                if let (_, _, kinds) = stereotypeAnnotation(type.annotations, ctx), kinds.contains(.springBootApplication) {
                    found.append(SpringApplicationEntry(typeName: type.qualifiedName, location: SpringSourceLocation(url: url, byteRange: type.nameRange)))
                }
            }
        }
        return found
    }

    // MARK: Build

    mutating func build() -> SpringModel {
        var beans: [SpringBean] = []
        var points: [SpringInjectionPoint] = []
        var applications: [SpringApplicationEntry] = []
        var opaqueRegistration = false
        var profiles = Set<String>()
        var scanPackages = Set<String>(), importedTypes = Set<String>()
        var links: [SpringConfigurationLink] = []

        for url in sortedURLs {
            guard let file = files[url] else { continue }
            let ctx = Context(url: url, file: file)
            for type in file.types {
                // Outside every scanned package and not imported: Spring never sees this class in this application,
                // so nothing about it (not even its profiles) is read.
                guard scope.admits(package: file.packageName, type: type.qualifiedName) else { continue }
                for a in type.annotations + type.methods.flatMap(\.annotations) {
                    let q = qualifyAnnotation(a.name, ctx)
                    if q == SpringAnnotationRegistry.profile {
                        for e in a["value"]?.strings ?? [] {
                            for part in e.split(whereSeparator: { "&|()! ".contains($0) }) { profiles.insert(String(part)) }
                        }
                    }
                    if q == SpringAnnotationRegistry.importResource { opaqueRegistration = true }
                }
                var stereotype = stereotypeAnnotation(type.annotations, ctx)
                if stereotype == nil, scope.imports(type.qualifiedName), type.kind == .classKind {
                    // `@Import(Plain.class)` registers a class that carries no stereotype at all.
                    stereotype = (JavaAnnotationUse(name: "Import", arguments: [:], byteRange: 0..<0),
                                  SpringAnnotationRegistry.importAnnotation, [.component])
                }
                guard let (sa, saName, kinds) = stereotype,
                      type.kind != .annotationKind, type.kind != .interfaceKind,
                      !type.modifiers.contains(.abstractFlag) else {
                    continue
                }
                if kinds.contains(.configuration) || scope.imports(type.qualifiedName) {
                    let at = SpringSourceLocation(url: url, byteRange: type.nameRange)
                    for request in scanRequests(of: type, ctx: ctx) {
                        scanPackages.insert(request)
                        links.append(SpringConfigurationLink(from: type.qualifiedName, kind: .scan(package: request), location: at))
                    }
                    var opaqueHere = false
                    for imported in importRequests(of: type, ctx: ctx, opaque: &opaqueHere) {
                        importedTypes.insert(imported)
                        links.append(SpringConfigurationLink(from: type.qualifiedName, kind: .importClass(target: imported, resolved: true), location: at))
                    }
                    if opaqueHere {
                        opaqueRegistration = true
                        links.append(SpringConfigurationLink(from: type.qualifiedName, kind: .importClass(target: "library or unresolved configuration", resolved: false), location: at))
                    }
                    for a in type.annotations where qualifyAnnotation(a.name, ctx) == SpringAnnotationRegistry.importResource {
                        links.append(SpringConfigurationLink(from: type.qualifiedName, kind: .importResource(locations: a["value"]?.strings ?? a["locations"]?.strings ?? []), location: at))
                    }
                }
                let classCertainty = certainty(of: type.annotations, ctx)
                let id = SpringBeanID(raw: "type:" + type.qualifiedName)
                let bean = makeBean(
                    id: id, defaultName: Self.defaultBeanName(type.qualifiedName, package: file.packageName),
                    explicit: sa.arguments["value"]?.strings.first, aliases: [],
                    type: SpringType(name: type.qualifiedName, isResolved: true, arguments: []),
                    annotations: type.annotations, ctx: ctx, origin: .stereotype(annotation: saName),
                    certainty: classCertainty, location: SpringSourceLocation(url: url, byteRange: type.nameRange),
                    declarationStart: type.declarationStart, stereotypes: kinds)
                beans.append(bean)
                if kinds.contains(.springBootApplication) {
                    applications.append(SpringApplicationEntry(typeName: type.qualifiedName, location: bean.location))
                }
                points += classInjectionPoints(type, ctx: ctx, owner: id, location: bean.location)

                do {  // @Bean methods also work in plain components ("lite" mode)
                    for m in type.methods where !m.isConstructor {
                        guard let bm = m.annotations.first(where: { qualifyAnnotation($0.name, ctx) == SpringAnnotationRegistry.beanMethod }) else { continue }
                        let names = (bm.arguments["name"] ?? bm.arguments["value"])?.strings ?? []
                        let beanName = names.first ?? m.name
                        let mid = SpringBeanID(raw: "method:\(type.qualifiedName)#\(m.name)(\(m.parameters.map { resolve($0.type, ctx, enclosing: type.qualifiedName).name }.joined(separator: ",")))")
                        let loc = SpringSourceLocation(url: url, byteRange: m.nameRange)
                        let combined = mergeCertainty(classCertainty, certainty(of: m.annotations, ctx))
                        beans.append(makeBean(
                            id: mid, defaultName: m.name, explicit: beanName == m.name ? nil : beanName,
                            aliases: Array(names.dropFirst()),
                            type: resolve(m.returnType, ctx, enclosing: type.qualifiedName),
                            annotations: m.annotations, ctx: ctx,
                            origin: .factoryMethod(configuration: type.qualifiedName, method: m.name),
                            certainty: combined, location: loc, declarationStart: m.declarationStart, stereotypes: []))
                        for p in m.parameters {
                            points.append(injectionPoint(
                                owner: mid, kind: .factoryParameter, name: p.name, type: p.type,
                                annotations: p.annotations,
                                ctx: ctx, enclosing: type.qualifiedName,
                                location: SpringSourceLocation(url: url, byteRange: p.byteRange),
                                nameRange: p.nameRange, insertAt: p.byteRange.lowerBound))
                        }
                    }
                }
            }
        }

        var configProps: [SpringPropertyMetadata] = []
        var prefixes: [SpringConfigurationPrefix] = []
        var valueRefs: [SpringValueReference] = []
        var configDiagnostics: [SpringDiagnostic] = []
        collectConfiguration(properties: &configProps, prefixes: &prefixes, values: &valueRefs, diagnostics: &configDiagnostics)

        var resolutions: [SpringInjectionPoint: SpringResolution] = [:]
        var diagnostics: [SpringDiagnostic] = configDiagnostics
        let closure = SupertypeClosure(builder: self)
        var pools: [SpringInjectionPoint: [SpringBeanID]] = [:]
        // Active beans by every supertype name, so an injection point looks up its candidates instead of
        // testing every bean (the first version was quadratic: 1.2 s to rebuild 1,500 beans).
        let byID = Dictionary(beans.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let supertypeIndex = closure.supertypeIndex(beans)
        let knownNames = Set(beans.flatMap { [$0.name] + $0.aliases + $0.qualifiers })
        for p in points {
            let assignable = p.requiredType.isResolved ? closure.candidates(for: p.requiredType, index: supertypeIndex, all: beans) : []
            pools[p] = assignable.map(\.id)
            let r = resolve(point: p, assignable: assignable, knownNames: knownNames, closure: closure, opaque: opaqueRegistration)
            resolutions[p] = r
            if let d = diagnostic(for: p, r, byID: byID) { diagnostics.append(d) }
        }
        var unregistered: [SpringInjectionPoint: [SpringUnregisteredType]] = [:]
        let beanTypeNames = Set(beans.map(\.type.name))
        for p in points where resolutions[p] == .missing {
            var found: [SpringUnregisteredType] = []
            for (name, entry) in typeIndex.sorted(by: { $0.key < $1.key }) where found.count < 5 {
                guard entry.type.kind == .classKind, !entry.type.modifiers.contains(.abstractFlag), !beanTypeNames.contains(name),
                      name == p.requiredType.name || closure.isSubtype(name, of: p.requiredType.name) else { continue }
                found.append(SpringUnregisteredType(
                    typeName: name, location: SpringSourceLocation(url: entry.ctx.url, byteRange: entry.type.nameRange),
                    declarationStart: entry.type.declarationStart))
            }
            if !found.isEmpty { unregistered[p] = found }
        }
        diagnostics += duplicateNameDiagnostics(beans)
        let cycles = findCycles(points: points, resolutions: resolutions, beans: beans)
        for c in cycles {
            if let first = c.beans.first.flatMap({ byID[$0] }) {
                let names = c.beans.compactMap { byID[$0]?.name }
                diagnostics.append(SpringDiagnostic(
                    severity: c.strength == .proven ? .error : .warning, code: "spring.circular-dependency",
                    message: c.strength == .proven
                        ? "Circular constructor dependency: \(names.joined(separator: " → ")) → \(names[0])"
                        : "Circular dependency: \(names.joined(separator: " → ")) → \(names[0]) (rejected by Spring Boot 2.6+ unless spring.main.allow-circular-references=true)",
                    location: first.location, related: c.beans))
            }
        }
        return SpringModel(beans: beans, injectionPoints: points, resolutions: resolutions,
                           diagnostics: diagnostics, cycles: cycles, applications: applications,
                           typeCandidates: pools, declaredProfiles: profiles,
                           configurationProperties: configProps, configurationPrefixes: prefixes, valueReferences: valueRefs,
                           unregistered: unregistered, discoveredScanPackages: scanPackages, discoveredImports: importedTypes,
                           configurationLinks: links)
    }

    // MARK: Component scan and imports

    /// Packages a configuration class asks Spring to scan: `@ComponentScan` and `@SpringBootApplication`, by
    /// `basePackages`/`value`/`scanBasePackages`, by `basePackageClasses`, or (with none of those) the class's own package.
    private func scanRequests(of type: JavaAnnotatedType, ctx: Context) -> [String] {
        var out: [String] = []
        for a in type.annotations {
            let q = qualifyAnnotation(a.name, ctx)
            let isBoot = SpringAnnotationRegistry.stereotypes[q]?.contains(.springBootApplication) == true
                || stereotypes(ofAnnotationNoMutation: q).contains(.springBootApplication)
            guard isBoot || q == SpringAnnotationRegistry.componentScan else { continue }
            var packages: [String] = []
            for key in ["basePackages", "scanBasePackages", "value"] { packages += a[key]?.strings ?? [] }
            for key in ["basePackageClasses", "scanBasePackageClasses"] {
                for literal in a[key]?.classLiterals ?? [] {
                    if let qualified = qualifySimple(literal, ctx, enclosing: type.qualifiedName), let dot = qualified.lastIndex(of: ".") {
                        packages.append(String(qualified[..<dot]))
                    }
                }
            }
            out += packages.isEmpty ? [ctx.file.packageName] : packages
        }
        return out
    }

    /// Classes `@Import` names. A class that is not in the project's sources (a library configuration) cannot be
    /// followed, so the model is marked opaque rather than claiming nothing else registers.
    private func importRequests(of type: JavaAnnotatedType, ctx: Context, opaque: inout Bool) -> [String] {
        var out: [String] = []
        for a in type.annotations where qualifyAnnotation(a.name, ctx) == SpringAnnotationRegistry.importAnnotation {
            let literals = a["value"]?.classLiterals ?? []
            if literals.isEmpty { opaque = true }
            for literal in literals {
                if let qualified = qualifySimple(literal, ctx, enclosing: type.qualifiedName), typeIndex[qualified] != nil { out.append(qualified) }
                else { opaque = true }
            }
        }
        return out
    }

    // MARK: Configuration (`@ConfigurationProperties`, `@Value`)

    private func collectConfiguration(
        properties: inout [SpringPropertyMetadata], prefixes: inout [SpringConfigurationPrefix],
        values: inout [SpringValueReference], diagnostics: inout [SpringDiagnostic]
    ) {
        for url in sortedURLs {
            guard let file = files[url] else { continue }
            let ctx = Context(url: url, file: file)
            for type in file.types where scope.admits(package: file.packageName, type: type.qualifiedName) {
                let location = SpringSourceLocation(url: url, byteRange: type.nameRange)
                if let a = type.annotations.first(where: { qualifyAnnotation($0.name, ctx) == SpringAnnotationRegistry.configurationProperties }) {
                    let prefix = (a["prefix"] ?? a["value"])?.strings.first ?? ""
                    if !prefix.isEmpty {
                        prefixes.append(SpringConfigurationPrefix(prefix: prefix, typeName: type.qualifiedName, location: location))
                        if !Self.isCanonicalPrefix(prefix) {
                            diagnostics.append(SpringDiagnostic(
                                severity: .error, code: "spring.config.invalid-prefix",
                                message: "Configuration property name '\(prefix)' is not valid: use lower-case, dash-separated names (Spring Boot fails at startup)",
                                location: SpringSourceLocation(url: url, byteRange: a.byteRange), related: []))
                        }
                    }
                    bind(type, prefix: prefix, ctx: ctx, depth: 0, visiting: [type.qualifiedName], into: &properties)
                }
                for f in type.fields { scanValues(f.annotations, ctx, &values) }
                for m in type.methods {
                    scanValues(m.annotations, ctx, &values)
                    for p in m.parameters { scanValues(p.annotations, ctx, &values) }
                }
            }
        }
    }

    static func isCanonicalPrefix(_ prefix: String) -> Bool {
        prefix.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { seg in
            !seg.isEmpty && seg.allSatisfy { ($0.isLowercase && $0.isASCII) || $0.isNumber || $0 == "-" } && seg.first != "-" && seg.last != "-"
        }
    }

    private func scanValues(_ annotations: [JavaAnnotationUse], _ ctx: Context, _ out: inout [SpringValueReference]) {
        for a in annotations where qualifyAnnotation(a.name, ctx) == SpringAnnotationRegistry.value {
            for string in a["value"]?.strings ?? [] {
                for p in SpringPlaceholder.scan(string) {
                    out.append(SpringValueReference(
                        key: p.key, hasDefault: p.hasDefault, location: SpringSourceLocation(url: ctx.url, byteRange: a.byteRange)))
                }
            }
        }
    }

    private func bind(
        _ type: JavaAnnotatedType, prefix: String, ctx: Context, depth: Int, visiting: Set<String>,
        into out: inout [SpringPropertyMetadata]
    ) {
        for f in type.fields where !f.modifiers.contains(.staticFlag) {
            let name = SpringConfigMetadata.canonicalSegment(f.name)
            let full = prefix.isEmpty ? name : prefix + "." + name
            let resolved = resolve(f.type, ctx, enclosing: type.qualifiedName)
            if depth < 6, let nested = typeIndex[resolved.name], !visiting.contains(nested.type.qualifiedName),
               nested.type.kind == .classKind || nested.type.kind == .recordKind {
                bind(nested.type, prefix: full, ctx: nested.ctx, depth: depth + 1, visiting: visiting.union([nested.type.qualifiedName]), into: &out)
                continue
            }
            let deprecated = f.annotations.contains { $0.simpleName == "Deprecated" }
            out.append(SpringPropertyMetadata(
                name: full, type: Self.display(resolved), description: nil, defaultValue: nil,
                deprecation: deprecated ? SpringDeprecation(level: .warning, reason: nil, replacement: nil) : nil,
                origin: .source(SpringSourceLocation(url: ctx.url, byteRange: f.nameRange), className: type.qualifiedName)))
        }
    }

    static func display(_ t: SpringType) -> String {
        t.arguments.isEmpty || t.name.hasSuffix("[]") ? t.name : "\(t.name)<\(t.arguments.map(display).joined(separator: ","))>"
    }

    private func mergeCertainty(_ a: SpringCertainty, _ b: SpringCertainty) -> SpringCertainty {
        switch (a, b) {
        case (.inactive(let x), .inactive(let y)): return .inactive(reasons: x + y)
        case (.inactive(let x), _), (_, .inactive(let x)): return .inactive(reasons: x)
        case (.conditional(let x), .conditional(let y)): return .conditional(reasons: x + y)
        case (.conditional(let x), _), (_, .conditional(let x)): return .conditional(reasons: x)
        default: return .certain
        }
    }

    /// `AnnotationBeanNameGenerator`: the short class name (`Outer.Inner` keeps its dot) with
    /// `Introspector.decapitalize` applied (unchanged when the first two letters are upper case).
    static func defaultBeanName(_ qualified: String, package: String) -> String {
        var short = qualified
        if !package.isEmpty, qualified.hasPrefix(package + ".") { short = String(qualified.dropFirst(package.count + 1)) }
        let chars = Array(short)
        guard let first = chars.first else { return short }
        if chars.count > 1, chars[0].isUppercase, chars[1].isUppercase { return short }
        return first.lowercased() + String(chars.dropFirst())
    }

    private mutating func makeBean(
        id: SpringBeanID, defaultName: String, explicit: String?, aliases: [String], type: SpringType,
        annotations: [JavaAnnotationUse], ctx: Context, origin: SpringBeanOrigin,
        certainty: SpringCertainty, location: SpringSourceLocation, declarationStart: Int, stereotypes: Set<SpringStereotype>
    ) -> SpringBean {
        var qualifiers: [String] = []
        var primary = false, fallback = false, lazy = false
        var scope = "singleton"
        for a in annotations {
            let q = qualifyAnnotation(a.name, ctx)
            switch q {
            case SpringAnnotationRegistry.qualifier: if let v = a["value"]?.strings.first { qualifiers.append(v) }
            case SpringAnnotationRegistry.primary: primary = true
            case SpringAnnotationRegistry.fallback: fallback = true
            case SpringAnnotationRegistry.lazy: lazy = (a["value"]?.scalarText ?? "true") != "false"
            case SpringAnnotationRegistry.scope: if let v = (a["value"] ?? a["scopeName"])?.scalarText { scope = v }
            default: if SpringAnnotationRegistry.namedNames.contains(q), let v = a["value"]?.strings.first { qualifiers.append(v) }
            }
        }
        return SpringBean(id: id, name: explicit ?? defaultName, aliases: aliases, type: type, qualifiers: qualifiers,
                          isPrimary: primary, isFallback: fallback, scope: scope, origin: origin,
                          certainty: certainty, location: location, isLazy: lazy, declarationStart: declarationStart, stereotypes: stereotypes)
    }

    // MARK: Injection points

    private mutating func classInjectionPoints(
        _ type: JavaAnnotatedType, ctx: Context, owner: SpringBeanID, location: SpringSourceLocation
    ) -> [SpringInjectionPoint] {
        var points: [SpringInjectionPoint] = []
        let ctors = type.methods.filter(\.isConstructor)
        let annotated = ctors.filter { isInjectAnnotated($0.annotations, ctx) }
        // Spring picks the one @Autowired constructor, else the only constructor. Several
        // constructors and no marker means the default constructor is used: nothing is injected.
        let chosen = annotated.first ?? (ctors.count == 1 ? ctors[0] : nil)
        if let c = chosen {
            for p in c.parameters {
                points.append(injectionPoint(
                    owner: owner, kind: .constructor, name: p.name, type: p.type,
                    annotations: p.annotations + c.annotations.filter { qualifyAnnotation($0.name, ctx) == SpringAnnotationRegistry.lazy },
                    ctx: ctx, enclosing: type.qualifiedName,
                    location: SpringSourceLocation(url: ctx.url, byteRange: p.byteRange), nameRange: p.nameRange,
                    insertAt: p.byteRange.lowerBound))
            }
        } else if type.kind == .recordKind, ctors.isEmpty {
            for f in type.fields {
                points.append(injectionPoint(
                    owner: owner, kind: .constructor, name: f.name, type: f.type, annotations: f.annotations,
                    ctx: ctx, enclosing: type.qualifiedName,
                    location: SpringSourceLocation(url: ctx.url, byteRange: f.nameRange), nameRange: f.nameRange,
                    insertAt: f.declarationStart))
            }
        }
        for f in type.fields where !f.modifiers.contains(.staticFlag) && isInjectAnnotated(f.annotations, ctx) && type.kind != .recordKind {
            points.append(injectionPoint(
                owner: owner, kind: .field, name: f.name, type: f.type, annotations: f.annotations, ctx: ctx,
                enclosing: type.qualifiedName, location: SpringSourceLocation(url: ctx.url, byteRange: f.nameRange),
                nameRange: f.nameRange, insertAt: f.declarationStart))
        }
        for m in type.methods where !m.isConstructor && isInjectAnnotated(m.annotations, ctx) {
            for p in m.parameters {
                points.append(injectionPoint(
                    owner: owner, kind: .method, name: p.name, type: p.type, annotations: p.annotations + m.annotations,
                    ctx: ctx, enclosing: type.qualifiedName,
                    location: SpringSourceLocation(url: ctx.url, byteRange: p.byteRange), nameRange: p.nameRange,
                    insertAt: p.byteRange.lowerBound))
            }
        }
        return points
    }

    private mutating func isInjectAnnotated(_ annotations: [JavaAnnotationUse], _ ctx: Context) -> Bool {
        annotations.contains {
            let q = qualifyAnnotation($0.name, ctx)
            return q == SpringAnnotationRegistry.autowired || SpringAnnotationRegistry.injectNames.contains(q)
                || SpringAnnotationRegistry.resourceNames.contains(q)
        }
    }

    private mutating func injectionPoint(
        owner: SpringBeanID, kind: SpringInjectionKind, name: String, type ref: JavaTypeRef,
        annotations: [JavaAnnotationUse], ctx: Context, enclosing: String, location: SpringSourceLocation,
        nameRange: Range<Int>, insertAt: Int
    ) -> SpringInjectionPoint {
        var type = resolve(ref, ctx, enclosing: enclosing)
        var shape = SpringInjectionShape.single
        var deferred = false
        var required = true
        var qualifier: String?
        var qualifierRange: Range<Int>?
        for a in annotations {
            let q = qualifyAnnotation(a.name, ctx)
            if q == SpringAnnotationRegistry.qualifier || SpringAnnotationRegistry.namedNames.contains(q) {
                qualifier = a["value"]?.strings.first
                qualifierRange = a.byteRange
            } else if SpringAnnotationRegistry.resourceNames.contains(q) {
                qualifier = a["name"]?.strings.first ?? name   // @Resource resolves by name first
            } else if q == SpringAnnotationRegistry.autowired, a["required"]?.scalarText == "false" {
                required = false
            } else if q == SpringAnnotationRegistry.lazy {
                deferred = true
            } else if a.simpleName == "Nullable" {
                required = false
            }
        }
        // Unwrap Optional / ObjectProvider / Provider, then collections.
        if SpringAnnotationRegistry.deferredWrappers.contains(type.name), let inner = type.arguments.first {
            if type.name == "java.util.Optional" { required = false }
            type = inner
            deferred = true
        }
        if type.name.hasSuffix("[]"), let element = type.arguments.first {
            type = element; shape = .collection
        } else if SpringAnnotationRegistry.collectionTypes.contains(type.name), let element = type.arguments.first {
            type = element; shape = .collection
        } else if type.name == "java.util.Map", type.arguments.count == 2 {
            type = type.arguments[1]; shape = .collection
        }
        return SpringInjectionPoint(owner: owner, kind: kind, name: name, requiredType: type, shape: shape,
                                    qualifier: qualifier, isRequired: required, isDeferred: deferred, location: location,
                                    nameRange: nameRange, qualifierRange: qualifierRange, annotationInsertOffset: insertAt)
    }

    // MARK: Resolution

    /// Spring's `DefaultListableBeanFactory.determineAutowireCandidate` order: `@Primary`, then
    /// `@Fallback` filtering, then the injection point's own name against bean names.
    private func resolve(point p: SpringInjectionPoint, assignable: [SpringBean], knownNames: Set<String>, closure: SupertypeClosure, opaque: Bool) -> SpringResolution {
        if !p.requiredType.isResolved {
            return .uncertain(candidates: [], reason: "type \(p.requiredType.name) could not be resolved")
        }
        var candidates = assignable
        if let q = p.qualifier {
            let matching = candidates.filter { $0.qualifiers.contains(q) || $0.name == q || $0.aliases.contains(q) }
            if matching.isEmpty {
                let anyBeanNamed = knownNames.contains(q)
                if !anyBeanNamed && !opaque && p.requiredType.isResolved && closure.isProjectType(p.requiredType) {
                    return .unknownQualifier(q)
                }
                return candidates.isEmpty ? uncertainOrMissing(p, closure, opaque) : .uncertain(candidates: candidates.map(\.id), reason: "qualifier '\(q)' matches no candidate")
            }
            candidates = matching
        }
        if p.shape == .collection { return .collection(candidates.map(\.id)) }
        let certain = candidates.filter { $0.certainty == .certain }
        let conditional = candidates.filter { $0.certainty.isConditional }
        if candidates.isEmpty { return uncertainOrMissing(p, closure, opaque) }
        if certain.count == 1, conditional.isEmpty { return .resolved(certain[0].id) }
        if !conditional.isEmpty && certain.isEmpty {
            return .uncertain(candidates: candidates.map(\.id), reason: "only conditionally registered beans match")
        }
        // Several candidates: primary → fallback exclusion → parameter name.
        var pool = candidates
        let primaries = pool.filter(\.isPrimary)
        if primaries.count == 1 { return .resolved(primaries[0].id) }
        if primaries.count > 1 { pool = primaries }
        let nonFallback = pool.filter { !$0.isFallback }
        if nonFallback.count == 1 { return .resolved(nonFallback[0].id) }
        if !nonFallback.isEmpty { pool = nonFallback }
        let byName = pool.filter { $0.name == p.name || $0.aliases.contains(p.name) }
        if byName.count == 1 { return .resolved(byName[0].id) }
        if !conditional.isEmpty { return .uncertain(candidates: candidates.map(\.id), reason: "multiple candidates, some conditional") }
        return .ambiguous(pool.map(\.id))
    }

    private func uncertainOrMissing(_ p: SpringInjectionPoint, _ closure: SupertypeClosure, _ opaque: Bool) -> SpringResolution {
        if !p.requiredType.isResolved { return .uncertain(candidates: [], reason: "type \(p.requiredType.name) could not be resolved") }
        if !closure.isProjectType(p.requiredType) {
            return .uncertain(candidates: [], reason: "\(p.requiredType.simpleName) is a library type; it may come from auto-configuration")
        }
        if opaque { return .uncertain(candidates: [], reason: "@Import or @ImportResource may register it") }
        return .missing
    }

    private func diagnostic(for p: SpringInjectionPoint, _ r: SpringResolution, byID: [SpringBeanID: SpringBean]) -> SpringDiagnostic? {
        let t = p.requiredType.simpleName
        switch r {
        case .missing where p.isRequired && p.shape == .single:
            return SpringDiagnostic(severity: .error, code: "spring.no-candidate",
                message: "No matching bean candidate for \(t)", location: p.location, related: [])
        case .ambiguous(let ids):
            let names = ids.compactMap { byID[$0]?.name }
            return SpringDiagnostic(severity: .error, code: "spring.ambiguous-candidates",
                message: "Multiple candidates for \(t): \(names.joined(separator: ", ")). Add @Primary or a @Qualifier.",
                location: p.location, related: ids)
        case .unknownQualifier(let q):
            return SpringDiagnostic(severity: .error, code: "spring.unknown-qualifier",
                message: "No bean answers to qualifier '\(q)'", location: p.location, related: [])
        case .uncertain(let c, let reason) where p.isRequired && p.shape == .single && !c.isEmpty:
            return SpringDiagnostic(severity: .info, code: "spring.conditional-candidate",
                message: "\(t) depends on conditional registration: \(reason)", location: p.location, related: c)
        default:
            return nil
        }
    }

    private func duplicateNameDiagnostics(_ beans: [SpringBean]) -> [SpringDiagnostic] {
        var byName: [String: [SpringBean]] = [:]
        for b in beans where !b.certainty.isInactive { byName[b.name, default: []].append(b) }
        var out: [SpringDiagnostic] = []
        for (name, group) in byName where group.count > 1 {
            // Two @Bean methods of one class with the same name are overloads Spring picks between; skip.
            let stereotypes = group.filter { if case .stereotype = $0.origin { return true } else { return false } }
            guard stereotypes.count > 1 || (stereotypes.count == 1 && group.count > 1) else { continue }
            let conditional = group.contains { $0.certainty.isConditional }
            for b in group {
                out.append(SpringDiagnostic(
                    severity: conditional ? .warning : .error, code: "spring.duplicate-bean-name",
                    message: "Bean name '\(name)' is declared \(group.count) times" + (conditional ? " (some conditionally)" : ""),
                    location: b.location, related: group.map(\.id)))
            }
        }
        return out.sorted { $0.location.byteRange.lowerBound < $1.location.byteRange.lowerBound }
    }

    // MARK: Cycles

    private func findCycles(points: [SpringInjectionPoint], resolutions: [SpringInjectionPoint: SpringResolution], beans: [SpringBean]) -> [SpringDependencyCycle] {
        let singletons = Set(beans.filter { $0.scope == "singleton" && !$0.certainty.isInactive }.map(\.id))
        var edges: [SpringBeanID: [(to: SpringBeanID, strong: Bool)]] = [:]
        for p in points where singletons.contains(p.owner) && !p.isDeferred {
            guard case .resolved(let target)? = resolutions[p], singletons.contains(target) else { continue }
            // Construction-time edges (constructor, factory parameter) are the ones Spring cannot break.
            edges[p.owner, default: []].append((target, p.kind == .constructor || p.kind == .factoryParameter))
        }
        var index = 0
        var stack: [SpringBeanID] = []
        var onStack = Set<SpringBeanID>()
        var indices: [SpringBeanID: Int] = [:], low: [SpringBeanID: Int] = [:]
        var result: [SpringDependencyCycle] = []
        func connect(_ v: SpringBeanID) {
            indices[v] = index; low[v] = index; index += 1
            stack.append(v); onStack.insert(v)
            for e in edges[v] ?? [] {
                if indices[e.to] == nil { connect(e.to); low[v] = min(low[v]!, low[e.to]!) }
                else if onStack.contains(e.to) { low[v] = min(low[v]!, indices[e.to]!) }
            }
            if low[v] == indices[v] {
                var scc: [SpringBeanID] = []
                while let w = stack.popLast() { onStack.remove(w); scc.append(w); if w == v { break } }
                let selfLoop = scc.count == 1 && (edges[v] ?? []).contains { $0.to == v }
                if scc.count > 1 || selfLoop {
                    let members = Set(scc)
                    let inside = scc.flatMap { edges[$0] ?? [] }.filter { members.contains($0.to) }
                    let allStrong = inside.allSatisfy(\.strong)
                    result.append(SpringDependencyCycle(beans: scc.reversed(), strength: allStrong ? .proven : .dependsOnConfiguration))
                }
            }
        }
        for b in beans where indices[b.id] == nil { connect(b.id) }
        return result
    }

    /// Supertypes of every project class, resolved once per build.
    struct SupertypeClosure {
        private var closures: [String: [String: [SpringType]]] = [:]
        private let projectTypes: Set<String>

        init(builder: SpringModelBuilder) {
            projectTypes = Set(builder.typeIndex.keys)
            for q in builder.typeIndex.keys { _ = closure(of: q, builder: builder) }
        }

        @discardableResult
        private mutating func closure(of q: String, builder: SpringModelBuilder) -> [String: [SpringType]] {
            if let c = closures[q] { return c }
            closures[q] = [q: []]   // cycle guard
            var result: [String: [SpringType]] = [q: []]
            if let entry = builder.typeIndex[q] {
                let refs = (entry.type.superclass.map { [$0] } ?? []) + entry.type.interfaces
                for ref in refs {
                    let t = builder.resolve(ref, entry.ctx, enclosing: q)
                    guard t.isResolved else { continue }
                    result[t.name] = t.arguments
                    for (name, _) in closure(of: t.name, builder: builder) where result[name] == nil { result[name] = [] }
                }
            }
            closures[q] = result
            return result
        }

        func isProjectType(_ t: SpringType) -> Bool { projectTypes.contains(t.name) }

        func isSubtype(_ name: String, of ancestor: String) -> Bool { closures[name]?[ancestor] != nil && name != ancestor }

        /// Active beans keyed by every type they can be injected as (their own and each supertype).
        func supertypeIndex(_ beans: [SpringBean]) -> [String: [SpringBean]] {
            var out: [String: [SpringBean]] = [:]
            for b in beans where b.type.isResolved && !b.certainty.isInactive {
                let names: [String] = closures[b.type.name].map { Array($0.keys) } ?? [b.type.name]
                for name in names {
                    out[name, default: []].append(b)
                }
            }
            return out
        }

        /// Active beans assignable to `required`, in registration order.
        func candidates(for required: SpringType, index: [String: [SpringBean]], all: [SpringBean]) -> [SpringBean] {
            if required.name == "java.lang.Object" { return all.filter { !$0.certainty.isInactive } }
            return (index[required.name] ?? []).filter { isAssignable($0.type, to: required) }
        }

        func isAssignable(_ bean: SpringType, to required: SpringType) -> Bool {
            guard required.isResolved else { return false }
            if required.name == "java.lang.Object" { return true }
            guard bean.isResolved, let supers = closures[bean.name] ?? (bean.name == required.name ? [bean.name: []] : nil),
                  let args = supers[required.name] else {
                return bean.isResolved && bean.name == required.name && argumentsCompatible(bean.arguments, required.arguments)
            }
            let known = bean.name == required.name ? bean.arguments : args
            return argumentsCompatible(known, required.arguments)
        }

        private func argumentsCompatible(_ have: [SpringType], _ want: [SpringType]) -> Bool {
            guard !have.isEmpty, have.count == want.count else { return true }
            for (h, w) in zip(have, want) where h.isResolved && w.isResolved && h.name != w.name { return false }
            return true
        }
    }
}
