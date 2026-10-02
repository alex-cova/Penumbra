import EditorIntelligence
import Foundation

enum JavaLocalCanBeFinalInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.localCanBeFinal
    static let nodeTypes: Set<String> = ["local_variable_declaration"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.parent?.type != "for_statement", !node.hasModifier("final"),
              node.namedChildren(ofType: "variable_declarator").count == 1,
              let declarator = node.firstNamedChild(ofType: "variable_declarator"), declarator.child(byFieldName: "value") != nil,
              let name = declarator.child(byFieldName: "name") else { return }
        let table = context.tree.declarationCache.fileSymbols(context: context)
        guard let local = table.locals[name.byteRange] else { return }
        let isAssigned = local.uses.contains { JavaLocalUsages.isWrite(context.tree.node(inByteRange: $0)) }
        guard !isAssigned else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Local variable '\(name.text)' can be final", node: name, fixTitle: "Make '\(name.text)' final"
        ))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let name = JavaInspectionSupport.node(of: "identifier", for: diagnostic, tree: tree, source: source),
              let declaration = name.parent?.parent, declaration.type == "local_variable_declaration",
              let type = declaration.child(byFieldName: "type") else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: type.startByte..<type.startByte, with: "final ", in: tree)
        return [CodeAction(title: "Make '\(name.text)' final", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}
