import EditorIntelligence
import Foundation

/// A private field, method, constructor or nested type that nothing in the file mentions. Private
/// members can only be used inside their file, so a per-file name scan is exact apart from
/// reflection, which is why annotated members and types, serialization hooks and no-argument
/// private constructors are left alone.
enum JavaUnusedPrivateMemberInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.unusedPrivateMember
    static let nodeTypes: Set<String> = [
        "field_declaration", "method_declaration", "constructor_declaration",
        "class_declaration", "interface_declaration", "enum_declaration", "record_declaration",
    ]
    private static let serializationHooks: Set<String> = [
        "readObject", "writeObject", "readResolve", "writeReplace", "readObjectNoData", "serialVersionUID", "serialPersistentFields",
    ]
    private static let typeDeclarations: Set<String> = ["class_declaration", "interface_declaration", "enum_declaration", "record_declaration"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.hasModifier("private"), !node.hasAnnotation, !isInsideAnnotatedType(node) else { return }
        let table = context.tree.declarationCache.fileSymbols(context: context)
        switch node.type {
        case "field_declaration":
            for declarator in node.namedChildren(ofType: "variable_declarator") {
                guard let name = declarator.child(byFieldName: "name"), !serializationHooks.contains(name.text) else { continue }
                if table.occurrences[name.text]?.count == 1 { flag(name, kind: "field", report: report) }
            }
        case "constructor_declaration":
            guard let name = node.child(byFieldName: "name"), let owner = node.parent?.parent, owner.type == "class_declaration",
                  let parameters = node.child(byFieldName: "parameters"), parameters.namedChildCount > 0 else { return }
            if !isConstructorUsed(of: name.text, in: context.tree) { flag(name, kind: "constructor", report: report) }
        default:
            guard let name = node.child(byFieldName: "name"), !serializationHooks.contains(name.text) else { return }
            if table.occurrences[name.text]?.count == 1 {
                flag(name, kind: node.type == "method_declaration" ? "method" : "class", report: report)
            }
        }
    }

    private static func flag(_ name: SyntaxNode, kind: String, report: (JavaInspection) -> Void) {
        report(JavaInspectionSupport.inspection(
            rule, message: "Private \(kind) '\(name.text)' is never used", node: name, fixTitle: "Safe delete '\(name.text)'"
        ))
    }

    private static func isInsideAnnotatedType(_ node: SyntaxNode) -> Bool {
        var current = node.parent
        while let parent = current {
            if typeDeclarations.contains(parent.type), parent.hasAnnotation,
               parent.firstNamedChild(ofType: "modifiers")?.namedChildren.contains(where: { !$0.text.contains("SuppressWarnings") }) == true { return true }
            current = parent.parent
        }
        return false
    }

    /// Whether a `new Name(…)`, `Name::new`, `this(…)` or `super(…)` exists anywhere in the file.
    private static func isConstructorUsed(of className: String, in tree: JavaSyntaxTree) -> Bool {
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
            switch node.type {
            case "object_creation_expression":
                if let type = node.child(byFieldName: "type"), type.text.split(separator: ".").last.map(String.init)?.split(separator: "<").first.map(String.init) == className { return true }
            case "method_reference":
                if node.text.hasSuffix("::new"), node.text.contains(className) { return true }
            case "explicit_constructor_invocation":
                return true
            default:
                break
            }
            stack.append(contentsOf: node.namedChildren)
        }
        return false
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let name = JavaInspectionSupport.node(of: "identifier", for: diagnostic, tree: tree, source: source) else { return [] }
        var declaration = name.parent
        if declaration?.type == "variable_declarator" {
            declaration = declaration?.parent
            guard declaration?.namedChildren(ofType: "variable_declarator").count == 1 else { return [] }
        }
        guard let declaration, nodeTypes.contains(declaration.type) else { return [] }
        return JavaJumpStatements.removeFix(title: "Safe delete '\(name.text)'", node: declaration, in: tree)
    }
}
