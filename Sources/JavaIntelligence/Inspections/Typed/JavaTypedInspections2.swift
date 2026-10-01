import EditorIntelligence
import Foundation

/// `c.size() == 0`, `s.length() > 0` and the like, where the receiver's type has `isEmpty()`.
enum JavaSizeComparisonWithZeroInspection: JavaTypedInspection {
    static let rule = JavaInspectionRule.sizeComparisonWithZero
    static let nodeTypes: Set<String> = ["binary_expression"]
    private static let maxResolutions = 300

    /// The `size()`/`length()` call and whether the comparison means "is empty" (`false`: "is not empty").
    private static func analyze(_ node: SyntaxNode) -> (call: SyntaxNode, empty: Bool)? {
        guard let op = node.operatorText, let left = node.child(byFieldName: "left"), let right = node.child(byFieldName: "right"),
              left.type == "method_invocation", let name = left.child(byFieldName: "name")?.text, name == "size" || name == "length",
              left.child(byFieldName: "arguments")?.namedChildCount == 0, left.child(byFieldName: "object") != nil,
              right.type == "decimal_integer_literal", let value = Int(right.text), value == 0 || value == 1 else { return nil }
        switch (op, value) {
        case ("==", 0), ("<=", 0), ("<", 1): return (left, true)
        case ("!=", 0), (">", 0), (">=", 1): return (left, false)
        default: return nil
        }
    }

    static func check(nodes: [SyntaxNode], context: JavaInspectionContext, report: (JavaInspection) -> Void) async {
        var verdicts: [String: Bool] = [:]
        var resolutions = 0
        for node in nodes {
            guard let (call, empty) = analyze(node), let object = call.child(byFieldName: "object"),
                  let nameNode = call.child(byFieldName: "name") else { continue }
            let key = JavaDeclaredTypes.type(of: object).map { "\($0.name).\(nameNode.text)" }
            let hasIsEmpty: Bool
            if let key, let known = verdicts[key] {
                hasIsEmpty = known
            } else if resolutions >= maxResolutions {
                continue
            } else {
                resolutions += 1
                hasIsEmpty = await receiverHasIsEmpty(call, nameNode: nameNode, context: context)
                if let key { verdicts[key] = hasIsEmpty }
            }
            guard hasIsEmpty else { continue }
            let replacement = "\(empty ? "" : "!")\(object.text).isEmpty()"
            report(JavaInspectionSupport.inspection(
                rule, message: "'\(nameNode.text)()' compared with zero; use '\(replacement)'", node: node, fixTitle: "Replace with '\(replacement)'"
            ))
        }
    }

    private static func receiverHasIsEmpty(_ call: SyntaxNode, nameNode: SyntaxNode, context: JavaInspectionContext) async -> Bool {
        let session = JavaInspectionSupport.session(for: context, at: call.startByte)
        guard let receiver = await session.receiverInfo(of: call, nameNode: nameNode), !receiver.isTypeReference else { return false }
        let methods = await session.allMethods(named: "isEmpty", on: receiver.type, mode: .instance).map(\.method)
        return methods.contains { $0.parameters.isEmpty && !$0.modifiers.contains(.staticFlag) }
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "binary_expression", for: diagnostic, tree: tree, source: source),
              let (call, empty) = analyze(node), let object = call.child(byFieldName: "object") else { return [] }
        let replacement = "\(empty ? "" : "!")\(object.text).isEmpty()"
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: replacement, in: tree)
        return [CodeAction(title: "Replace with '\(replacement)'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// A call to a method the library marks deprecated. Resolved once per (receiver type, method,
/// arity); only calls on a variable of a declared type or on a type name are looked at.
enum JavaDeprecatedApiInspection: JavaTypedInspection {
    static let rule = JavaInspectionRule.deprecatedApiUsage
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let maxResolutions = 300

    /// Calls inside a declaration that is itself `@Deprecated` are the library's own business.
    private static func isInsideDeprecatedDeclaration(_ node: SyntaxNode) -> Bool {
        var current = node.parent
        while let ancestor = current {
            if ["method_declaration", "constructor_declaration", "class_declaration", "interface_declaration", "enum_declaration"].contains(ancestor.type),
               JavaNameShape.modifierWords(of: ancestor).contains("@Deprecated") { return true }
            current = ancestor.parent
        }
        return false
    }

    private static func key(for node: SyntaxNode, arity: Int) -> String? {
        guard let object = node.child(byFieldName: "object"), let name = node.child(byFieldName: "name")?.text else { return nil }
        if let declared = JavaDeclaredTypes.type(of: object), !declared.isArray { return "\(declared.name).\(name)/\(arity)" }
        if object.type == "identifier", object.text.first?.isUppercase == true { return "\(object.text).\(name)/\(arity)" }
        return nil
    }

    static func check(nodes: [SyntaxNode], context: JavaInspectionContext, report: (JavaInspection) -> Void) async {
        var verdicts: [String: Bool] = [:]
        for node in nodes {
            let arity = node.child(byFieldName: "arguments")?.namedChildCount ?? 0
            guard let key = key(for: node, arity: arity), let nameNode = node.child(byFieldName: "name") else { continue }
            let deprecated: Bool
            if let known = verdicts[key] {
                deprecated = known
            } else if verdicts.count >= maxResolutions {
                continue
            } else {
                deprecated = await onlyDeprecatedOverloads(node, nameNode: nameNode, arity: arity, context: context)
                verdicts[key] = deprecated
            }
            guard deprecated, !isInsideDeprecatedDeclaration(node) else { continue }
            report(JavaInspectionSupport.inspection(rule, message: "'\(nameNode.text)()' is deprecated", node: nameNode))
        }
    }

    private static func onlyDeprecatedOverloads(_ call: SyntaxNode, nameNode: SyntaxNode, arity: Int, context: JavaInspectionContext) async -> Bool {
        let session = JavaInspectionSupport.session(for: context, at: call.startByte)
        guard let receiver = await session.receiverInfo(of: call, nameNode: nameNode) else { return false }
        let candidates = await session.allMethods(
            named: nameNode.text, on: receiver.type, mode: receiver.isTypeReference ? .staticOnly : .instance
        ).map(\.method).filter { $0.parameters.count == arity || ($0.modifiers.contains(.varargs) && arity >= $0.parameters.count - 1) }
        return !candidates.isEmpty && candidates.allSatisfy { $0.modifiers.contains(.deprecatedFlag) }
    }
}

/// `(T) x` where `x` is already declared `T`.
enum JavaRedundantTypeCastInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.redundantTypeCast
    static let nodeTypes: Set<String> = ["cast_expression"]

    private static func redundantOperand(of node: SyntaxNode) -> SyntaxNode? {
        guard let type = node.child(byFieldName: "type"), !["generic_type", "array_type", "intersection_type"].contains(type.type),
              let value = node.child(byFieldName: "value"), let declared = JavaDeclaredTypes.type(of: value),
              !declared.isArray, !declared.hasTypeArguments, declared.name == JavaDeclaredTypes.simpleName(of: type),
              !node.tree.declarationCache.typeParameterNames(root: node.tree.rootNode).contains(declared.name) else { return nil }
        return value
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard redundantOperand(of: node) != nil, let type = node.child(byFieldName: "type") else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Cast to '\(type.text)' is redundant: the operand already has that type", node: node, fixTitle: "Remove redundant cast"
        ))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "cast_expression", for: diagnostic, tree: tree, source: source),
              let value = redundantOperand(of: node) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: value.text, in: tree)
        return [CodeAction(title: "Remove redundant cast", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `new Integer(x)`: the wrapper constructors are deprecated for removal and `valueOf` replaces them.
enum JavaDeprecatedBoxedConstructorInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.deprecatedBoxedConstructor
    static let nodeTypes: Set<String> = ["object_creation_expression"]
    private static let wrappers: Set<String> = ["Integer", "Long", "Short", "Byte", "Character", "Boolean", "Double", "Float"]

    private static func wrapper(of node: SyntaxNode) -> (name: String, argument: SyntaxNode)? {
        guard let type = node.child(byFieldName: "type"), node.namedChildren(ofType: "class_body").isEmpty else { return nil }
        let name = JavaDeclaredTypes.simpleName(of: type)
        guard wrappers.contains(name), let arguments = node.child(byFieldName: "arguments"), arguments.namedChildCount == 1,
              let argument = arguments.namedChild(at: 0) else { return nil }
        return (name, argument)
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let (name, _) = wrapper(of: node) else { return }
        // `new Float(double)` has no `valueOf(double)` to turn into, so it gets the warning only.
        report(JavaInspectionSupport.inspection(
            rule, message: "'new \(name)()' is deprecated for removal; use '\(name).valueOf()'", node: node,
            fixTitle: name == "Float" ? nil : "Replace with '\(name).valueOf()'"
        ))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "object_creation_expression", for: diagnostic, tree: tree, source: source),
              let (name, argument) = wrapper(of: node), name != "Float" else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: "\(name).valueOf(\(argument.text))", in: tree)
        return [CodeAction(title: "Replace with '\(name).valueOf()'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

enum JavaEqualsEmptyStringInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.equalsEmptyString
    static let nodeTypes: Set<String> = ["method_invocation"]

    private static func receiver(of node: SyntaxNode) -> SyntaxNode? {
        guard node.child(byFieldName: "name")?.text == "equals", let object = node.child(byFieldName: "object"),
              JavaDeclaredTypes.type(of: object) == .string, object.type != "string_literal",
              let arguments = node.child(byFieldName: "arguments"), arguments.namedChildCount == 1,
              let argument = arguments.namedChild(at: 0), argument.type == "string_literal", argument.text == "\"\"" else { return nil }
        return object
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard receiver(of: node) != nil else { return }
        report(JavaInspectionSupport.inspection(rule, message: "'equals(\"\")' can be replaced with 'isEmpty()'", node: node, fixTitle: "Replace with 'isEmpty()'"))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "method_invocation", for: diagnostic, tree: tree, source: source),
              let object = receiver(of: node) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: "\(object.text).isEmpty()", in: tree)
        return [CodeAction(title: "Replace with 'isEmpty()'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `List<String> l = new ArrayList<String>();` -> `new ArrayList<>()`.
enum JavaExplicitTypeArgumentsInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.explicitTypeArguments
    static let nodeTypes: Set<String> = ["object_creation_expression"]

    /// The creation's type arguments when the declaration spells out the same ones.
    private static func redundantArguments(of node: SyntaxNode) -> SyntaxNode? {
        guard node.namedChildren(ofType: "class_body").isEmpty, let created = node.child(byFieldName: "type"), created.type == "generic_type",
              let arguments = created.firstNamedChild(ofType: "type_arguments"), arguments.namedChildCount > 0,
              let declarator = node.parent, declarator.type == "variable_declarator",
              declarator.child(byFieldName: "value")?.byteRange == node.byteRange,
              let declaration = declarator.parent, let declared = declaration.child(byFieldName: "type"), declared.type == "generic_type",
              let declaredArguments = declared.firstNamedChild(ofType: "type_arguments"),
              JavaBooleanSyntax.squeezed(declaredArguments) == JavaBooleanSyntax.squeezed(arguments),
              !arguments.text.contains("?") else { return nil }
        return arguments
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let arguments = redundantArguments(of: node) else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Explicit type arguments can be replaced with '<>'", node: arguments, fixTitle: "Replace with '<>'"))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let arguments = JavaInspectionSupport.node(of: "type_arguments", for: diagnostic, tree: tree, source: source),
              let creation = arguments.parent?.parent, creation.type == "object_creation_expression",
              redundantArguments(of: creation)?.byteRange == arguments.byteRange else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: arguments.byteRange, with: "<>", in: tree)
        return [CodeAction(title: "Replace with '<>'", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `s += x` on a String declared outside the loop that runs it.
enum JavaStringConcatenationInLoopInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.stringConcatenationInLoop
    static let nodeTypes: Set<String> = ["assignment_expression"]
    private static let boundaries: Set<String> = ["lambda_expression", "class_body", "method_declaration", "constructor_declaration"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let op = node.operatorText, let left = node.child(byFieldName: "left"), JavaSelfComparison.isSimpleReference(left),
              JavaDeclaredTypes.type(of: left) == .string else { return }
        let appends: Bool
        if op == "+=" {
            appends = true
        } else if op == "=", let right = node.child(byFieldName: "right"), right.type == "binary_expression", right.operatorText == "+",
                  right.child(byFieldName: "left")?.text == left.text {
            appends = true
        } else {
            appends = false
        }
        guard appends, let loop = enclosingLoop(of: node), !declares(left.text, inside: loop) else { return }
        report(JavaInspectionSupport.inspection(rule, message: "String '\(left.text)' is rebuilt on every pass of the loop; use a StringBuilder", node: node))
    }

    private static func enclosingLoop(of node: SyntaxNode) -> SyntaxNode? {
        var current = node.parent
        while let ancestor = current {
            if boundaries.contains(ancestor.type) { return nil }
            if JavaJumpStatements.loops.contains(ancestor.type) { return ancestor }
            current = ancestor.parent
        }
        return nil
    }

    /// A variable declared inside the loop is a fresh, short string each pass.
    private static func declares(_ name: String, inside loop: SyntaxNode) -> Bool {
        var found = false
        loop.forEachDescendant { node in
            if node.type == "variable_declarator", node.child(byFieldName: "name")?.text == name { found = true }
        }
        return found
    }
}
