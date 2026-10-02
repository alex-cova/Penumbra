import Foundation

/// Per-file facts the usage-based rules share: every local variable and parameter with the
/// identifier ranges that use it (from the scope chain `JavaSemanticWalker` keeps), and every
/// `identifier` / `type_identifier` by name. Built once per tree (`JavaDeclarationCache.fileSymbols`).
struct JavaFileSymbolTable {
    struct Local {
        /// The declaring identifier.
        let declaration: Range<Int>
        /// Reads and writes, sorted, without the declaration.
        var uses: [Range<Int>]
    }

    /// Locals by the byte range of their declaring identifier.
    let locals: [Range<Int>: Local]
    /// Every identifier and type identifier by name (declarations included).
    let occurrences: [String: [Range<Int>]]
    /// The declaring identifier of the local each use belongs to.
    let localOfUse: [Range<Int>: Range<Int>]
    /// Identifier ranges that belong to a local (declaration or use), so a field of the same name is told apart.
    let localIdentifiers: Set<Range<Int>>

    static func build(tree: JavaSyntaxTree, source: String) -> JavaFileSymbolTable {
        var uses: [Range<Int>: Set<Range<Int>>] = [:]
        var declarations = Set<Range<Int>>()
        let walker = JavaSemanticWalker(tree: tree, source: source)
        walker.localSink = { declaration, identifier, isDeclaration in
            declarations.insert(declaration)
            if isDeclaration { return }
            uses[declaration, default: []].insert(identifier)
        }
        _ = walker.run()
        var locals: [Range<Int>: Local] = [:]
        var localIdentifiers = Set<Range<Int>>()
        var localOfUse: [Range<Int>: Range<Int>] = [:]
        for declaration in declarations {
            let sorted = (uses[declaration] ?? []).sorted { $0.lowerBound < $1.lowerBound }
            locals[declaration] = Local(declaration: declaration, uses: sorted)
            localIdentifiers.insert(declaration)
            localIdentifiers.formUnion(sorted)
            for use in sorted { localOfUse[use] = declaration }
        }
        var occurrences: [String: [Range<Int>]] = [:]
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
            if node.type == "identifier" || node.type == "type_identifier" {
                occurrences[node.text, default: []].append(node.byteRange)
            } else {
                stack.append(contentsOf: node.namedChildren)
            }
        }
        return JavaFileSymbolTable(locals: locals, occurrences: occurrences, localOfUse: localOfUse, localIdentifiers: localIdentifiers)
    }

    /// Identifier occurrences of `name` that are neither `excluding` nor a local's declaration or use.
    func nonLocalOccurrences(of name: String, excluding: Range<Int>) -> [Range<Int>] {
        (occurrences[name] ?? []).filter { $0 != excluding && !localIdentifiers.contains($0) }
    }
}

extension SyntaxNode {
    /// Whether the declaration's `modifiers` contain the keyword (`private`, `final`, `static`, …).
    func hasModifier(_ keyword: String) -> Bool {
        firstNamedChild(ofType: "modifiers")?.children.contains { $0.type == keyword } == true
    }

    /// Whether the declaration carries any annotation.
    var hasAnnotation: Bool {
        firstNamedChild(ofType: "modifiers")?.namedChildren.contains { $0.type == "annotation" || $0.type == "marker_annotation" } == true
    }
}
