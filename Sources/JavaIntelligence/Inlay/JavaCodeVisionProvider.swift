import EditorIntelligence
import Foundation

/// Which labels ``JavaCodeVisionProvider`` produces.
public struct JavaCodeVisionOptions: Sendable, Equatable {
    /// `3 usages` above classes, methods and constructors.
    public var usages: Bool
    /// `2 implementations` above interfaces, abstract classes and abstract or interface methods.
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
/// are cached by declaration and the index generation, at most ``maxSearches`` run per request and
/// two run at a time. The usage counts therefore follow what the index knows (saved files), not
/// unsaved edits, and refresh when the index does.
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

    // MARK: - CodeVisionProviding

    public func codeVisionAnchors(for document: Document) async -> [Int] {
        guard document.languageIdentifier == "java", (optionsSource?() ?? options).isAnyEnabled else { return [] }
        let source = JavaNavigationText.fullText(of: document)
        guard !source.isEmpty, let tree = JavaSyntaxParser().parse(source) else { return [] }
        return JavaCodeVision.declarations(in: tree, source: source).prefix(Self.maxAnchors).map(\.utf16Offset)
    }

    public func codeVision(for document: Document, anchors: [Int]) async -> [CodeVisionLens] {
        guard document.languageIdentifier == "java" else { return [] }
        let options = optionsSource?() ?? self.options
        guard options.isAnyEnabled else { return [] }
        let source = JavaNavigationText.fullText(of: document)
        guard !source.isEmpty, let tree = JavaSyntaxParser().parse(source) else { return [] }
        let wanted = Set(anchors)
        let declarations = JavaCodeVision.declarations(in: tree, source: source).filter { wanted.contains($0.utf16Offset) }
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
        // Two searches at a time.
        var index = 0
        while index < pending.count, !Task.isCancelled {
            let batch = pending[index ..< min(index + 2, pending.count)]
            index += batch.count
            let results = await withTaskGroup(of: (Int, String, [CodeVisionEntry]).self) { group in
                for item in batch {
                    group.addTask {
                        let entries = await self.entries(
                            for: item.declaration, offset: item.offset, source: source, url: url, options: options,
                            scope: scope, lookup: lookup
                        )
                        return (item.offset, item.key, entries)
                    }
                }
                var collected: [(Int, String, [CodeVisionEntry])] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for (offset, key, entries) in results {
                if cache.count >= Self.maxCachedEntries { cache.removeAll() }
                cache[key] = entries
                lenses.append(CodeVisionLens(utf16Offset: offset, entries: entries))
            }
        }
        return lenses
    }

    // MARK: - Counting

    private func entries(
        for declaration: JavaCodeVision.Declaration, offset: Int, source: String, url: URL?, options: JavaCodeVisionOptions,
        scope: Set<String>?, lookup: (@Sendable (URL) async -> String?)?
    ) async -> [CodeVisionEntry] {
        var entries: [CodeVisionEntry] = []
        if options.usages {
            let usages = await findUsages.findUsages(source: source, url: url, utf16Offset: offset)
            entries.append(CodeVisionEntry(id: "usages", text: JavaCodeVision.label(count: usages.count, singular: "usage", plural: "usages")))
        }
        if options.implementations, declaration.isAbstract {
            let count = await implementationCount(source: source, url: url, offset: offset, scope: scope, lookup: lookup)
            entries.append(CodeVisionEntry(
                id: "implementations",
                text: JavaCodeVision.label(count: count, singular: "implementation", plural: "implementations")
            ))
        }
        return entries
    }

    private func implementationCount(
        source: String, url: URL?, offset: Int, scope: Set<String>?, lookup: (@Sendable (URL) async -> String?)?
    ) async -> Int {
        let index = self.index
        let home = jdkHome
        let cacheRoot = indexPaths.root
        let work = { () async -> Int in
            await JavaGoToImplementation.resolve(
                source: source, fileURL: url, utf16Offset: offset, index: index, jdkHome: home, cacheRoot: cacheRoot, openBuffer: lookup
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
        /// An interface, an abstract class, an abstract method or an interface method: one that is
        /// used through its implementations.
        let isAbstract: Bool
    }

    private static let typeNodes: Set<String> = [
        "class_declaration", "interface_declaration", "enum_declaration", "record_declaration", "annotation_type_declaration"
    ]

    static func declarations(in tree: JavaSyntaxTree, source: String) -> [Declaration] {
        var result: [Declaration] = []
        collect(tree.rootNode, enclosing: [], source: source, into: &result)
        return result
    }

    private static func collect(_ node: SyntaxNode, enclosing: [String], source: String, into result: inout [Declaration]) {
        var path = enclosing
        if typeNodes.contains(node.type), let name = node.child(byFieldName: "name") {
            path.append(name.text)
            result.append(Declaration(
                utf16Offset: JavaNavigationText.utf16Offset(forByte: name.startByte, in: source),
                signature: "type|\(path.joined(separator: "."))",
                isAbstract: node.type == "interface_declaration" || (node.type == "class_declaration" && hasModifier("abstract", in: node))
            ))
        } else if node.type == "method_declaration" || node.type == "constructor_declaration",
                  let name = node.child(byFieldName: "name") {
            let parameters = node.child(byFieldName: "parameters")?.text.filter { !$0.isWhitespace } ?? ""
            let isInterfaceMethod = node.parent?.type == "interface_body"
                && !hasModifier("static", in: node) && !hasModifier("private", in: node) && !hasModifier("default", in: node)
            result.append(Declaration(
                utf16Offset: JavaNavigationText.utf16Offset(forByte: name.startByte, in: source),
                signature: "\(node.type)|\(path.joined(separator: "."))|\(name.text)|\(parameters)",
                isAbstract: hasModifier("abstract", in: node) || isInterfaceMethod
            ))
        }
        for child in node.namedChildren { collect(child, enclosing: path, source: source, into: &result) }
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
