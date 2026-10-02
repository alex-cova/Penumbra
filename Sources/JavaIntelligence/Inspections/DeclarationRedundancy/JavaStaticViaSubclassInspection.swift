import EditorIntelligence
import Foundation

/// `Sub.helper()` where `helper` is a static member that only a superclass in this file declares.
enum JavaStaticViaSubclassInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.staticViaSubclass
    static let nodeTypes: Set<String> = ["method_invocation", "field_access"]

    private static func members(named name: String, in declaration: SyntaxNode) -> [SyntaxNode] {
        JavaClassShape.members(of: declaration).filter { member in
            switch member.type {
            case "method_declaration": member.child(byFieldName: "name")?.text == name
            case "field_declaration":
                member.namedChildren(ofType: "variable_declarator").contains { $0.child(byFieldName: "name")?.text == name }
            case "class_declaration", "interface_declaration", "enum_declaration", "record_declaration":
                member.child(byFieldName: "name")?.text == name
            default: false
            }
        }
    }

    /// The qualifier and the superclass that declares the static member it is accessed through.
    private static func resolve(_ node: SyntaxNode) -> (qualifier: SyntaxNode, owner: String)? {
        guard let qualifier = node.child(byFieldName: "object"), qualifier.type == "identifier", qualifier.text.first?.isUppercase == true,
              let member = node.child(byFieldName: node.type == "method_invocation" ? "name" : "field")?.text else { return nil }
        let root = node.tree.rootNode
        guard var current = JavaDeclaredTypes.typeDeclaration(named: qualifier.text, in: root), current.type == "class_declaration",
              members(named: member, in: current).isEmpty else { return nil }
        for _ in 0..<8 {
            guard let superclass = current.child(byFieldName: "superclass")?.namedChild(at: 0) else { return nil }
            let name = JavaDeclaredTypes.simpleName(of: superclass)
            guard let parent = JavaDeclaredTypes.typeDeclaration(named: name, in: root), parent.type == "class_declaration" else { return nil }
            let declared = members(named: member, in: parent)
            if !declared.isEmpty {
                return declared.allSatisfy { $0.hasModifier("static") } ? (qualifier, name) : nil
            }
            current = parent
        }
        return nil
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let (qualifier, owner) = resolve(node) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Static member is declared in '\(owner)' but accessed via subclass '\(qualifier.text)'", node: qualifier,
            fixTitle: "Replace with '\(owner)'"
        ))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let qualifier = JavaInspectionSupport.node(of: "identifier", for: diagnostic, tree: tree, source: source),
              let parent = qualifier.parent, let (_, owner) = resolve(parent) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: qualifier.byteRange, with: owner, in: tree)
        return [CodeAction(title: "Replace with '\(owner)'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}
