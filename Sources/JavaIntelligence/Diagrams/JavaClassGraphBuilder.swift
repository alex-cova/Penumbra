import Foundation

/// Builds a ``JavaClassGraph`` from the index. It reads stubs only (no analysis pass), so a diagram of a
/// whole package costs about what the type hierarchy does, but it is still a scan: run it on request,
/// never while typing.
public struct JavaClassGraphBuilder: Sendable {
    private let index: JavaIndex
    private let openBuffer: (@Sendable (URL) async -> String?)?
    private let queryScope: Set<String>?

    /// - Parameters:
    ///   - openBuffer: reads unsaved editor text, so the diagram matches what is on screen.
    ///   - queryScope: the shard paths a Gradle source set can see, as the other index queries take.
    public init(
        index: JavaIndex,
        openBuffer: (@Sendable (URL) async -> String?)? = nil,
        queryScope: Set<String>? = nil
    ) {
        self.index = index
        self.openBuffer = openBuffer
        self.queryScope = queryScope
    }

    public func build(scope: JavaClassGraphScope, options: JavaClassGraphOptions = JavaClassGraphOptions()) async -> JavaClassGraph {
        let index = self.index
        let lookup = openBuffer
        return await JavaIndex.$queryScope.withValue(queryScope) {
            await JavaMemberLookup.$sourceTextProvider.withValue(lookup) {
                await Self.run(scope: scope, options: options, index: index, openBuffer: lookup)
            }
        }
    }

    // MARK: - Pipeline

    private static func run(
        scope: JavaClassGraphScope, options: JavaClassGraphOptions, index: JavaIndex,
        openBuffer: (@Sendable (URL) async -> String?)?
    ) async -> JavaClassGraph {
        var project: [String: JavaClassStub] = [:]
        for stub in await index.projectClassStubs() { project[stub.qualifiedName] = stub }

        var rootNames: [String] = []
        switch scope {
        case .project:
            rootNames = project.keys.sorted()
        case .types(let names):
            for name in names {
                if project[name] != nil {
                    rootNames.append(name)
                } else if let stub = await index.classStub(qualifiedName: name) {
                    project[name] = stub
                    rootNames.append(name)
                }
            }
        case .package(let packageName):
            for stub in await index.classes(inPackage: packageName) {
                guard case .source = stub.origin else { continue }
                project[stub.qualifiedName] = project[stub.qualifiedName] ?? stub
                rootNames.append(stub.qualifiedName)
            }
            rootNames.sort()
        case .file(let url):
            guard let text = await readSource(url, openBuffer: openBuffer) else { break }
            for parsed in JavaSourceStubBuilder.build(source: text, url: url).classes {
                if project[parsed.qualifiedName] == nil { project[parsed.qualifiedName] = parsed }
                rootNames.append(parsed.qualifiedName)
            }
        }
        guard !rootNames.isEmpty else { return JavaClassGraph() }

        let analyzer = RelationAnalyzer(index: index, openBuffer: openBuffer, options: options)
        var relations: [String: [ClassRelation]] = [:]

        // Supertypes and subtypes are part of what a class *is*, so they are always drawn; the neighbour depth
        // only adds the types reached through fields, parameters and the like.
        for (name, stub) in project {
            relations[name] = await analyzer.relations(of: stub, project: project)
        }
        var included = hierarchy(of: rootNames, relations: relations, project: project)
        if options.neighbourDepth > 0 {
            included = neighbourhood(of: included, relations: relations, project: project, depth: options.neighbourDepth)
        }

        let capped = Array(included.prefix(options.nodeLimit))
        let includedSet = Set(capped)
        var omitted = included.count - capped.count

        var externals: [String: JavaClassStub] = [:]
        for name in capped {
            for relation in relations[name] ?? [] where project[relation.target] == nil && externals[relation.target] == nil {
                guard options.showExternalTypes || relation.kind.isHierarchy else { continue }
                if let stub = await index.classStub(qualifiedName: relation.target) { externals[relation.target] = stub }
            }
        }
        let room = max(0, options.nodeLimit - capped.count)
        if externals.count > room {
            let kept = externals.keys.sorted().prefix(room)
            omitted += externals.count - room
            externals = externals.filter { kept.contains($0.key) }
        }

        var nodes: [JavaClassGraph.Node] = []
        for name in capped.sorted() {
            guard let stub = project[name] else { continue }
            nodes.append(node(for: stub, external: false, options: options))
        }
        for name in externals.keys.sorted() {
            guard let stub = externals[name] else { continue }
            nodes.append(node(for: stub, external: true, options: options))
        }

        let nodeNames = includedSet.union(externals.keys)
        var strongest: [String: JavaClassGraph.Edge] = [:]
        for name in capped {
            for relation in relations[name] ?? [] where relation.target != name && nodeNames.contains(relation.target) {
                let key = name + "\u{0}" + relation.target
                if let existing = strongest[key], existing.kind.strength >= relation.kind.strength { continue }
                strongest[key] = JavaClassGraph.Edge(source: name, destination: relation.target, kind: relation.kind, label: relation.label)
            }
        }
        let edges = strongest.values.sorted {
            ($0.source, $0.destination, $0.kind.rawValue) < ($1.source, $1.destination, $1.kind.rawValue)
        }
        return JavaClassGraph(nodes: nodes, edges: edges, truncated: omitted > 0, omittedCount: omitted)
    }

    /// The roots, then their project supertypes (all the way up) and subtypes (all the way down).
    private static func hierarchy(
        of roots: [String], relations: [String: [ClassRelation]], project: [String: JavaClassStub]
    ) -> [String] {
        var parents: [String: [String]] = [:]
        var children: [String: [String]] = [:]
        for (source, list) in relations {
            for relation in list where relation.kind.isHierarchy && project[relation.target] != nil {
                parents[source, default: []].append(relation.target)
                children[relation.target, default: []].append(source)
            }
        }
        var order = roots
        var seen = Set(roots)
        for direction in [parents, children] {
            var frontier = roots
            while !frontier.isEmpty {
                var next: [String] = []
                for name in frontier {
                    for neighbour in (direction[name] ?? []).sorted() where seen.insert(neighbour).inserted {
                        next.append(neighbour)
                        order.append(neighbour)
                    }
                }
                frontier = next
            }
        }
        return order
    }

    /// The scope's types, then types reached by following relations in either direction, nearest first.
    private static func neighbourhood(
        of roots: [String], relations: [String: [ClassRelation]], project: [String: JavaClassStub], depth: Int
    ) -> [String] {
        var incoming: [String: [String]] = [:]
        for (source, list) in relations {
            for relation in list where project[relation.target] != nil {
                incoming[relation.target, default: []].append(source)
            }
        }
        var order = roots
        var seen = Set(roots)
        var frontier = roots
        for _ in 0..<depth {
            var next: [String] = []
            for name in frontier {
                var neighbours = (relations[name] ?? []).map(\.target).filter { project[$0] != nil }
                neighbours += incoming[name] ?? []
                for neighbour in neighbours.sorted() where seen.insert(neighbour).inserted {
                    next.append(neighbour)
                    order.append(neighbour)
                }
            }
            frontier = next
        }
        return order
    }

    private static func readSource(_ url: URL, openBuffer: (@Sendable (URL) async -> String?)?) async -> String? {
        if let openBuffer, let text = await openBuffer(url) { return text }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Nodes

    private static func node(for stub: JavaClassStub, external: Bool, options: JavaClassGraphOptions) -> JavaClassGraph.Node {
        var attributes: [String] = []
        var methods: [String] = []
        if !external, options.showMembers {
            let isInterface = stub.kind == .interfaceKind || stub.kind == .annotationKind
            for field in stub.fields where !field.modifiers.contains(.synthetic) {
                if field.modifiers.contains(.enumConstant) {
                    attributes.append(field.name)
                    continue
                }
                guard options.showPrivateMembers || !field.modifiers.contains(.privateFlag) else { continue }
                attributes.append("\(visibility(field.modifiers, interface: isInterface)) \(field.name): \(display(field.type))")
            }
            for method in stub.methods where !method.modifiers.contains(.synthetic) && !method.modifiers.contains(.bridge) {
                guard method.name != "<clinit>" else { continue }
                guard options.showPrivateMembers || !method.modifiers.contains(.privateFlag) else { continue }
                let parameters = method.parameters.map { display($0.type) }.joined(separator: ", ")
                let mark = visibility(method.modifiers, interface: isInterface)
                if method.isConstructor {
                    methods.append("\(mark) \(stub.simpleName)(\(parameters))")
                } else {
                    methods.append("\(mark) \(method.name)(\(parameters)): \(display(method.returnType))")
                }
            }
        }
        let url: URL?
        if case .source(let fileURL, _) = stub.origin { url = fileURL } else { url = nil }
        let displayName = stub.packageName.isEmpty || !stub.qualifiedName.hasPrefix(stub.packageName + ".")
            ? stub.qualifiedName
            : String(stub.qualifiedName.dropFirst(stub.packageName.count + 1))
        return JavaClassGraph.Node(
            qualifiedName: stub.qualifiedName, displayName: displayName, packageName: stub.packageName,
            kind: stub.kind, isAbstract: stub.modifiers.contains(.abstractFlag) && stub.kind == .classKind,
            isExternal: external, attributes: attributes, methods: methods, sourceURL: url
        )
    }

    private static func visibility(_ modifiers: JavaModifiers, interface: Bool) -> String {
        if modifiers.contains(.privateFlag) { return "-" }
        if modifiers.contains(.protectedFlag) { return "#" }
        if modifiers.contains(.publicFlag) || interface { return "+" }
        return "~"
    }

    static func display(_ type: JavaTypeRef) -> String {
        switch type {
        case .primitive(let primitive): return primitive.rawValue
        case .void: return "void"
        case .typeVariable(let name): return name
        case .wildcard: return "?"
        case .array(let element): return display(element) + "[]"
        case .classType(let name, let arguments, _):
            return (name.split(separator: ".").last.map(String.init) ?? name) + displayArguments(arguments)
        case .unresolved(let name, let arguments):
            return name + displayArguments(arguments)
        }
    }

    private static func displayArguments(_ arguments: [JavaTypeArgument]) -> String {
        guard !arguments.isEmpty else { return "" }
        let parts = arguments.map { argument -> String in
            switch argument {
            case .type(let type): display(type)
            case .wildcard: "?"
            }
        }
        return "<" + parts.joined(separator: ", ") + ">"
    }
}

private struct ClassRelation: Hashable {
    let target: String
    let kind: JavaClassGraph.EdgeKind
    let label: String
}

/// Finds what a type refers to. A source stub keeps `extends Animal` and field types as written, so each
/// reference is resolved against the declaring file's package and imports, the same way member lookup does.
private struct RelationAnalyzer {
    let index: JavaIndex
    let openBuffer: (@Sendable (URL) async -> String?)?
    let options: JavaClassGraphOptions
    private let files = FileContexts()

    init(index: JavaIndex, openBuffer: (@Sendable (URL) async -> String?)?, options: JavaClassGraphOptions) {
        self.index = index
        self.openBuffer = openBuffer
        self.options = options
    }

    private final class FileContexts: @unchecked Sendable {
        private let lock = NSLock()
        private var contexts: [String: JavaResolutionContext] = [:]

        func context(for key: String) -> JavaResolutionContext? {
            lock.lock(); defer { lock.unlock() }
            return contexts[key]
        }

        func store(_ context: JavaResolutionContext, for key: String) {
            lock.lock(); defer { lock.unlock() }
            contexts[key] = context
        }
    }

    func relations(of stub: JavaClassStub, project: [String: JavaClassStub]) async -> [ClassRelation] {
        let base = await fileContext(of: stub)
        let context = base.entering(type: stub)
        var result: [ClassRelation] = []

        let isInterface = stub.kind == .interfaceKind || stub.kind == .annotationKind
        if let superclass = stub.superclass {
            for name in await targets(of: superclass, context: context, direct: .inheritance, nested: .inheritance, keepJavaLang: true) {
                if name.target != "java.lang.Object" { result.append(name) }
            }
        }
        for interface in stub.interfaces {
            let kind: JavaClassGraph.EdgeKind = isInterface ? .inheritance : .realization
            result += await targets(of: interface, context: context, direct: kind, nested: kind, keepJavaLang: true)
        }

        for field in stub.fields where !field.modifiers.contains(.synthetic) && !field.modifiers.contains(.enumConstant) {
            result += await targets(of: field.type, context: context, direct: .association, nested: .aggregation, label: field.name)
        }

        for method in stub.methods where !method.modifiers.contains(.synthetic) && !method.modifiers.contains(.bridge) {
            if method.modifiers.contains(.privateFlag), !options.showPrivateMembers { continue }
            let methodContext = context.entering(methodTypeParameters: method.typeParameters)
            for parameter in method.parameters {
                result += await targets(of: parameter.type, context: methodContext, direct: .dependency, nested: .dependency)
            }
            if !method.isConstructor {
                result += await targets(of: method.returnType, context: methodContext, direct: .dependency, nested: .dependency)
            }
            for thrown in method.thrownTypes {
                result += await targets(of: thrown, context: methodContext, direct: .dependency, nested: .dependency)
            }
        }
        return result
    }

    private func fileContext(of stub: JavaClassStub) async -> JavaResolutionContext {
        guard case .source(let url, _) = stub.origin else {
            return JavaResolutionContext(packageName: stub.packageName, imports: [])
        }
        let key = url.standardizedFileURL.path
        if let cached = files.context(for: key) { return cached }
        var context = JavaResolutionContext(packageName: stub.packageName, imports: [])
        var text: String?
        if let openBuffer { text = await openBuffer(url) }
        if text == nil { text = try? String(contentsOf: url, encoding: .utf8) }
        if let text {
            context = .file(JavaSourceStubBuilder.build(source: text, url: url))
        }
        files.store(context, for: key)
        return context
    }

    /// Types `type` points at. Collections and other generic JDK containers are looked through to their
    /// arguments, since "a `List<Order>` field" means "has many `Order`".
    private func targets(
        of type: JavaTypeRef, context: JavaResolutionContext,
        direct: JavaClassGraph.EdgeKind, nested: JavaClassGraph.EdgeKind,
        label: String = "", keepJavaLang: Bool = false
    ) async -> [ClassRelation] {
        let resolved = await JavaTypeResolver.resolve(type, context: context, index: index)
        var found: [ClassRelation] = []
        collect(resolved, kind: direct, nested: nested, label: label, keepJavaLang: keepJavaLang, into: &found)
        return found
    }

    private func collect(
        _ type: JavaTypeRef, kind: JavaClassGraph.EdgeKind, nested: JavaClassGraph.EdgeKind,
        label: String, keepJavaLang: Bool, into found: inout [ClassRelation]
    ) {
        switch type {
        case .array(let element):
            collect(element, kind: nested, nested: nested, label: label, keepJavaLang: keepJavaLang, into: &found)
        case .classType(let name, let arguments, _):
            let isJDK = name.hasPrefix("java.") || name.hasPrefix("javax.")
            if isJDK, !arguments.isEmpty {
                for argument in arguments {
                    switch argument {
                    case .type(let inner):
                        collect(inner, kind: nested, nested: nested, label: label, keepJavaLang: false, into: &found)
                    case .wildcard(.extends(let bound)?), .wildcard(.superBound(let bound)?):
                        collect(bound, kind: nested, nested: nested, label: label, keepJavaLang: false, into: &found)
                    case .wildcard(nil):
                        break
                    }
                }
                return
            }
            if name.hasPrefix("java.lang."), !keepJavaLang { return }
            found.append(ClassRelation(target: name, kind: kind, label: label))
            if !isJDK {
                for argument in arguments {
                    if case .type(let inner) = argument {
                        collect(inner, kind: .dependency, nested: .dependency, label: "", keepJavaLang: false, into: &found)
                    }
                }
            }
        case .primitive, .void, .typeVariable, .wildcard, .unresolved:
            break
        }
    }
}
