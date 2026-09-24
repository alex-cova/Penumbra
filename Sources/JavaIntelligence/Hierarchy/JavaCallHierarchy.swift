import EditorIntelligence
import Foundation

/// One method in a call hierarchy tree.
public struct JavaCallHierarchyNode: Identifiable, Hashable, Sendable {
    public enum Origin: Sendable {
        case source
        case jar
        case jdk
        case ambiguous
    }

    public let symbolID: JavaSymbolID
    public let displayName: String
    public let declaringClass: String
    public let origin: Origin
    /// Unique within one tree: qualified names / method keys from the root down.
    public var id: String { path.joined(separator: " > ") }
    public let path: [String]

    public init(symbolID: JavaSymbolID, displayName: String, declaringClass: String, origin: Origin, path: [String]) {
        self.symbolID = symbolID
        self.displayName = displayName
        self.declaringClass = declaringClass
        self.origin = origin
        self.path = path
    }
}

/// Where a call-hierarchy node lives in source.
public struct JavaCallHierarchyLocation: Sendable, Equatable {
    public let url: URL?
    public let range: EditorIntelligence.TextRange
}

/// Callers and callees of a Java method. Callers search project sources; callees walk the method
/// body (or the caret's enclosing method when expanding callees from a call site).
public actor JavaCallHierarchyProvider {
    private let index: JavaIndex
    private let indexPaths: JavaIndexPaths
    private let findUsages: JavaFindUsagesProvider
    private var classpathModel: JavaGradleProjectModel?
    private var roots: [URL] = []
    private var jdkHome: URL?
    private var openBuffer: (@Sendable (URL) async -> String?)?

    public init(index: JavaIndex, indexPaths: JavaIndexPaths, findUsages: JavaFindUsagesProvider) {
        self.index = index
        self.indexPaths = indexPaths
        self.findUsages = findUsages
    }

    public func setProjectRoots(_ roots: [URL]) {
        self.roots = roots
    }

    public func setSourceSetClasspath(_ model: JavaGradleProjectModel?, indexPaths: JavaIndexPaths) {
        classpathModel = model
    }

    public func setJDKHome(_ home: URL?) {
        jdkHome = home
    }

    public func setOpenBufferLookup(_ lookup: (@Sendable (URL) async -> String?)?) {
        openBuffer = lookup
    }

    /// The method at `utf16Offset` in `source`, or `nil` when the caret is not on a method.
    public func rootMethod(source: String, fileURL: URL?, utf16Offset: Int) async -> JavaCallHierarchyNode? {
        guard let tree = JavaSyntaxParser().parse(source) else { return nil }
        let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: utf16Offset, in: source)
        let environment = makeEnvironment()
        guard let id = await JavaSymbolIdentity.symbolID(at: utf16Offset, in: source, url: fileURL, environment: environment),
              case .method = id else { return nil }
        return await self.makeNode(for: id, path: [Self.pathKey(for: id)], file: fileURL)
    }

    /// Methods that call `node` anywhere in the project.
    public func callers(of node: JavaCallHierarchyNode, file: URL?) async -> [JavaCallHierarchyNode] {
        guard case .method = node.symbolID else { return [] }
        let environment = makeEnvironment()
        var result: [JavaCallHierarchyNode] = []
        var seen = Set<String>()
        let searchRoots = roots.isEmpty ? (file.map { [$0] } ?? []) : roots
        let scan = JavaTextScanCandidateSource(textProvider: openBuffer, extraFiles: file.map { [$0] } ?? [])
        let candidates = JavaIndexedOrScanningCandidates(nameIndex: nil, scan: scan)
        let targets = await JavaMethodFamily.symbolIDs(of: node.symbolID, index: index)
        for target in targets {
            let usages = await JavaUsageSearch.collect(
                target, candidates: candidates, roots: searchRoots, environment: environment, includeDeclarations: false
            )
            for usage in usages where usage.kind == .call || usage.kind == .methodReference {
                guard let enclosing = await enclosingMethod(at: usage, environment: environment) else { continue }
                let key = Self.pathKey(for: enclosing)
                guard seen.insert(key).inserted else { continue }
                if let child = await self.makeNode(for: enclosing, path: node.path + [key], file: file) {
                    result.append(child)
                }
            }
        }
        return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    /// Methods invoked directly from `node`'s declaring method body.
    public func callees(of node: JavaCallHierarchyNode, file: URL?) async -> [JavaCallHierarchyNode] {
        guard case .method(let declaringClass, let name, let parameterKeys) = node.symbolID else { return [] }
        let environment = makeEnvironment()
        return await scoped(file) { [index, jdkHome, indexPaths, openBuffer] in
            guard let stub = await index.classStub(qualifiedName: declaringClass),
                  let method = stub.methods.first(where: { $0.name == name && JavaTypeKeys.keys(of: $0) == parameterKeys }) else { return [] }
            let source = await Self.source(
                for: declaringClass, preferred: file, index: index, jdkHome: jdkHome,
                cacheRoot: indexPaths.root, openBuffer: openBuffer
            )
            guard let source, let tree = JavaSyntaxParser().parse(source) else { return [] }
            guard let methodNode = Self.methodNode(named: name, parameterKeys: parameterKeys, in: tree) else { return [] }
            var result: [JavaCallHierarchyNode] = []
            var seen = Set<String>()
            for invocation in Self.methodInvocations(in: methodNode) {
                let hits = await Self.resolveCallee(invocation, source: source, fileURL: file, environment: environment)
                for hit in hits {
                    let key = Self.pathKey(for: hit.id)
                    guard seen.insert(key).inserted else { continue }
                    if let child = await self.makeNode(for: hit.id, path: node.path + [key], file: file, origin: hit.origin) {
                        result.append(child)
                    }
                }
            }
            return result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
    }

    /// Opens the declaration of `node`.
    public func location(of node: JavaCallHierarchyNode, file: URL?) async -> JavaCallHierarchyLocation? {
        guard case .method(let declaringClass, let name, let parameterKeys) = node.symbolID else { return nil }
        return await scoped(file) { [index, jdkHome, indexPaths, openBuffer] in
            guard let source = await Self.source(
                for: declaringClass, preferred: file, index: index, jdkHome: jdkHome,
                cacheRoot: indexPaths.root, openBuffer: openBuffer
            ),
                  let tree = JavaSyntaxParser().parse(source),
                  let methodNode = Self.methodNode(named: name, parameterKeys: parameterKeys, in: tree) else { return nil }
            let start = JavaImportInserter.textPosition(forByteOffset: methodNode.startByte, in: tree.sourceBytes)
            let end = JavaImportInserter.textPosition(forByteOffset: methodNode.endByte, in: tree.sourceBytes)
            let url = await Self.sourceURL(
                for: declaringClass, preferred: file ?? URL(fileURLWithPath: "/"), index: index, jdkHome: jdkHome,
                cacheRoot: indexPaths.root, openBuffer: openBuffer
            )
            return JavaCallHierarchyLocation(url: url, range: TextRange(start: start, end: end))
        }
    }

    // MARK: - Helpers

    private struct ResolvedCallee {
        let id: JavaSymbolID
        let origin: JavaCallHierarchyNode.Origin
    }

    private func makeEnvironment() -> JavaReferenceEnvironment {
        JavaReferenceEnvironment(
            index: index, jdkHome: jdkHome, cacheRoot: indexPaths.root, openBuffer: openBuffer,
            gradleModel: classpathModel, indexPaths: classpathModel == nil ? nil : indexPaths
        )
    }

    private func scoped<T: Sendable>(_ file: URL?, _ body: @Sendable @escaping () async -> T) async -> T {
        let environment = makeEnvironment()
        if let file, let scope = environment.queryScope(for: file) {
            return await JavaIndex.$queryScope.withValue(scope) {
                await JavaMemberLookup.$sourceTextProvider.withValue(openBuffer) { await body() }
            }
        }
        return await JavaMemberLookup.$sourceTextProvider.withValue(openBuffer) { await body() }
    }

    private func makeNode(
        for id: JavaSymbolID,
        path: [String],
        file: URL?,
        origin: JavaCallHierarchyNode.Origin? = nil
    ) async -> JavaCallHierarchyNode? {
        switch id {
        case .method(let declaringClass, let name, let parameterKeys):
            let resolvedOrigin: JavaCallHierarchyNode.Origin
            if let origin {
                resolvedOrigin = origin
            } else {
                resolvedOrigin = await originOf(for: declaringClass)
            }
            let signature = "\(name)(\(parameterKeys.joined(separator: ", ")))"
            let display = declaringClass.split(separator: ".").last.map { "\($0).\(signature)" } ?? signature
            return JavaCallHierarchyNode(
                symbolID: id, displayName: display, declaringClass: declaringClass, origin: resolvedOrigin, path: path
            )
        default:
            return nil
        }
    }

    private func originOf(for declaringClass: String) async -> JavaCallHierarchyNode.Origin {
        guard let stub = await index.classStub(qualifiedName: declaringClass) else { return .ambiguous }
        switch stub.origin {
        case .source: return .source
        case .jar: return .jar
        case .jdkModule: return .jdk
        }
    }

    private func enclosingMethod(at usage: JavaUsage, environment: JavaReferenceEnvironment) async -> JavaSymbolID? {
        let source: String
        if let buffer = await openBuffer?(usage.url) {
            source = buffer
        } else if let disk = try? String(contentsOf: usage.url, encoding: .utf8) {
            source = disk
        } else {
            return nil
        }
        guard let tree = JavaSyntaxParser().parse(source),
              let methodNode = Self.enclosingMethodNode(containing: usage.byteRange.lowerBound, in: tree) else { return nil }
        let file = JavaSourceStubBuilder.build(tree: tree, url: usage.url)
        guard let declaringClass = Self.declaringClass(of: methodNode, file: file) else { return nil }
        let name = methodNode.child(byFieldName: "name")?.text ?? ""
        let keys = JavaTypeKeys.keys(of: methodNode)
        return .method(declaringClass: declaringClass, name: name, parameterKeys: keys)
    }

    private static func enclosingMethodNode(containing byteOffset: Int, in tree: JavaSyntaxTree) -> SyntaxNode? {
        let node = tree.node(atByteOffset: byteOffset)
        var current: SyntaxNode? = node
        while let walk = current {
            if walk.type == "method_declaration" { return walk }
            current = walk.parent
        }
        return nil
    }

    private static func declaringClass(of methodNode: SyntaxNode, file: JavaSourceFileStubs) -> String? {
        var current: SyntaxNode? = methodNode.parent
        while let walk = current {
            if ["class_declaration", "interface_declaration", "enum_declaration", "record_declaration"].contains(walk.type),
               let name = walk.child(byFieldName: "name")?.text {
                if let outer = outerTypeName(startingAt: walk, file: file) {
                    return outer + "." + name
                }
                if !file.packageName.isEmpty { return file.packageName + "." + name }
                return name
            }
            current = walk.parent
        }
        return nil
    }

    private static func outerTypeName(startingAt node: SyntaxNode, file: JavaSourceFileStubs) -> String? {
        var parent = node.parent
        while let current = parent {
            if ["class_declaration", "interface_declaration", "enum_declaration"].contains(current.type),
               let name = current.child(byFieldName: "name")?.text {
                if let outer = outerTypeName(startingAt: current, file: file) { return outer + "." + name }
                if !file.packageName.isEmpty { return file.packageName + "." + name }
                return name
            }
            parent = current.parent
        }
        return file.packageName.isEmpty ? nil : file.packageName
    }

    private static func pathKey(for id: JavaSymbolID) -> String {
        switch id {
        case .method(let declaringClass, let name, let parameterKeys):
            return "\(declaringClass)#\(name)(\(parameterKeys.joined(separator: ",")))"
        case .type(let name): return "type:\(name)"
        case .field(let declaringClass, let name): return "\(declaringClass)#\(name)"
        case .local(let file, let range): return "local:\(file.path):\(range.lowerBound)"
        case .constructor(let declaringClass, let keys): return "\(declaringClass)#<init>(\(keys.joined(separator: ",")))"
        }
    }

    private static func methodInvocations(in node: SyntaxNode) -> [SyntaxNode] {
        var stack = [node]
        var invocations: [SyntaxNode] = []
        while let current = stack.popLast() {
            if current.type == "method_invocation" { invocations.append(current) }
            for index in (0..<current.namedChildCount).reversed() {
                stack.append(current.namedChild(at: index)!)
            }
        }
        return invocations
    }

    private static func methodNode(named name: String, parameterKeys: [String], in tree: JavaSyntaxTree) -> SyntaxNode? {
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
            if node.type == "method_declaration", node.child(byFieldName: "name")?.text == name {
                let keys = JavaTypeKeys.keys(of: node)
                if keys == parameterKeys { return node }
            }
            for index in (0..<node.namedChildCount).reversed() {
                stack.append(node.namedChild(at: index)!)
            }
        }
        return nil
    }

    private static func resolveCallee(
        _ invocation: SyntaxNode,
        source: String,
        fileURL: URL?,
        environment: JavaReferenceEnvironment
    ) async -> [ResolvedCallee] {
        guard let tree = JavaSyntaxParser().parse(source) else { return [] }
        let byteOffset = invocation.child(byFieldName: "name")?.startByte ?? invocation.startByte
        let file = JavaSourceStubBuilder.build(tree: tree, url: fileURL ?? JavaNavigationSession.placeholderURL)
        let session = JavaNavigationSession(
            source: source, fileURL: fileURL, tree: tree, byteOffset: byteOffset, fileStubs: file,
            index: environment.index, jdkHome: environment.jdkHome, cacheRoot: environment.cacheRoot,
            openBuffer: environment.openBuffer, decompile: JavaDecompileGate(policy: .denied)
        )
        guard let reference = JavaReferenceClassifier.classify(in: tree, atByteOffset: byteOffset) else { return [] }
        var hits: [ResolvedCallee] = []
        for symbol in await session.resolveSymbols(reference) {
            if case .method(let stub, let declaringClass) = symbol {
                let id: JavaSymbolID = .method(
                    declaringClass: declaringClass, name: stub.name, parameterKeys: JavaTypeKeys.keys(of: stub)
                )
                let origin: JavaCallHierarchyNode.Origin
                if let classStub = await environment.index.classStub(qualifiedName: declaringClass) {
                    switch classStub.origin {
                    case .source: origin = .source
                    case .jar: origin = .jar
                    case .jdkModule: origin = .jdk
                    }
                } else {
                    origin = .ambiguous
                }
                hits.append(ResolvedCallee(id: id, origin: origin))
            }
        }
        return hits
    }

    private static func source(
        for declaringClass: String,
        preferred file: URL?,
        index: JavaIndex,
        jdkHome: URL?,
        cacheRoot: URL,
        openBuffer: (@Sendable (URL) async -> String?)?
    ) async -> String? {
        let session = JavaNavigationSession(
            source: "", fileURL: file, tree: JavaSyntaxParser().parse("")!, byteOffset: 0,
            index: index, jdkHome: jdkHome, cacheRoot: cacheRoot, openBuffer: openBuffer,
            decompile: JavaDecompileGate(policy: .denied)
        )
        guard let url = await session.typeHits(qualifiedName: declaringClass).first?.url else { return nil }
        if let buffer = await openBuffer?(url) { return buffer }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private static func source(for declaringClass: String, file: URL?, openBuffer: (@Sendable (URL) async -> String?)?) async -> String? {
        if let file, let buffer = await openBuffer?(file) { return buffer }
        if let file, let disk = try? String(contentsOf: file, encoding: .utf8) { return disk }
        return nil
    }

    private static func sourceURL(
        for declaringClass: String,
        preferred file: URL,
        index: JavaIndex,
        jdkHome: URL?,
        cacheRoot: URL,
        openBuffer: (@Sendable (URL) async -> String?)?
    ) async -> URL? {
        let session = JavaNavigationSession(
            source: "", fileURL: file, tree: JavaSyntaxParser().parse("")!, byteOffset: 0,
            index: index, jdkHome: jdkHome, cacheRoot: cacheRoot, openBuffer: openBuffer,
            decompile: JavaDecompileGate(policy: .denied)
        )
        return await session.typeHits(qualifiedName: declaringClass).first?.url
    }
}
