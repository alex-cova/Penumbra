import EditorIntelligence
import Foundation

/// A local variable nothing reads or writes after its declaration. Built on the per-file symbol
/// table (`JavaSemanticWalker`'s scope chain), so a shadowing field or a same-named variable in
/// another method never counts as a use.
enum JavaUnusedLocalVariableInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.unusedLocalVariable
    static let nodeTypes: Set<String> = ["local_variable_declaration"]

    private static let scopes: Set<String> = ["block", "switch_block_statement_group", "constructor_body"]
    /// Initializers that run no code, so removing the variable removes nothing else.
    private static let inertValues: Set<String> = [
        "string_literal", "character_literal", "decimal_integer_literal", "hex_integer_literal", "octal_integer_literal",
        "binary_integer_literal", "decimal_floating_point_literal", "hex_floating_point_literal", "true", "false",
        "null_literal", "identifier", "this",
    ]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let parent = node.parent, scopes.contains(parent.type) else { return }
        let table = context.tree.declarationCache.fileSymbols(context: context)
        for declarator in node.namedChildren(ofType: "variable_declarator") {
            guard let name = declarator.child(byFieldName: "name"), name.text != "_",
                  let local = table.locals[name.byteRange], local.uses.isEmpty else { continue }
            report(JavaInspectionSupport.inspection(
                rule, message: "Variable '\(name.text)' is never used", node: name,
                fixTitle: isRemovable(node) ? "Remove variable '\(name.text)'" : nil
            ))
        }
    }

    private static func isRemovable(_ declaration: SyntaxNode) -> Bool {
        let declarators = declaration.namedChildren(ofType: "variable_declarator")
        guard declarators.count == 1 else { return false }
        guard let value = declarators[0].child(byFieldName: "value") else { return true }
        return inertValues.contains(value.unparenthesized.type)
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let name = JavaInspectionSupport.node(of: "identifier", for: diagnostic, tree: tree, source: source),
              let declarator = name.parent, declarator.type == "variable_declarator",
              let declaration = declarator.parent, declaration.type == "local_variable_declaration",
              isRemovable(declaration) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: JavaSourceBytes.removalRange(of: declaration), with: "", in: tree)
        return [CodeAction(title: "Remove variable '\(name.text)'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// A private field with an initializer that nothing in the file assigns again. Conservative: any
/// assignment to a name equal to the field's (a local, a parameter, `other.field`) keeps it quiet,
/// and a class with annotations (Lombok setters, injection) is left alone.
enum JavaFieldCanBeFinalInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.fieldCanBeFinal
    static let nodeTypes: Set<String> = ["field_declaration"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.hasModifier("private"), !node.hasModifier("final"), !node.hasModifier("volatile"), !node.hasAnnotation,
              let body = node.parent, body.type == "class_body", let owner = body.parent, owner.type == "class_declaration",
              !owner.hasAnnotation else { return }
        let declarators = node.namedChildren(ofType: "variable_declarator")
        guard declarators.count == 1, let declarator = declarators.first, declarator.child(byFieldName: "value") != nil,
              let name = declarator.child(byFieldName: "name") else { return }
        let assigned = context.tree.declarationCache.assignedNames(root: context.tree.rootNode)
        guard !assigned.contains(name.text) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Field '\(name.text)' may be 'final'", node: name, fixTitle: "Make '\(name.text)' final"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let name = JavaInspectionSupport.node(of: "identifier", for: diagnostic, tree: tree, source: source),
              let declarator = name.parent, declarator.type == "variable_declarator",
              let field = declarator.parent, field.type == "field_declaration",
              let type = field.child(byFieldName: "type") else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: type.startByte..<type.startByte, with: "final ", in: tree)
        return [CodeAction(title: "Make '\(name.text)' final", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}
