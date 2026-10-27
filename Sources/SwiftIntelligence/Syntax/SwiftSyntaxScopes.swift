import Foundation
import SwiftLexicalLookup
import SwiftSyntax

/// What name an identifier in an expression refers to, by swift-syntax's own scope rules
/// (`SwiftLexicalLookup`), reduced to the question `SwiftFileModel.bindings` answers: is it a local
/// declaration, and if so which?
///
/// `SwiftFileModel` is built from tree-sitter and resolves names with scopes it computes itself
/// (`guard let` lives to the end of the block, `if let` in its body, and so on). Those rules are
/// hand-written; swift-syntax's are the compiler front end's. This type exists so the two can be
/// compared on real code (`SwiftSyntaxScopeParityTests`) before anything depends on the new one.
public enum SwiftSyntaxScopes {
    /// Where an identifier reference ends up.
    public enum Resolution: Sendable, Equatable {
        /// A parameter, a local variable or constant, a pattern binding, or a function or type
        /// declared inside a body. `declaration` is the UTF-8 byte range of the declaring name.
        /// `case .a(let x), .b(let x)` declares one name twice: `alsoDeclaredAt` holds the others.
        case local(declaration: Range<Int>, alsoDeclaredAt: [Range<Int>])
        /// A name no source text declares: `error` in a `catch`, `newValue` and `oldValue` in an accessor.
        case implicit
        /// Not a local: a member of an enclosing type, a top-level declaration, an imported name or an
        /// implicit closure parameter. The lookup reached a type body or the file without a local match.
        case outer
    }

    public struct Reference: Sendable, Equatable {
        public var name: String
        /// UTF-8 byte range of the identifier in the reference.
        public var bytes: Range<Int>
        public var resolution: Resolution
    }

    /// Every bare identifier reference in an expression (`x`, `foo(…)`), in source order. A name after a
    /// dot (`a.x`) and an implicit member (`.x`) are not references to a local and are left out.
    public static func references(in document: SwiftSyntaxDocument) -> [Reference] {
        let collector = ReferenceCollector(viewMode: .sourceAccurate)
        collector.walk(document.tree)
        return collector.references
    }

    // MARK: - Walk

    private final class ReferenceCollector: SyntaxVisitor {
        var references: [Reference] = []

        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            if let reference = SwiftSyntaxScopes.reference(for: node) { references.append(reference) }
            return .skipChildren
        }
    }

    private static func reference(for node: DeclReferenceExprSyntax) -> Reference? {
        // `a.x`: the node is the member access's name, not a bare reference. `.x` has no base at all.
        if let access = node.parent?.as(MemberAccessExprSyntax.self), access.declName.id == node.id { return nil }
        // Operators, `init`, `self`-like keywords and `$0` are not names a binding can introduce.
        let token = node.baseName
        guard case .identifier = token.tokenKind, let identifier = Identifier(token) else { return nil }

        let start = token.positionAfterSkippingLeadingTrivia.utf8Offset
        let bytes = start..<(start + token.text.utf8.count)
        return Reference(name: token.text, bytes: bytes, resolution: resolution(of: node, identifier: identifier))
    }

    /// The first name `SwiftLexicalLookup` offers from a body, closure, pattern or parameter scope. Reaching
    /// the file scope or a type body first means no local matched.
    private static func resolution(of node: DeclReferenceExprSyntax, identifier: Identifier) -> Resolution {
        for result in node.lookup(identifier) {
            switch result {
            case .fromScope(let scope, let names):
                // Top-level names are the file's; `SwiftFileModel` keeps those as declarations, not bindings.
                if scope.is(SourceFileSyntax.self) { return .outer }
                guard let name = names.first else { continue }
                if case .implicit = name { return .implicit }
                let ranges = declarationBytes(of: name, named: identifier)
                guard let first = ranges.first else { return .outer }
                return .local(declaration: first, alsoDeclaredAt: Array(ranges.dropFirst()))
            case .lookForMembers, .lookForGenericParameters:
                return .outer
            case .lookForImplicitClosureParameters:
                continue
            }
        }
        return .outer
    }

    /// The UTF-8 range of the token that spells the declared name: the local name of a parameter (not its
    /// label), the name of a function or type, the identifier of a pattern.
    private static func declarationBytes(of name: LookupName, named identifier: Identifier) -> [Range<Int>] {
        switch name {
        case .equivalentNames(let names):
            return names.flatMap { declarationBytes(of: $0, named: identifier) }
        case .implicit:
            return []
        case .identifier(let syntax, _), .declaration(let syntax):
            guard let token = nameToken(in: Syntax(syntax), matching: identifier) else { return [] }
            let start = token.positionAfterSkippingLeadingTrivia.utf8Offset
            return [start..<(start + token.text.utf8.count)]
        }
    }

    private static func nameToken(in syntax: Syntax, matching identifier: Identifier) -> TokenSyntax? {
        if let parameter = syntax.as(FunctionParameterSyntax.self) { return parameter.secondName ?? parameter.firstName }
        if let closureParameter = syntax.as(ClosureParameterSyntax.self) { return closureParameter.secondName ?? closureParameter.firstName }
        if let named = syntax.asProtocol(NamedDeclSyntax.self) { return named.name }
        if let token = syntax.as(TokenSyntax.self) { return token }
        // A pattern or other wrapper: the first identifier token spelling the name.
        for token in syntax.tokens(viewMode: .sourceAccurate) where Identifier(token) == identifier { return token }
        return nil
    }
}
