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
}
