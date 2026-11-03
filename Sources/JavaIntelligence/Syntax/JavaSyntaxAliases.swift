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

    /// The locals visible at `offset`, from the memoized scope tree (JLS 6.3): pattern bindings in
    /// `switch` rules, negated `instanceof` flow-out, record patterns and guards included, which the
    /// older per-query `JavaLocalScope.locals(in:atByteOffset:)` does not see. For callers that need
    /// the variables only, not declaration sites, so no file URL is involved.
    ///
    /// The scope tree loses locals inside `ERROR` regions (an unfinished statement around the
    /// caret, F14), which `JavaLocalScope` recovers, so its answers are kept for any name the tree
    /// does not know. The result is only ever larger than either source alone.
    func visibleLocals(atByteOffset offset: Int) -> [JavaLocalVariable] {
        let fromTree = JavaScopeTree.locals(in: self, enclosingExecutableAtByteOffset: offset)
            ?? scopeTree(for: Self.localsOnlyURL).locals(atByteOffset: offset)
        let known = Set(fromTree.map(\.name))
        return fromTree + JavaLocalScope.locals(in: self, atByteOffset: offset).filter { !known.contains($0.name) }
    }

    private static var localsOnlyURL: URL { URL(fileURLWithPath: "/__umbra_locals_only__.java") }
}
