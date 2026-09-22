import Foundation

/// Converts a tree-sitter-java "type node" into a ``JavaTypeRef``. Grammar node shapes referenced
/// here were confirmed empirically (see `JavaSyntaxTreeGroundTruthTests` in the test target) rather
/// than assumed, since tree-sitter-java field names are inconsistently applied -- some nodes label
/// their children (`class_declaration name: (identifier)`), others are purely positional
/// (`superclass (type_identifier)`, `scoped_type_identifier` has no `scope:`/`name:` fields even
/// though the near-identical `scoped_identifier` used for package/import paths does).
///
/// A bare `type_identifier` (a single simple name, e.g. `Bar`) can't be told apart syntactically
/// from a reference to an enclosing type parameter -- both are just an identifier token. Rather
/// than track type-parameter scope here (which the source stub builder has no need to do for its
/// own purposes), every simple name becomes `.unresolved(simpleName:arguments:)`; resolving it
/// against type parameters, imports, and the package is `JavaTypeResolver`'s job at query time.
/// A dotted reference (`scoped_type_identifier`, e.g. `java.io.Serializable`) is unambiguous as
/// written, so it becomes a `.classType` directly.
enum JavaTypeNodeConverter {
    static func convert(_ node: SyntaxNode) -> JavaTypeRef {
        switch node.type {
        case "boolean_type":
            return .primitive(.boolean)
        case "void_type":
            return .void
        case "integral_type":
            return primitive(fromKeyword: node.text) ?? .primitive(.int)
        case "floating_point_type":
            return primitive(fromKeyword: node.text) ?? .primitive(.double)

        case "type_identifier":
            return .unresolved(simpleName: node.text, arguments: [])

        case "scoped_type_identifier":
            let dotted = dottedTypeName(node)
            return .classType(qualifiedName: dotted, arguments: [], outer: nil)

        case "generic_type":
            guard let base = node.namedChild(at: 0) else { return .unresolved(simpleName: node.text, arguments: []) }
            let arguments = node.firstNamedChild(ofType: "type_arguments")?.namedChildren.map(convertTypeArgument) ?? []
            switch convert(base) {
            case .classType(let qualifiedName, _, let outer):
                return .classType(qualifiedName: qualifiedName, arguments: arguments, outer: outer)
            case .unresolved(let simpleName, _):
                return .unresolved(simpleName: simpleName, arguments: arguments)
            case let other:
                return other
            }

        case "array_type":
            let elementNode = node.child(byFieldName: "element")
            let element = elementNode.map(convert) ?? .classType(qualifiedName: "java.lang.Object", arguments: [], outer: nil)
            let dimensionCount = max(1, node.child(byFieldName: "dimensions")?.text.filter { $0 == "[" }.count ?? 1)
            var result = element
            for _ in 0..<dimensionCount {
                result = .array(element: result)
            }
            return result

        default:
            // Unknown/unsupported node shape (e.g. a future grammar addition): fall back to the
            // raw text as an unresolved reference rather than losing the type entirely.
            return .unresolved(simpleName: node.text, arguments: [])
        }
    }

    private static func convertTypeArgument(_ node: SyntaxNode) -> JavaTypeArgument {
        if node.type == "wildcard" {
            return .wildcard(convertWildcardBound(node))
        }
        return .type(convert(node))
    }

    /// `(wildcard)` = bare `?`; `(wildcard (type_identifier))` = `? extends T` (no explicit
    /// "extends" marker in the grammar -- a single bound child defaults to extends); `(wildcard
    /// (super) (type_identifier))` = `? super T` (the `super` keyword is, unusually, a *named*
    /// node here, letting it double as the disambiguator).
    private static func convertWildcardBound(_ node: SyntaxNode) -> JavaWildcardBound? {
        let children = node.namedChildren
        guard let first = children.first else { return nil }
        if first.type == "super", children.count > 1 {
            return .superBound(convert(children[1]))
        }
        return .extends(convert(first))
    }

    private static func primitive(fromKeyword text: String) -> JavaTypeRef? {
        switch text {
        case "byte": return .primitive(.byte)
        case "short": return .primitive(.short)
        case "int": return .primitive(.int)
        case "long": return .primitive(.long)
        case "char": return .primitive(.char)
        case "float": return .primitive(.float)
        case "double": return .primitive(.double)
        default: return nil
        }
    }

    /// Reconstructs a dotted name from a `scoped_identifier` (used for `package`/`import` paths;
    /// fields `scope:`/`name:`) or `scoped_type_identifier` (used for qualified type references;
    /// no field labels, purely positional: child 0 is the scope/qualifier, child 1 the final
    /// simple name).
    static func dottedName(_ node: SyntaxNode) -> String {
        switch node.type {
        case "identifier", "type_identifier":
            return node.text
        case "scoped_identifier":
            guard let scope = node.child(byFieldName: "scope"), let name = node.child(byFieldName: "name") else {
                return node.text
            }
            return "\(dottedName(scope)).\(dottedName(name))"
        default:
            return node.text
        }
    }

    static func dottedTypeName(_ node: SyntaxNode) -> String {
        switch node.type {
        case "type_identifier":
            return node.text
        case "scoped_type_identifier":
            let children = node.namedChildren
            guard children.count >= 2 else { return node.text }
            return "\(dottedTypeName(children[0])).\(dottedTypeName(children[1]))"
        default:
            return node.text
        }
    }
}
