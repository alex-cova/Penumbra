import EditorIntelligence
import Foundation

enum JavaTypeMembers {
    static let typeDeclarations: Set<String> = ["class_declaration", "record_declaration", "enum_declaration"]

    /// The methods declared directly in a type's body (an enum's sit under `enum_body_declarations`).
    static func methods(of type: SyntaxNode) -> [SyntaxNode] {
        guard let body = type.child(byFieldName: "body") else { return [] }
        var members = body.namedChildren
        if let declarations = body.firstNamedChild(ofType: "enum_body_declarations") { members.append(contentsOf: declarations.namedChildren) }
        return members.filter { $0.type == "method_declaration" }
    }

    static func parameterTypeNames(of method: SyntaxNode) -> [String] {
        guard let parameters = method.child(byFieldName: "parameters") else { return [] }
        return parameters.namedChildren.compactMap { $0.child(byFieldName: "type").map(JavaDeclaredTypes.simpleName(of:)) }
    }

    static func name(of method: SyntaxNode) -> String? { method.child(byFieldName: "name")?.text }

    static func isEqualsObject(_ method: SyntaxNode) -> Bool {
        name(of: method) == "equals" && parameterTypeNames(of: method) == ["Object"]
    }

    static func isHashCode(_ method: SyntaxNode) -> Bool {
        name(of: method) == "hashCode" && method.child(byFieldName: "parameters")?.namedChildCount == 0
    }
}

enum JavaEqualsHashCodePairInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.equalsHashCodePair
    static let nodeTypes = JavaTypeMembers.typeDeclarations

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        let methods = JavaTypeMembers.methods(of: node)
        let equals = methods.first(where: JavaTypeMembers.isEqualsObject)
        let hashCode = methods.first(where: JavaTypeMembers.isHashCode)
        switch (equals, hashCode) {
        case (let equals?, nil):
            guard !superclassMayDefine(node, context: context, matching: JavaTypeMembers.isHashCode),
                  let name = equals.child(byFieldName: "name") else { return }
            report(JavaInspectionSupport.inspection(rule, message: "Class defines 'equals()' but not 'hashCode()'", node: name))
        case (nil, let hashCode?):
            guard !superclassMayDefine(node, context: context, matching: JavaTypeMembers.isEqualsObject),
                  let name = hashCode.child(byFieldName: "name") else { return }
            report(JavaInspectionSupport.inspection(rule, message: "Class defines 'hashCode()' but not 'equals()'", node: name))
        default:
            return
        }
    }
}

extension JavaEqualsHashCodePairInspection {
    /// Whether an inherited method could be the missing half: a superclass the file does not
    /// declare is unknown, so it counts; one it declares is searched up the chain.
    fileprivate static func superclassMayDefine(
        _ type: SyntaxNode, context: JavaInspectionContext, matching isMethod: (SyntaxNode) -> Bool
    ) -> Bool {
        var current = type
        var seen = Set<String>()
        while let superclass = current.child(byFieldName: "superclass")?.namedChild(at: 0) {
            let name = JavaDeclaredTypes.simpleName(of: superclass)
            guard name != "Object", seen.insert(name).inserted else { return false }
            guard let declaration = JavaDeclaredTypes.typeDeclaration(named: name, in: context.tree.rootNode) else { return true }
            if JavaTypeMembers.methods(of: declaration).contains(where: isMethod) { return true }
            current = declaration
        }
        return false
    }
}

enum JavaCovariantEqualsInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.covariantEquals
    static let nodeTypes = JavaTypeMembers.typeDeclarations

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        let methods = JavaTypeMembers.methods(of: node)
        guard !methods.contains(where: JavaTypeMembers.isEqualsObject) else { return }
        for method in methods where JavaTypeMembers.name(of: method) == "equals" && JavaTypeMembers.parameterTypeNames(of: method).count == 1 {
            guard let name = method.child(byFieldName: "name") else { continue }
            report(JavaInspectionSupport.inspection(rule, message: "'equals()' takes '\(JavaTypeMembers.parameterTypeNames(of: method)[0])', not 'Object', so it does not override 'Object.equals()'", node: name))
        }
    }
}

enum JavaEqualInsteadOfEqualsInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.equalInsteadOfEquals
    static let nodeTypes: Set<String> = ["method_declaration"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard JavaTypeMembers.name(of: node) == "equal", JavaTypeMembers.parameterTypeNames(of: node).count == 1,
              let name = node.child(byFieldName: "name") else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Method 'equal()' is probably meant to be 'equals()'", node: name, fixTitle: "Rename to 'equals'"))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let name = JavaInspectionSupport.node(of: "identifier", for: diagnostic, tree: tree, source: source) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: name.byteRange, with: "equals", in: tree)
        return [CodeAction(title: "Rename to 'equals'", kind: "quickfix", edits: [edit])]
    }
}

enum JavaSubtractionInCompareToInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.subtractionInCompareTo
    static let nodeTypes: Set<String> = ["method_declaration"]
    /// Subtracting these cannot overflow `int`.
    private static let smallTypes: Set<String> = ["char", "short", "byte"]
    private static let boundedCalls: Set<String> = ["length", "size", "ordinal"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = JavaTypeMembers.name(of: node), let body = node.child(byFieldName: "body") else { return }
        let arity = JavaTypeMembers.parameterTypeNames(of: node).count
        guard (name == "compareTo" && arity == 1) || (name == "compare" && arity == 2) else { return }
        body.forEachDescendant { statement in
            // A `return a - b;` that compiles in an `int` method is int arithmetic, so it can overflow.
            guard statement.type == "return_statement", let value = statement.namedChild(at: 0)?.unparenthesized,
                  value.type == "binary_expression", value.operatorText == "-",
                  let left = value.child(byFieldName: "left"), let right = value.child(byFieldName: "right"),
                  !isBounded(left), !isBounded(right) else { return }
            report(JavaInspectionSupport.inspection(rule, message: "Subtraction in '\(name)()' can overflow; use 'Integer.compare()'", node: value))
        }
    }

    private static func isBounded(_ operand: SyntaxNode) -> Bool {
        let node = operand.unparenthesized
        if let type = JavaDeclaredTypes.type(of: node), !type.isArray, smallTypes.contains(type.name) { return true }
        if node.type == "field_access", node.child(byFieldName: "field")?.text == "length" { return true }
        if node.type == "method_invocation", let name = node.child(byFieldName: "name")?.text, boundedCalls.contains(name) { return true }
        return ["decimal_integer_literal", "hex_integer_literal"].contains(node.type)
    }
}
