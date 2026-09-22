import Foundation

/// A local variable, parameter, loop variable, or resource variable visible at some point in a
/// method/constructor body.
public struct JavaLocalVariable: Sendable, Equatable {
    public let name: String
    public let type: JavaTypeRef

    public init(name: String, type: JavaTypeRef) {
        self.name = name
        self.type = type
    }
}

/// Collects the locals visible at a byte offset in a live (possibly still-being-typed) source
/// file: method/constructor parameters, local variable declarations in enclosing blocks that occur
/// textually before the offset, enhanced-for loop variables, and try-with-resources variables --
/// by walking up the tree from the offset through its ancestors.
///
/// Best-effort by design: a trigger `.` with nothing typed after it, on anything more than a bare
/// identifier (a field chain like `bar.value.`, `this.`, a method-call chain, ...), reliably
/// collapses the *entire* enclosing declaration into one `ERROR` node at the file's root instead of
/// staying contained in its block (confirmed empirically -- see `JavaReceiverScanner`'s doc
/// comment). tree-sitter still attaches whatever fields it matched before giving up directly onto
/// that `ERROR` node, so a `parameters:` field survives even when the method's `body:`/`block`
/// wrapper is lost entirely -- meaning any local variable declared earlier in the same corrupted
/// method body is genuinely unrecoverable from this parse, not just harder to reach. This collector
/// still recovers parameters in that case (the most common thing a receiver chain continues from),
/// documented here rather than silently missing locals with no explanation.
///
/// Known simplifications, deferred rather than guessed at: catch-clause parameters and
/// `instanceof` pattern-variable bindings are not yet collected.
public enum JavaLocalScope {
    public static func locals(in tree: JavaSyntaxTree, atByteOffset offset: Int) -> [JavaLocalVariable] {
        var result: [JavaLocalVariable] = []
        var seenNames = Set<String>() // innermost/first-encountered declaration wins on shadowing.
        var current: SyntaxNode? = tree.node(atByteOffset: offset)

        while let node = current {
            switch node.type {
            case "block", "constructor_body":
                for statement in node.namedChildren where statement.type == "local_variable_declaration" && statement.endByte <= offset {
                    collectLocalVariableDeclaration(statement, into: &result, seenNames: &seenNames)
                }
            case "method_declaration", "constructor_declaration":
                if let parameters = node.child(byFieldName: "parameters") {
                    for parameter in parameters.namedChildren where parameter.type == "formal_parameter" {
                        collectFormalParameter(parameter, into: &result, seenNames: &seenNames)
                    }
                }
            case "lambda_expression":
                if let parameters = node.child(byFieldName: "parameters"), parameters.type == "formal_parameters" {
                    for parameter in parameters.namedChildren where parameter.type == "formal_parameter" {
                        collectFormalParameter(parameter, into: &result, seenNames: &seenNames)
                    }
                } else if let single = node.child(byFieldName: "parameters"), single.type == "identifier" {
                    // A single-parameter lambda without parens (`x -> ...`) binds directly to an
                    // `identifier`, not a `formal_parameters` list; its type can't be known without
                    // inferring the functional interface's abstract method, so it's left unresolved.
                    addIfNew(name: single.text, type: .unresolved(simpleName: "Object", arguments: []), into: &result, seenNames: &seenNames)
                }
            case "ERROR":
                // tree-sitter's debug printer (`ts_node_string`) shows field labels like
                // `parameters:` on an ERROR node's children, but `ts_node_child_by_field_name`
                // doesn't actually resolve them there (confirmed empirically) -- those labels are
                // cosmetic on ERROR nodes, not queryable fields. Found by node type instead.
                if let parameters = node.namedChildren.first(where: { $0.type == "formal_parameters" }) {
                    for parameter in parameters.namedChildren where parameter.type == "formal_parameter" {
                        collectFormalParameter(parameter, into: &result, seenNames: &seenNames)
                    }
                }
            case "enhanced_for_statement":
                if let body = node.child(byFieldName: "body"), offset >= body.startByte,
                   let typeNode = node.child(byFieldName: "type"), let nameNode = node.child(byFieldName: "name") {
                    addIfNew(name: nameNode.text, type: JavaTypeNodeConverter.convert(typeNode), into: &result, seenNames: &seenNames)
                }
            case "try_with_resources_statement":
                if let spec = node.firstNamedChild(ofType: "resource_specification") {
                    for resource in spec.namedChildren where resource.type == "resource" {
                        guard let typeNode = resource.child(byFieldName: "type"), let nameNode = resource.child(byFieldName: "name") else { continue }
                        addIfNew(name: nameNode.text, type: JavaTypeNodeConverter.convert(typeNode), into: &result, seenNames: &seenNames)
                    }
                }
            default:
                break
            }
            current = node.parent
        }
        return result
    }

    /// `var x = ...;` declarations aren't given their inferred type here -- that would mean typing
    /// the initializer expression, which is `JavaExpressionTyper`'s job, and this collector has no
    /// dependency on it. A `var`-declared local resolves to `.unresolved(simpleName: "var")`
    /// (effectively "unknown"); teaching `JavaExpressionTyper` to special-case its own locals'
    /// `var` initializers is a reasonable follow-up, not attempted here.
    private static func collectLocalVariableDeclaration(_ node: SyntaxNode, into result: inout [JavaLocalVariable], seenNames: inout Set<String>) {
        guard let typeNode = node.child(byFieldName: "type") else { return }
        let type = JavaTypeNodeConverter.convert(typeNode)
        for declarator in node.namedChildren(ofType: "variable_declarator") {
            guard let nameNode = declarator.child(byFieldName: "name") else { continue }
            addIfNew(name: nameNode.text, type: type, into: &result, seenNames: &seenNames)
        }
    }

    private static func collectFormalParameter(_ node: SyntaxNode, into result: inout [JavaLocalVariable], seenNames: inout Set<String>) {
        guard let typeNode = node.child(byFieldName: "type"), let nameNode = node.child(byFieldName: "name") else { return }
        addIfNew(name: nameNode.text, type: JavaTypeNodeConverter.convert(typeNode), into: &result, seenNames: &seenNames)
    }

    private static func addIfNew(name: String, type: JavaTypeRef, into result: inout [JavaLocalVariable], seenNames: inout Set<String>) {
        guard seenNames.insert(name).inserted else { return }
        result.append(JavaLocalVariable(name: name, type: type))
    }
}
