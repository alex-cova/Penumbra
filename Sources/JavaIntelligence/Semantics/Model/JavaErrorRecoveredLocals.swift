import Foundation

/// Locals recovered from `ERROR` regions, for the places the scope tree gives up.
///
/// A method whose body is cut off (a trailing `.`, an unclosed call) often collapses into one flat
/// `ERROR` node: no `method_declaration`, no `block`. The pieces are still there as direct children
/// in source order, the parameters as a `formal_parameters` node and the earlier statements as
/// `local_variable_declaration`s with the `{` and `}` tokens around them, so what was declared
/// before the damage can be read back. ``JavaScopeTree`` recovers members inside corrupt regions
/// but not their locals; ``JavaSyntaxTree/visibleLocals(atByteOffset:)`` adds this to its answer.
///
/// A balanced `{ … }` inside the collapsed method stays a `block` child that is never entered, so
/// the locals of a block that already closed do not leak; the braces that remain flat are the
/// unmatched ones and are tracked so a stray `}` drops what its block declared.
enum JavaErrorRecoveredLocals {
    static func locals(in tree: JavaSyntaxTree, atByteOffset offset: Int) -> [JavaLocalVariable] {
        var result: [JavaLocalVariable] = []
        var seen = Set<String>()
        var current: SyntaxNode? = tree.node(atByteOffset: offset)
        while let node = current {
            if node.type == "ERROR" {
                // tree-sitter prints field labels such as `parameters:` on an ERROR node's children
                // but does not resolve them there; the parameters are found by node type.
                if let parameters = node.namedChildren.first(where: { $0.type == "formal_parameters" }) {
                    for parameter in parameters.namedChildren where parameter.type == "formal_parameter" {
                        guard let typeNode = parameter.child(byFieldName: "type"),
                              let nameNode = parameter.child(byFieldName: "name") else { continue }
                        add(nameNode.text, JavaTypeNodeConverter.convert(typeNode), to: &result, seen: &seen)
                    }
                }
                collectFlatDeclarations(in: node, before: offset, into: &result, seen: &seen)
            }
            current = node.parent
        }
        return result
    }

    /// Innermost, latest declaration first.
    private static func collectFlatDeclarations(
        in node: SyntaxNode, before offset: Int, into result: inout [JavaLocalVariable], seen: inout Set<String>
    ) {
        var frames: [[SyntaxNode]] = [[]]
        for child in node.children where child.startByte < offset {
            switch child.type {
            case "{":
                frames.append([])
            case "}":
                if frames.count > 1 { frames.removeLast() }
            case "local_variable_declaration":
                if child.endByte <= offset { frames[frames.count - 1].append(child) }
            default:
                break
            }
        }
        for frame in frames.reversed() {
            for declaration in frame.reversed() { collect(declaration, into: &result, seen: &seen) }
        }
    }

    /// `var x = …;` keeps `.unresolved("var")` and the initializer text, which the typer resolves.
    private static func collect(_ node: SyntaxNode, into result: inout [JavaLocalVariable], seen: inout Set<String>) {
        guard let typeNode = node.child(byFieldName: "type") else { return }
        let isVar = typeNode.text == "var"
        let type = JavaTypeNodeConverter.convert(typeNode)
        for declarator in node.namedChildren(ofType: "variable_declarator") {
            guard let nameNode = declarator.child(byFieldName: "name"), seen.insert(nameNode.text).inserted else { continue }
            result.append(JavaLocalVariable(
                name: nameNode.text,
                type: isVar ? .unresolved(simpleName: "var", arguments: []) : type,
                initializerText: isVar ? declarator.child(byFieldName: "value")?.text : nil
            ))
        }
    }

    private static func add(_ name: String, _ type: JavaTypeRef, to result: inout [JavaLocalVariable], seen: inout Set<String>) {
        guard seen.insert(name).inserted else { return }
        result.append(JavaLocalVariable(name: name, type: type))
    }
}
