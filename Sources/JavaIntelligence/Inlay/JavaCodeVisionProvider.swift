import EditorIntelligence
import Foundation

/// Which labels ``JavaCodeVisionProvider`` produces.
public struct JavaCodeVisionOptions: Sendable, Equatable {
    /// `3 usages` above classes, methods and constructors.
    public var usages: Bool
    /// `2 implementations` above interfaces, abstract classes and abstract or interface methods,
    /// `2 subclasses` above other classes that have some, and `2 overrides` above methods that
    /// subclasses override.
    public var implementations: Bool

    public init(usages: Bool = true, implementations: Bool = true) {
        self.usages = usages
        self.implementations = implementations
    }

    public var isAnyEnabled: Bool {
        usages || implementations
    }
}

/// Code vision for Java: a lens above every class, interface, enum, record, method and constructor,
/// with its usage count and, for declarations that only make sense through their implementations,
/// how many project types implement them.
///
/// ``codeVisionAnchors(for:)`` is one pass over the syntax tree and reserves the room for every
/// declaration. ``codeVision(for:anchors:)`` then searches for the anchors on screen. A search is the
/// expensive part (it resolves the symbol and parses the files that mention its name), so results
/// are cached by declaration and index generation, with at most ``maxSearches`` per request.
/// Usage searches share candidate file parsing, and implementation searches run two at a time.
public actor JavaCodeVisionProvider: CodeVisionProviding {
    /// Most declarations given lenses in one file.
    static let maxAnchors = 400
    /// Most declarations searched for in one request.
    static let maxSearches = 40
    private static let maxCachedEntries = 3000

    private let index: JavaIndex
    private let indexPaths: JavaIndexPaths
    private let findUsages: JavaFindUsagesProvider
    private var classpathModel: JavaGradleProjectModel?
    private var classpathPaths: JavaIndexPaths?
    private var openBuffer: (@Sendable (URL) async -> String?)?
    private var jdkHome: URL?
    private var options = JavaCodeVisionOptions()
    private var isIndexReady: (@Sendable (URL?) async -> Bool)?
    private var optionsSource: (@Sendable () -> JavaCodeVisionOptions)?
    private var cache: [String: [CodeVisionEntry]] = [:]

    public init(index: JavaIndex, indexPaths: JavaIndexPaths, findUsages: JavaFindUsagesProvider) {
        self.index = index
        self.indexPaths = indexPaths
        self.findUsages = findUsages
    }

    public func setSourceSetClasspath(_ model: JavaGradleProjectModel?, indexPaths: JavaIndexPaths) {
        classpathModel = model
        classpathPaths = model == nil ? nil : indexPaths
        cache.removeAll()
    }

    public func setOpenBufferLookup(_ lookup: (@Sendable (URL) async -> String?)?) {
        openBuffer = lookup
    }

    public func setJDKHome(_ home: URL?) {
        jdkHome = home
    }

    public func setOptions(_ options: JavaCodeVisionOptions) {
        self.options = options
    }

    /// Asks `source` for the options at the start of every request, so a host's settings apply
    /// without being pushed.
    public func setOptionsSource(_ source: (@Sendable () -> JavaCodeVisionOptions)?) {
        optionsSource = source
    }

    public func setIndexReadiness(_ readiness: @escaping @Sendable (URL?) async -> Bool) {
        isIndexReady = readiness
        cache.removeAll()
    }

    // MARK: - CodeVisionProviding

    public func codeVisionAnchors(for document: Document) async -> [Int] {
        guard document.languageIdentifier == "java", (optionsSource?() ?? options).isAnyEnabled else { return [] }
        let source = JavaNavigationText.fullText(of: document)
        guard !source.isEmpty, !Task.isCancelled, let tree = JavaParseMemo.shared.tree(for: source) else { return [] }
        return JavaCodeVision.declarations(in: tree, source: source, limit: Self.maxAnchors).map(\.utf16Offset)
    }

    public func codeVision(for document: Document, anchors: [Int]) async -> [CodeVisionLens] {
        guard document.languageIdentifier == "java" else { return [] }
        let options = optionsSource?() ?? self.options
        guard options.isAnyEnabled else { return [] }
        let source = JavaNavigationText.fullText(of: document)
        guard !source.isEmpty, !Task.isCancelled, let tree = JavaParseMemo.shared.tree(for: source) else { return [] }
        if let isIndexReady, !(await isIndexReady(document.url)) {
            return anchors.map { CodeVisionLens(utf16Offset: $0, entries: []) }
        }
        let wanted = Set(anchors)
        let declarations = JavaCodeVision.declarations(in: tree, source: source, limit: Self.maxAnchors)
            .filter { wanted.contains($0.utf16Offset) }
        let generation = await index.generation
        let url = document.url
        let lookup = openBuffer
        let scope = scope(for: url)
        var lenses: [CodeVisionLens] = []
        var searches = 0
        var pending: [(declaration: JavaCodeVision.Declaration, offset: Int, key: String)] = []
        for declaration in declarations {
            let offset = declaration.utf16Offset
            let key = "\(url?.path ?? "")|\(declaration.signature)|\(generation)|\(options.usages)|\(options.implementations)"
            if let cached = cache[key] {
                lenses.append(CodeVisionLens(utf16Offset: offset, entries: cached))
            } else if searches < Self.maxSearches {
                searches += 1
                pending.append((declaration, offset, key))
            }
        }
        let usageCounts = if options.usages, !pending.isEmpty {
            await findUsages.declarationUsageCounts(source: source, url: url, offsets: pending.map { $0.offset })
        } else {
            [Int: Int]()
        }
        guard !Task.isCancelled, await self.index.generation == generation else { return [] }

        // Two implementation searches at a time.
        var index = 0
        while index < pending.count, !Task.isCancelled {
            let batch = pending[index ..< min(index + 2, pending.count)]
            index += batch.count
            let results = await withTaskGroup(of: (Int, String, [CodeVisionEntry]).self) { group in
                for item in batch {
                    group.addTask {
                        let entries = await self.entries(
                            for: item.declaration, offset: item.offset, source: source, tree: tree, url: url, options: options,
                            usageCount: usageCounts[item.offset],
                            scope: scope, lookup: lookup
                        )
                        return (item.offset, item.key, entries)
                    }
                }
                var collected: [(Int, String, [CodeVisionEntry])] = []
                for await result in group { collected.append(result) }
                return collected
            }
            guard !Task.isCancelled, await self.index.generation == generation else { return [] }
            for (offset, key, entries) in results {
                if cache.count >= Self.maxCachedEntries { cache.removeAll() }
                cache[key] = entries
                lenses.append(CodeVisionLens(utf16Offset: offset, entries: entries))
            }
        }
        guard !Task.isCancelled, await self.index.generation == generation else { return [] }
        return lenses
    }

    // MARK: - Counting

    private func entries(
        for declaration: JavaCodeVision.Declaration, offset: Int, source: String, tree: JavaSyntaxTree, url: URL?,
        options: JavaCodeVisionOptions, usageCount: Int?, scope: Set<String>?, lookup: (@Sendable (URL) async -> String?)?
    ) async -> [CodeVisionEntry] {
        var entries: [CodeVisionEntry] = []
        if let usageCount {
            entries.append(CodeVisionEntry(id: "usages", text: JavaCodeVision.label(count: usageCount, singular: "usage", plural: "usages")))
        }
        guard options.implementations, declaration.inheritance != .none else { return entries }
        let count = await implementationCount(source: source, tree: tree, url: url, offset: offset, scope: scope, lookup: lookup)
        switch declaration.inheritance {
        case .abstract:
            // Only meaningful through its implementations, so "no implementations" is information.
            entries.append(CodeVisionEntry(
                id: "implementations",
                text: JavaCodeVision.label(count: count, singular: "implementation", plural: "implementations")
            ))
        case .subclassable:
            // Most classes have none: a label on every one would be noise.
            if count > 0 {
                entries.append(CodeVisionEntry(
                    id: "subclasses", text: JavaCodeVision.label(count: count, singular: "subclass", plural: "subclasses")
                ))
            }
        case .overridable:
            if count > 0 {
                entries.append(CodeVisionEntry(
                    id: "overrides", text: JavaCodeVision.label(count: count, singular: "override", plural: "overrides")
                ))
            }
        case .none:
            break
        }
        return entries
    }

    private func implementationCount(
        source: String, tree: JavaSyntaxTree, url: URL?, offset: Int, scope: Set<String>?,
        lookup: (@Sendable (URL) async -> String?)?
    ) async -> Int {
        let index = self.index
        let home = jdkHome
        let cacheRoot = indexPaths.root
        let work = { () async -> Int in
            await JavaGoToImplementation.resolve(
                source: source, fileURL: url, utf16Offset: offset, index: index, jdkHome: home, cacheRoot: cacheRoot,
                openBuffer: lookup, tree: tree
            ).count
        }
        return await JavaMemberLookup.$sourceTextProvider.withValue(lookup) {
            if let scope {
                return await JavaIndex.$queryScope.withValue(scope) { await work() }
            }
            return await work()
        }
    }

    private func scope(for url: URL?) -> Set<String>? {
        guard let url, let classpathModel, let classpathPaths else { return nil }
        return classpathModel.visibleShardPaths(forFile: url, paths: classpathPaths)
    }
}

/// The declarations that get a lens, found in a syntax tree.
enum JavaCodeVision {
    struct Declaration: Sendable {
        /// UTF-16 offset of the declaration's name.
        let utf16Offset: Int
        /// Identifies the declaration across edits: `kind|Outer.Inner|name|parameters`.
        let signature: String
        /// What the declaration has below it: see ``Inheritance``.
        let inheritance: Inheritance
    }

    /// How a declaration is used by the types below it.
    enum Inheritance: Sendable, Equatable {
        /// Nothing can extend or override it: a constructor, an enum, a record, a `final` or `static` member.
        case none
        /// An interface, an abstract class, an abstract method or an interface method: one that is
        /// used through its implementations.
        case abstract
        /// A class that can be extended.
        case subclassable
        /// A method that subclasses can override.
        case overridable
    }

    private static let typeNodes: Set<String> = [
        "class_declaration", "interface_declaration", "enum_declaration", "record_declaration", "annotation_type_declaration"
    ]

    static func declarations(in tree: JavaSyntaxTree, source: String, limit: Int) -> [Declaration] {
        var result: [Declaration] = []
        collect(tree.rootNode, enclosing: [], source: source, limit: limit, into: &result)
        return result
    }

    private static func collect(
        _ node: SyntaxNode, enclosing: [String], source: String, limit: Int, into result: inout [Declaration]
    ) {
        guard result.count < limit, !Task.isCancelled else { return }
        var path = enclosing
        if typeNodes.contains(node.type), let name = node.child(byFieldName: "name") {
            path.append(name.text)
            result.append(Declaration(
                utf16Offset: JavaNavigationText.utf16Offset(forByte: name.startByte, in: source),
                signature: "type|\(path.joined(separator: "."))",
                inheritance: typeInheritance(node)
            ))
        } else if node.type == "method_declaration" || node.type == "constructor_declaration",
                  let name = node.child(byFieldName: "name") {
            let parameters = node.child(byFieldName: "parameters")?.text.filter { !$0.isWhitespace } ?? ""
            result.append(Declaration(
                utf16Offset: JavaNavigationText.utf16Offset(forByte: name.startByte, in: source),
                signature: "\(node.type)|\(path.joined(separator: "."))|\(name.text)|\(parameters)",
                inheritance: node.type == "method_declaration" ? methodInheritance(node) : .none
            ))
        }
        node.walkNamedChildren(overlapping: node.byteRange) { child in
            guard result.count < limit, !Task.isCancelled else { return false }
            collect(child, enclosing: path, source: source, limit: limit, into: &result)
            return true
        }
    }

    private static func typeInheritance(_ node: SyntaxNode) -> Inheritance {
        switch node.type {
        case "interface_declaration":
            return .abstract
        case "class_declaration":
            if hasModifier("abstract", in: node) { return .abstract }
            return hasModifier("final", in: node) ? .none : .subclassable
        default:
            return .none
        }
    }

    private static func methodInheritance(_ node: SyntaxNode) -> Inheritance {
        if hasModifier("abstract", in: node) { return .abstract }
        let isInterfaceMember = node.parent?.type == "interface_body"
        if isInterfaceMember {
            if hasModifier("static", in: node) || hasModifier("private", in: node) { return .none }
            // `default` has a body that implementations may replace; any other is abstract.
            return hasModifier("default", in: node) ? .overridable : .abstract
        }
        guard !hasModifier("static", in: node), !hasModifier("private", in: node), !hasModifier("final", in: node),
              let body = node.parent, body.type == "class_body",
              let owner = body.parent, owner.type == "class_declaration", !hasModifier("final", in: owner) else { return .none }
        return .overridable
    }

    private static func hasModifier(_ keyword: String, in declaration: SyntaxNode) -> Bool {
        declaration.namedChildren.first(where: { $0.type == "modifiers" })?.children.contains { $0.type == keyword } == true
    }

    static func label(count: Int, singular: String, plural: String) -> String {
        switch count {
        case 0: return "no \(plural)"
        case 1: return "1 \(singular)"
        default: return "\(count) \(plural)"
        }
    }
}
