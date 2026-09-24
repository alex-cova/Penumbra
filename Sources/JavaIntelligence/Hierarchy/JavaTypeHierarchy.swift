import EditorIntelligence
import Foundation

/// One type in a type hierarchy. The tree is built lazily: ask ``JavaTypeHierarchyProvider`` for a
/// node's ``JavaTypeHierarchyProvider/supertypes(of:file:)`` or ``JavaTypeHierarchyProvider/subtypes(of:file:)``
/// when it is expanded.
public struct JavaTypeHierarchyNode: Identifiable, Hashable, Sendable {
    public enum Origin: Sendable {
        /// A `.java` file of the project.
        case source
        /// A dependency JAR.
        case jar
        /// The JDK.
        case jdk
    }

    /// Unique within one tree: the qualified names from the root down to this node.
    public var id: String { path.joined(separator: " > ") }
    public let qualifiedName: String
    /// The name without its package, `Outer.Inner` for a nested type.
    public let displayName: String
    public let packageName: String
    public let kind: JavaTypeKind
    public let origin: Origin
    /// Qualified names from the root to this node, this one last. Used to keep a cycle in broken
    /// code from expanding forever.
    public let path: [String]

    public var isProjectType: Bool { origin == .source }
}

/// Where a hierarchy node is declared, ready to open.
public struct JavaTypeHierarchyLocation: Sendable, Equatable {
    public let url: URL?
    public let range: EditorIntelligence.TextRange
}

/// Supertype and subtype trees for a Java type. Supertypes come from the whole classpath and the
/// JDK; subtypes are the project's own classes (a scan of every project class per expansion, so it
/// belongs behind an explicit request, not typing).
public actor JavaTypeHierarchyProvider {
    private let index: JavaIndex
    private let indexPaths: JavaIndexPaths
    private var classpathModel: JavaGradleProjectModel?
    private var classpathPaths: JavaIndexPaths?
    private var jdkHome: URL?
    private var openBuffer: (@Sendable (URL) async -> String?)?

    public init(index: JavaIndex, indexPaths: JavaIndexPaths) {
        self.index = index
        self.indexPaths = indexPaths
    }

    public func setSourceSetClasspath(_ model: JavaGradleProjectModel?, indexPaths: JavaIndexPaths) {
        classpathModel = model
        classpathPaths = model == nil ? nil : indexPaths
    }

    public func setJDKHome(_ home: URL?) {
        jdkHome = home
    }

    public func setOpenBufferLookup(_ lookup: (@Sendable (URL) async -> String?)?) {
        openBuffer = lookup
    }

    // MARK: - Root

    /// The type to show a hierarchy for at `utf16Offset` of `source`: the type named there (a
    /// reference, a declaration, `this`), else the type the caret is inside. `nil` outside a type.
    public func rootType(source: String, fileURL: URL?, utf16Offset: Int) async -> JavaTypeHierarchyNode? {
        guard let tree = JavaSyntaxParser().parse(source) else { return nil }
        let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: utf16Offset, in: source)
        let session = makeSession(source: source, fileURL: fileURL, tree: tree, byteOffset: byteOffset)
        let index = self.index
        return await scoped(fileURL) {
            var stub: JavaClassStub?
            if let reference = JavaReferenceClassifier.classify(in: tree, atByteOffset: byteOffset) {
                for symbol in await session.resolveSymbols(reference) {
                    if case .type(let found) = symbol { stub = found; break }
                }
            }
            if stub == nil, let enclosing = session.context.enclosingTypeQualifiedNames.first {
                let current = session.currentClasses.first { $0.qualifiedName == enclosing }
                let indexed = await index.classStub(qualifiedName: enclosing)
                stub = indexed ?? current
            }
            return stub.map { Self.node(for: $0, path: [$0.qualifiedName]) }
        }
    }

    /// A root node for a type known by name, e.g. one the user picked in a list.
    public func rootType(named qualifiedName: String, file: URL?) async -> JavaTypeHierarchyNode? {
        let index = self.index
        return await scoped(file) {
            await index.classStub(qualifiedName: qualifiedName).map { Self.node(for: $0, path: [$0.qualifiedName]) }
        }
    }

    // MARK: - Children

    /// The types `node` directly extends or implements: superclass first, then interfaces.
    public func supertypes(of node: JavaTypeHierarchyNode, file: URL?) async -> [JavaTypeHierarchyNode] {
        let index = self.index
        return await scoped(file) {
            var result: [JavaTypeHierarchyNode] = []
            for name in await JavaMemberLookup.directSupertypeNames(of: node.qualifiedName, index: index) {
                guard !node.path.contains(name), let stub = await index.classStub(qualifiedName: name) else { continue }
                result.append(Self.node(for: stub, path: node.path + [name]))
            }
            return result
        }
    }

    /// The project types that directly extend or implement `node`, sorted by name.
    public func subtypes(of node: JavaTypeHierarchyNode, file: URL?) async -> [JavaTypeHierarchyNode] {
        let index = self.index
        return await scoped(file) {
            let simple = node.displayName.split(separator: ".").last.map(String.init) ?? node.displayName
            var result: [JavaTypeHierarchyNode] = []
            for stub in await index.projectClassStubs() where !node.path.contains(stub.qualifiedName) {
                // Cheap pre-filter: only a class that names the type at all is worth resolving.
                let referenced = ([stub.superclass].compactMap { $0 } + stub.interfaces).contains { ref in
                    let name = ref.simpleDisplayName
                    return name == simple || name.hasSuffix("." + simple)
                }
                guard referenced else { continue }
                let supers = await JavaMemberLookup.directSupertypeNames(of: stub.qualifiedName, index: index)
                if supers.contains(node.qualifiedName) {
                    result.append(Self.node(for: stub, path: node.path + [stub.qualifiedName]))
                }
            }
            return result.sorted { $0.qualifiedName < $1.qualifiedName }
        }
    }

    // MARK: - Location

    /// The name of `node`'s declaration in its source file (the project's, or an attached
    /// `src.zip` / sources JAR). `nil` for a class file with no source: a hierarchy never
    /// decompiles.
    public func location(of node: JavaTypeHierarchyNode, file: URL?) async -> JavaTypeHierarchyLocation? {
        guard let tree = JavaSyntaxParser().parse("") else { return nil }
        let session = makeSession(source: "", fileURL: nil, tree: tree, byteOffset: 0)
        return await scoped(file) {
            guard let hit = await session.typeHits(qualifiedName: node.qualifiedName).first else { return nil }
            return JavaTypeHierarchyLocation(url: hit.url, range: hit.range)
        }
    }

    // MARK: - Helpers

    private func makeSession(source: String, fileURL: URL?, tree: JavaSyntaxTree, byteOffset: Int) -> JavaNavigationSession {
        JavaNavigationSession(
            source: source, fileURL: fileURL, tree: tree, byteOffset: byteOffset,
            index: index, jdkHome: jdkHome, cacheRoot: indexPaths.root, openBuffer: openBuffer,
            decompile: JavaDecompileGate(policy: .denied)
        )
    }

    /// Runs `body` with the file's source-set scope and the open-buffer lookup installed.
    private func scoped<T: Sendable>(_ file: URL?, _ body: @Sendable @escaping () async -> T) async -> T {
        let lookup = openBuffer
        if let file, let classpathModel, let classpathPaths,
           let scope = classpathModel.visibleShardPaths(forFile: file, paths: classpathPaths) {
            return await JavaIndex.$queryScope.withValue(scope) {
                await JavaMemberLookup.$sourceTextProvider.withValue(lookup) { await body() }
            }
        }
        return await JavaMemberLookup.$sourceTextProvider.withValue(lookup) { await body() }
    }

    private static func node(for stub: JavaClassStub, path: [String]) -> JavaTypeHierarchyNode {
        let origin: JavaTypeHierarchyNode.Origin
        switch stub.origin {
        case .source: origin = .source
        case .jar: origin = .jar
        case .jdkModule: origin = .jdk
        }
        let display = stub.packageName.isEmpty || !stub.qualifiedName.hasPrefix(stub.packageName + ".")
            ? stub.qualifiedName
            : String(stub.qualifiedName.dropFirst(stub.packageName.count + 1))
        return JavaTypeHierarchyNode(
            qualifiedName: stub.qualifiedName, displayName: display, packageName: stub.packageName,
            kind: stub.kind, origin: origin, path: path
        )
    }
}
