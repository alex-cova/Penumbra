import EditorIntelligence
import Foundation

/// Gutter markers for a Java file: methods that implement or override a supertype's method (↑),
/// methods and types that project subtypes implement or override (↓), superclass methods that
/// implement an interface method for a subclass, and recursive calls.
///
/// ↓ and sibling markers need the project's subtypes. They come from a map of supertype to
/// direct project subtypes, built from the index once per index generation and Gradle scope; the
/// open buffer's own classes replace their indexed (saved) versions. Like ``JavaMethodFamily``,
/// anonymous classes and lambdas are not counted as overriders, so the scan stays stub-only.
public actor JavaLineMarkerProvider {
    /// Most method declarations examined per file.
    static let maxMethods = 400

    private struct SubtypeKey: Equatable {
        let generation: Int
        let scope: Set<String>?
    }

    private let index: JavaIndex
    private let indexPaths: JavaIndexPaths
    private var classpathModel: JavaGradleProjectModel?
    private var classpathPaths: JavaIndexPaths?
    private var openBuffer: (@Sendable (URL) async -> String?)?
    private var subtypeCache: (key: SubtypeKey, map: [String: [JavaClassStub]])?

    public init(index: JavaIndex, indexPaths: JavaIndexPaths) {
        self.index = index
        self.indexPaths = indexPaths
    }

    public func setSourceSetClasspath(_ model: JavaGradleProjectModel?, indexPaths: JavaIndexPaths) {
        classpathModel = model
        classpathPaths = model == nil ? nil : indexPaths
    }

    public func setOpenBufferLookup(_ lookup: (@Sendable (URL) async -> String?)?) {
        openBuffer = lookup
    }

    /// The markers of `kinds` in `source`, ordered by line, or `nil` when the task was cancelled
    /// or the file does not parse.
    public func markers(
        source: String, fileURL: URL?, kinds: Set<JavaLineMarkerKind> = Set(JavaLineMarkerKind.allCases)
    ) async -> [JavaLineMarker]? {
        guard !kinds.isEmpty, !source.isEmpty else { return [] }
        let scope = scope(for: fileURL)
        let lookup = openBuffer
        return await JavaIndex.$queryScope.withValue(scope) {
            await JavaMemberLookup.$sourceTextProvider.withValue(lookup) {
                let needsSubtypes = !kinds.isDisjoint(with: [.implemented, .overridden, .siblingInherited])
                let subtypes = needsSubtypes ? await self.subtypeMap(scope: scope) : [:]
                guard let subtypes, !Task.isCancelled else { return nil }
                return await JavaLineMarkers.compute(
                    source: source, fileURL: fileURL, kinds: kinds, subtypes: subtypes,
                    index: self.index, cacheRoot: self.indexPaths.root, openBuffer: lookup
                )
            }
        }
    }

    /// Where a ``JavaLineMarkerKind/siblingInherited`` marker leads: the interface methods it
    /// implements. `documentID` is used for a target in `fileURL` itself.
    public func siblingTargets(
        of marker: JavaLineMarker, source: String, fileURL: URL?, documentID: DocumentID
    ) async -> [Location] {
        guard !marker.targets.isEmpty else { return [] }
        let scope = scope(for: fileURL)
        let lookup = openBuffer
        let index = self.index
        let cacheRoot = indexPaths.root
        return await JavaIndex.$queryScope.withValue(scope) {
            await JavaMemberLookup.$sourceTextProvider.withValue(lookup) {
                let hits = await JavaLineMarkers.targetHits(
                    marker.targets, source: source, fileURL: fileURL, index: index, cacheRoot: cacheRoot, openBuffer: lookup
                )
                return hits.map { hit in
                    let same = hit.url == nil || JavaNavigationText.sameFile(hit.url, fileURL)
                    return Location(documentID: same ? documentID : DocumentID(), url: hit.url, range: hit.range, displayName: hit.displayName)
                }
            }
        }
    }

    private func scope(for file: URL?) -> Set<String>? {
        guard let file, let classpathModel, let classpathPaths else { return nil }
        return classpathModel.visibleShardPaths(forFile: file, paths: classpathPaths)
    }

    /// Supertype qualified name → its direct project subtypes. `nil` when cancelled while building.
    private func subtypeMap(scope: Set<String>?) async -> [String: [JavaClassStub]]? {
        let key = SubtypeKey(generation: await index.generation, scope: scope)
        if let subtypeCache, subtypeCache.key == key { return subtypeCache.map }
        var map: [String: [JavaClassStub]] = [:]
        for stub in await index.projectClassStubs() where stub.superclass != nil || !stub.interfaces.isEmpty {
            if Task.isCancelled { return nil }
            for name in await JavaMemberLookup.directSupertypeNames(of: stub.qualifiedName, index: index)
            where name != "java.lang.Object" && name != stub.qualifiedName {
                map[name, default: []].append(stub)
            }
        }
        subtypeCache = (key, map)
        return map
    }
}

/// The per-file work, kept out of the actor so the syntax tree never crosses an isolation boundary.
enum JavaLineMarkers {
    private static let typeDeclarations: Set<String> = [
        "class_declaration", "interface_declaration", "enum_declaration", "record_declaration",
    ]
    /// Nodes that can hold member declarations. Method and constructor bodies are not descended,
    /// so local and anonymous classes are left out.
    private static let memberContainers: Set<String> = [
        "program", "class_body", "interface_body", "enum_body", "enum_body_declarations",
    ]

    static func compute(
        source: String, fileURL: URL?, kinds: Set<JavaLineMarkerKind>, subtypes indexedSubtypes: [String: [JavaClassStub]],
        index: JavaIndex, cacheRoot: URL, openBuffer: (@Sendable (URL) async -> String?)?
    ) async -> [JavaLineMarker]? {
        guard let tree = JavaSyntaxParser().parse(source) else { return nil }
        let file = JavaSourceStubBuilder.build(tree: tree, url: fileURL ?? URL(fileURLWithPath: "/unsaved/LineMarkers.java"))
        let lines = JavaLineTable(source)
        func session(at byte: Int) -> JavaNavigationSession {
            JavaNavigationSession(
                source: source, fileURL: fileURL, tree: tree, byteOffset: byte, fileStubs: file,
                index: index, jdkHome: nil, cacheRoot: cacheRoot, openBuffer: openBuffer,
                decompile: JavaDecompileGate(policy: .denied)
            )
        }

        // A supertype the index can't resolve may be a class of this (unsaved) buffer.
        let localClasses = Dictionary(file.classes.map { ($0.qualifiedName, $0) }, uniquingKeysWith: { first, _ in first })
        let localBySimpleName = Dictionary(file.classes.map { ($0.simpleName, $0.qualifiedName) }, uniquingKeysWith: { first, _ in first })
        func supertypes(of qualifiedName: String) async -> [String] {
            guard let stub = localClasses[qualifiedName], case .source(_, let nameRange) = stub.origin else {
                return await session(at: 0).directSupertypes(of: qualifiedName)
            }
            var names = await session(at: nameRange.lowerBound).directSupertypes(of: qualifiedName)
            for reference in [stub.superclass].compactMap({ $0 }) + stub.interfaces {
                guard case .unresolved(let written, _) = reference,
                      let simple = written.split(separator: ".").last,
                      let local = localBySimpleName[String(simple)], !names.contains(local) else { continue }
                names.append(local)
            }
            return names
        }

        // The buffer's classes stand in for their indexed versions.
        var subtypes: [String: [JavaClassStub]] = [:]
        if !kinds.isDisjoint(with: [.implemented, .overridden, .siblingInherited]) {
            let own = Set(file.classes.map(\.qualifiedName))
            for (name, stubs) in indexedSubtypes {
                let kept = stubs.filter { !own.contains($0.qualifiedName) }
                if !kept.isEmpty { subtypes[name] = kept }
            }
            for stub in file.classes {
                for name in await supertypes(of: stub.qualifiedName) where name != "java.lang.Object" && name != stub.qualifiedName {
                    subtypes[name, default: []].append(stub)
                }
            }
        }

        var declarations: [SyntaxNode] = []
        collectDeclarations(tree.rootNode, into: &declarations)
        var markers: [JavaLineMarker] = []
        var methodCount = 0
        for declaration in declarations {
            if Task.isCancelled { return nil }
            guard let nameNode = declaration.child(byFieldName: "name") else { continue }
            let scoped = session(at: nameNode.startByte)
            guard let owner = scoped.context.enclosingTypeQualifiedNames.first else { continue }
            let line = lines.line(ofByte: nameNode.startByte)
            let anchor = lines.utf16Offset(ofByte: nameNode.startByte)
            if typeDeclarations.contains(declaration.type) {
                if let marker = await typeMarker(owner: owner, line: line, anchor: anchor, kinds: kinds, subtypes: subtypes, session: scoped) {
                    markers.append(marker)
                }
                continue
            }
            methodCount += 1
            if methodCount > JavaLineMarkerProvider.maxMethods { break }
            guard let ownerStub = await scoped.liveStub(owner),
                  let method = matchingMethod(declaration, name: nameNode.text, in: ownerStub) else { continue }
            let site = MethodSite(owner: ownerStub, method: method, line: line, anchor: anchor)
            markers.append(contentsOf: await superMarkers(site, kinds: kinds, session: scoped, supertypes: supertypes(of:)))
            if let marker = await overriderMarker(site, kinds: kinds, subtypes: subtypes) {
                markers.append(marker)
            }
            if kinds.contains(.siblingInherited), let marker = await siblingMarker(site, subtypes: subtypes, session: scoped, index: index) {
                markers.append(marker)
            }
            if kinds.contains(.recursiveCall) {
                markers.append(contentsOf: await recursionMarkers(
                    in: declaration, site: site, lines: lines, session: session(at:)
                ))
            }
        }
        return markers.enumerated().sorted { lhs, rhs in
            lhs.element.line == rhs.element.line ? lhs.offset < rhs.offset : lhs.element.line < rhs.element.line
        }.map(\.element)
    }

    /// Hits for the methods `ids` name, labelled `Owner.method(...)`.
    static func targetHits(
        _ ids: [JavaSymbolID], source: String, fileURL: URL?, index: JavaIndex, cacheRoot: URL,
        openBuffer: (@Sendable (URL) async -> String?)?
    ) async -> [JavaDefinitionHit] {
        guard let tree = JavaSyntaxParser().parse(source) else { return [] }
        let session = JavaNavigationSession(
            source: source, fileURL: fileURL, tree: tree, byteOffset: 0,
            index: index, jdkHome: nil, cacheRoot: cacheRoot, openBuffer: openBuffer,
            decompile: JavaDecompileGate(policy: .denied)
        )
        var targets: [MethodTarget] = []
        for id in ids {
            guard case .method(let declaringClass, let name, let keys) = id,
                  let stub = await session.liveStub(declaringClass),
                  let method = stub.methods.first(where: { !$0.isConstructor && $0.name == name && JavaTypeKeys.keys(of: $0) == keys })
            else { continue }
            targets.append(MethodTarget(declaringClass: declaringClass, method: method))
        }
        return await session.methodHits(targets, qualifiedOwner: true)
    }

    // MARK: - Declarations

    private struct MethodSite {
        let owner: JavaClassStub
        let method: JavaMethodStub
        let line: Int
        let anchor: Int
    }

    private static func collectDeclarations(_ node: SyntaxNode, into declarations: inout [SyntaxNode]) {
        for child in node.namedChildren {
            if typeDeclarations.contains(child.type) {
                declarations.append(child)
                if let body = child.child(byFieldName: "body") {
                    collectDeclarations(body, into: &declarations)
                }
            } else if child.type == "method_declaration" {
                declarations.append(child)
            } else if memberContainers.contains(child.type) {
                collectDeclarations(child, into: &declarations)
            }
        }
    }

    /// The stub for a `method_declaration`: same name and arity, exact parameter keys preferred.
    private static func matchingMethod(_ declaration: SyntaxNode, name: String, in stub: JavaClassStub) -> JavaMethodStub? {
        let arity = declaration.child(byFieldName: "parameters")?.namedChildren
            .filter { $0.type == "formal_parameter" || $0.type == "spread_parameter" }.count ?? 0
        let sameArity = stub.methods.filter { $0.name == name && !$0.isConstructor && $0.parameters.count == arity }
        let written = JavaNavigationSession.parameterKeys(of: declaration)
        return sameArity.first { JavaTypeKeys.keys(of: $0) == written } ?? sameArity.first
    }

    private static func isAbstract(_ method: JavaMethodStub, in owner: JavaClassStub?) -> Bool {
        method.modifiers.contains(.abstractFlag)
            || (owner?.kind == .interfaceKind && !method.modifiers.contains(.defaultMethod) && !method.modifiers.contains(.staticFlag))
    }

    // MARK: - ↑ Implementing / overriding

    private static func superMarkers(
        _ site: MethodSite, kinds: Set<JavaLineMarkerKind>, session: JavaNavigationSession,
        supertypes: (String) async -> [String]
    ) async -> [JavaLineMarker] {
        guard kinds.contains(.implementing) || kinds.contains(.overriding) else { return [] }
        let targets = await JavaSuperMethods.overridden(
            method: site.method, owner: site.owner.qualifiedName,
            stub: { await session.liveStub($0) },
            supertypes: supertypes
        )
        guard !targets.isEmpty else { return [] }
        var implementsAll = true
        for target in targets where !isAbstract(target.method, in: await session.liveStub(target.declaringClass)) {
            implementsAll = false
        }
        let kind: JavaLineMarkerKind = implementsAll ? .implementing : .overriding
        guard kinds.contains(kind) else { return [] }
        let owners = uniqued(targets.map { simpleName($0.declaringClass) })
        let verb = implementsAll ? "Implements" : "Overrides"
        return [JavaLineMarker(
            kind: kind, line: site.line, anchorUTF16Offset: site.anchor,
            tooltip: "\(verb) method in \(list(owners))"
        )]
    }

    // MARK: - ↓ Implemented / overridden

    private static func typeMarker(
        owner: String, line: Int, anchor: Int, kinds: Set<JavaLineMarkerKind>,
        subtypes: [String: [JavaClassStub]], session: JavaNavigationSession
    ) async -> JavaLineMarker? {
        guard let direct = subtypes[owner], !direct.isEmpty else { return nil }
        let isInterface = await session.liveStub(owner)?.kind == .interfaceKind
        let kind: JavaLineMarkerKind = isInterface ? .implemented : .overridden
        guard kinds.contains(kind) else { return nil }
        let names = uniqued(direct.map(\.simpleName)).sorted()
        return JavaLineMarker(
            kind: kind, line: line, anchorUTF16Offset: anchor,
            tooltip: "\(isInterface ? "Is implemented by" : "Is subclassed by") \(list(names))"
        )
    }

    private static func overriderMarker(
        _ site: MethodSite, kinds: Set<JavaLineMarkerKind>, subtypes: [String: [JavaClassStub]]
    ) async -> JavaLineMarker? {
        let method = site.method
        guard JavaSuperMethods.isOverridable(method), !method.modifiers.contains(.finalFlag) else { return nil }
        let abstract = isAbstract(method, in: site.owner)
        let kind: JavaLineMarkerKind = abstract ? .implemented : .overridden
        guard kinds.contains(kind) else { return nil }
        let variables = Set(site.owner.typeParameters.map(\.name) + method.typeParameters.map(\.name))
        var overriders: [String] = []
        var visited: Set<String> = [site.owner.qualifiedName]
        var queue = subtypes[site.owner.qualifiedName] ?? []
        while !queue.isEmpty, overriders.count < 4 {
            let stub = queue.removeFirst()
            guard visited.insert(stub.qualifiedName).inserted else { continue }
            if overrides(in: stub, method: method, variables: variables) {
                overriders.append(stub.simpleName)
            }
            queue.append(contentsOf: subtypes[stub.qualifiedName] ?? [])
        }
        guard !overriders.isEmpty else { return nil }
        return JavaLineMarker(
            kind: kind, line: site.line, anchorUTF16Offset: site.anchor,
            tooltip: "\(abstract ? "Is implemented in" : "Is overridden in") \(list(uniqued(overriders)))"
        )
    }

    /// Whether `stub` declares a body for `method`, with the filters Go to Implementation uses.
    private static func overrides(in stub: JavaClassStub, method: JavaMethodStub, variables: Set<String>) -> Bool {
        stub.methods.contains { candidate in
            candidate.name == method.name
                && !candidate.isConstructor
                && !candidate.modifiers.contains(.abstractFlag)
                && !candidate.modifiers.contains(.staticFlag)
                && (stub.kind != .interfaceKind || candidate.modifiers.contains(.defaultMethod))
                && JavaNavigationSession.overrides(candidate: JavaTypeKeys.keys(of: candidate), target: method, typeVariables: variables)
        }
    }

    // MARK: - Sibling inherited

    /// `class C extends Owner implements I`, where C does not declare `method` and I declares it:
    /// Owner's method implements `I.method` for C. Subclasses that override the method are not
    /// descended, since their subclasses inherit the override instead.
    private static func siblingMarker(
        _ site: MethodSite, subtypes: [String: [JavaClassStub]], session: JavaNavigationSession, index: JavaIndex
    ) async -> JavaLineMarker? {
        let method = site.method
        guard site.owner.kind == .classKind || site.owner.kind == .enumKind,
              method.modifiers.contains(.publicFlag), JavaSuperMethods.isOverridable(method),
              !method.modifiers.contains(.abstractFlag),
              let direct = subtypes[site.owner.qualifiedName], !direct.isEmpty else { return nil }
        let ownerClosure = await JavaMemberLookup.supertypeClosure(of: site.owner.qualifiedName, index: index)
        let keys = JavaTypeKeys.keys(of: method)
        var targets: [JavaSymbolID] = []
        var via: [String] = []
        var visited: Set<String> = [site.owner.qualifiedName]
        var queue = direct
        var examined = 0
        while !queue.isEmpty, examined < 50 {
            let stub = queue.removeFirst()
            guard visited.insert(stub.qualifiedName).inserted, stub.kind == .classKind || stub.kind == .enumKind else { continue }
            examined += 1
            let declares = stub.methods.contains {
                $0.name == method.name && !$0.isConstructor && JavaTypeKeys.keys(of: $0) == keys
            }
            if declares { continue }
            let closure = await JavaMemberLookup.supertypeClosure(of: stub.qualifiedName, index: index)
            for name in closure.subtracting(ownerClosure).sorted() {
                guard let interface = await session.liveStub(name), interface.kind == .interfaceKind else { continue }
                let variables = Set(interface.typeParameters.map(\.name))
                for target in interface.methods
                where target.name == method.name && isAbstract(target, in: interface)
                    && JavaNavigationSession.overrides(candidate: keys, target: target, typeVariables: variables.union(target.typeParameters.map(\.name))) {
                    let id = JavaSymbolID.method(declaringClass: name, name: target.name, parameterKeys: JavaTypeKeys.keys(of: target))
                    if !targets.contains(id) {
                        targets.append(id)
                        via.append("\(interface.simpleName).\(method.name) via subclass \(stub.simpleName)")
                    }
                }
            }
            queue.append(contentsOf: subtypes[stub.qualifiedName] ?? [])
        }
        guard !targets.isEmpty else { return nil }
        return JavaLineMarker(
            kind: .siblingInherited, line: site.line, anchorUTF16Offset: site.anchor,
            tooltip: "Implements \(list(via))", targets: targets
        )
    }

    // MARK: - Recursive calls

    private static func recursionMarkers(
        in declaration: SyntaxNode, site: MethodSite, lines: JavaLineTable,
        session: (Int) -> JavaNavigationSession
    ) async -> [JavaLineMarker] {
        guard let body = declaration.child(byFieldName: "body") else { return [] }
        let method = site.method
        let keys = JavaTypeKeys.keys(of: method)
        let isStatic = method.modifiers.contains(.staticFlag)
        var calls: [SyntaxNode] = []
        var stack = [body]
        while let node = stack.popLast() {
            // A lambda or a nested class body runs in another frame or on another object.
            if node.type == "lambda_expression" || node.type == "class_body" { continue }
            stack.append(contentsOf: node.namedChildren)
            guard node.type == "method_invocation",
                  let name = node.child(byFieldName: "name"), name.text == method.name else { continue }
            if let object = node.child(byFieldName: "object") {
                let receiver = object.text
                guard receiver == "this" || (isStatic && receiver == site.owner.simpleName) else { continue }
            }
            calls.append(node)
        }
        var markers: [JavaLineMarker] = []
        var seenLines = Set<Int>()
        for call in calls.sorted(by: { $0.startByte < $1.startByte }) {
            guard let name = call.child(byFieldName: "name") else { continue }
            let line = lines.line(ofByte: name.startByte)
            guard !seenLines.contains(line) else { continue }
            let scoped = session(name.startByte)
            let targets = await narrowed(await scoped.methodCallTargets(call), call: call, session: scoped)
            guard targets.count == 1, targets[0].declaringClass == site.owner.qualifiedName,
                  JavaTypeKeys.keys(of: targets[0].method) == keys else { continue }
            seenLines.insert(line)
            markers.append(JavaLineMarker(
                kind: .recursiveCall, line: line, anchorUTF16Offset: lines.utf16Offset(ofByte: name.startByte),
                tooltip: "Recursive call"
            ))
        }
        return markers
    }

    /// Narrows arity-matched overloads with the argument types, as Find Usages does. Stays
    /// ambiguous when an argument does not type.
    private static func narrowed(_ targets: [MethodTarget], call: SyntaxNode, session: JavaNavigationSession) async -> [MethodTarget] {
        guard targets.count > 1, let arguments = call.child(byFieldName: "arguments") else { return targets }
        let locals = await JavaExpressionTyper.resolvingVarLocals(
            JavaLocalScope.locals(in: session.tree, atByteOffset: arguments.startByte), context: session.context, index: session.index
        )
        var types: [JavaTypeRef?] = []
        for argument in arguments.namedChildren {
            if JavaExpressionTyper.isFunctionalArgument(argument) {
                types.append(nil)
            } else {
                // An untyped argument matches any reference parameter, which could pick the wrong
                // overload; a gutter marker should rather be missing than wrong.
                guard let type = await JavaExpressionTyper.typed(argument, locals: locals, context: session.context, index: session.index)?.type
                else { return targets }
                types.append(type)
            }
        }
        let best = await JavaExpressionTyper.resolveOverloads(
            targets.map(\.method), argumentTypes: types, context: session.context, index: session.index
        )
        return targets.filter { best.contains($0.method) }
    }

    // MARK: - Text

    private static func simpleName(_ qualifiedName: String) -> String {
        String(qualifiedName.split(separator: ".").last ?? Substring(qualifiedName))
    }

    private static func uniqued(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    /// `A`, `A and B`, `A, B and C`, `A, B, C and 2 more`.
    private static func list(_ names: [String]) -> String {
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2...3: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        default: return names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
        }
    }
}

/// Byte offset → editor line and UTF-16 offset, from one pass over the text. A line break is
/// `\n`, `\r\n` or a lone `\r`, as the editor's line manager counts them.
struct JavaLineTable {
    private var lineStartBytes: [Int] = [0]
    private var lineStartUTF16: [Int] = [0]
    private let utf8: [UInt8]

    init(_ source: String) {
        utf8 = Array(source.utf8)
        var utf16 = 0
        var index = 0
        while index < utf8.count {
            let byte = utf8[index]
            let length = Self.sequenceLength(byte)
            utf16 += length == 4 ? 2 : 1
            index += length
            if byte == 0x0A || (byte == 0x0D && (index >= utf8.count || utf8[index] != 0x0A)) {
                lineStartBytes.append(index)
                lineStartUTF16.append(utf16)
            }
        }
    }

    /// 1-based line containing `byte`.
    func line(ofByte byte: Int) -> Int {
        rowIndex(ofByte: byte) + 1
    }

    func utf16Offset(ofByte byte: Int) -> Int {
        let row = rowIndex(ofByte: byte)
        var utf16 = lineStartUTF16[row]
        var index = lineStartBytes[row]
        let end = min(max(byte, 0), utf8.count)
        while index < end {
            let length = Self.sequenceLength(utf8[index])
            utf16 += length == 4 ? 2 : 1
            index += length
        }
        return utf16
    }

    private func rowIndex(ofByte byte: Int) -> Int {
        var low = 0
        var high = lineStartBytes.count
        while low < high {
            let mid = (low + high) / 2
            if lineStartBytes[mid] <= byte { low = mid + 1 } else { high = mid }
        }
        return max(low - 1, 0)
    }

    private static func sequenceLength(_ lead: UInt8) -> Int {
        switch lead {
        case 0xF0...: return 4
        case 0xE0...: return 3
        case 0xC0...: return 2
        default: return 1
        }
    }
}
