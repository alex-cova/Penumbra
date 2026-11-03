import Foundation
import LanguageSyntax
import TreeSitterJava

/// Java's public parser names. The types live in `LanguageSyntax`; these aliases keep every
/// JavaIntelligence call site on the names it already uses.
public typealias JavaSyntaxTree = LanguageSyntax.SyntaxTree
public typealias JavaSyntaxParser = SyntaxParser
public typealias JavaDocumentParseCache = DocumentParseCache
public typealias JavaParseEdit = ParseEdit
public typealias SyntaxNode = LanguageSyntax.SyntaxNode

public extension SyntaxParser {
    /// The Java grammar. The pointer is chosen here, not as a default argument on ``SyntaxParser``,
    /// so a client that also imports Tree-sitter is not asked to re-check the pointer type.
    convenience init() {
        self.init(language: tree_sitter_java())
    }
}

public extension DocumentParseCache {
    /// A cache for Java documents.
    init() {
        self.init(languageIdentifier: "java", language: tree_sitter_java())
    }
}

extension JavaSyntaxTree {
    /// Memoized declaration lookups for the inspections. One cache per parse.
    var declarationCache: JavaDeclarationCache {
        attachment.object(JavaDeclarationCache.self, create: JavaDeclarationCache.init)
    }

    /// The memoized lexical scope tree (JLS 6.3) for a file: built once per parse, then queried
    /// by byte offset. The URL rides along because a parse doesn't know its file.
    func scopeTree(for url: URL) -> JavaScopeTree {
        attachment.object(JavaScopeTreeCache.self, create: JavaScopeTreeCache.init)
            .tree(for: url, build: { JavaScopeTree(tree: self, url: url) })
    }

    /// The locals visible at `offset`: the scope tree's (JLS 6.3 scopes, pattern bindings in
    /// `switch` rules and negated `instanceof` included) for the outermost method or constructor
    /// around it, plus what ``JavaErrorRecoveredLocals`` reads back from a collapsed `ERROR` region.
    /// No file URL is involved: callers need the variables, not declaration sites.
    ///
    /// The tree puts a local in scope inside its own initializer (JLS 6.3), which is right for the
    /// tree and wrong for completion and receiver typing: `String s = <caret>` must not offer `s`
    /// (javac rejects it), so the variable whose declarator holds the offset is dropped.
    func visibleLocals(atByteOffset offset: Int) -> [JavaLocalVariable] {
        let fromTree = JavaScopeTree.locals(in: self, enclosingExecutableAtByteOffset: offset)
            ?? scopeTree(for: Self.localsOnlyURL).locals(atByteOffset: offset)
        let known = Set(fromTree.map(\.name))
        let merged = fromTree + JavaErrorRecoveredLocals.locals(in: self, atByteOffset: offset).filter { !known.contains($0.name) }
        let initializing = namesBeingInitialized(atByteOffset: offset)
        return initializing.isEmpty ? merged : merged.filter { !initializing.contains($0.name) }
    }

    /// Variables whose declarator contains `offset` after the name, i.e. the caret is in their
    /// own initializer.
    private func namesBeingInitialized(atByteOffset offset: Int) -> Set<String> {
        var names = Set<String>()
        var current: SyntaxNode? = node(atByteOffset: offset)
        while let node = current {
            if node.type == "variable_declarator", let name = node.child(byFieldName: "name"),
               offset >= name.endByte, offset <= node.endByte {
                names.insert(name.text)
            }
            current = node.parent
        }
        return names
    }

    private static var localsOnlyURL: URL { URL(fileURLWithPath: "/__umbra_locals_only__.java") }
}
