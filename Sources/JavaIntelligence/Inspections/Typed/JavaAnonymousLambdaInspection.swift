import EditorIntelligence
import Foundation

/// `new Runnable() { public void run() { ... } }` -> `() -> { ... }`, when the type resolves to a
/// functional interface and the body does not depend on being a class (`this`, other members, shadowing).
enum JavaAnonymousCanBeLambdaInspection: JavaTypedInspection {
    static let rule = JavaInspectionRule.anonymousCanBeLambda
    static let nodeTypes: Set<String> = ["object_creation_expression"]
    private static let maxResolutions = 200
    private static let objectMethods: Set<String> = ["equals/1", "hashCode/0", "toString/0"]
    private static let declarationTypes: Set<String> = ["variable_declarator", "formal_parameter", "catch_formal_parameter", "spread_parameter", "resource"]

    private struct Shape {
        let method: SyntaxNode
        let body: SyntaxNode
        let parameterNames: [String]
        let type: SyntaxNode
    }

    /// The anonymous class's only method, when the class is nothing but that method.
    private static func shape(of node: SyntaxNode) -> Shape? {
        guard node.child(byFieldName: "object") == nil, node.child(byFieldName: "arguments")?.namedChildCount == 0,
              let type = node.child(byFieldName: "type"), let classBody = node.firstNamedChild(ofType: "class_body") else { return nil }
        let members = classBody.namedChildren.filter { !JavaClassShape.comments.contains($0.type) }
        guard members.count == 1, let method = members.first, method.type == "method_declaration",
              method.firstNamedChild(ofType: "type_parameters") == nil, let body = method.child(byFieldName: "body"),
              let parameters = method.child(byFieldName: "parameters") else { return nil }
        let words = JavaNameShape.modifierWords(of: method)
        guard words.isSubset(of: ["public", "@Override"]) else { return nil }
        var names: [String] = []
        for parameter in parameters.namedChildren {
            guard parameter.type == "formal_parameter", let name = parameter.child(byFieldName: "name") else { return nil }
            names.append(name.text)
        }
        return Shape(method: method, body: body, parameterNames: names, type: type)
    }

    /// Whether the body needs the anonymous class: `this`, `super`, a call to the method itself, or a name that a lambda cannot reuse.
    private static func dependsOnClass(_ shape: Shape, creation: SyntaxNode) -> Bool {
        let methodName = shape.method.child(byFieldName: "name")?.text ?? ""
        var declared = Set(shape.parameterNames)
        var dependent = false
        shape.body.forEachDescendant { node in
            switch node.type {
            case "this", "super": dependent = true
            case "method_invocation" where node.child(byFieldName: "object") == nil && node.child(byFieldName: "name")?.text == methodName: dependent = true
            default: break
            }
            if declarationTypes.contains(node.type), let name = node.child(byFieldName: "name") { declared.insert(name.text) }
        }
        if dependent { return true }
        // A lambda cannot redeclare a local of the enclosing method, but an anonymous class can.
        var scope: SyntaxNode? = creation.parent
        while let current = scope, !["method_declaration", "constructor_declaration", "static_initializer"].contains(current.type) { scope = current.parent }
        guard let scope else { return false }
        var clash = false
        scope.forEachDescendant { node in
            guard !clash, declarationTypes.contains(node.type), node.startByte < creation.startByte || node.startByte >= creation.endByte,
                  let name = node.child(byFieldName: "name") else { return }
            if declared.contains(name.text) { clash = true }
        }
        if let parameters = scope.child(byFieldName: "parameters") {
            for parameter in parameters.namedChildren {
                if let name = parameter.child(byFieldName: "name"), declared.contains(name.text) { clash = true }
            }
        }
        return clash
    }

    static func check(nodes: [SyntaxNode], context: JavaInspectionContext, report: (JavaInspection) -> Void) async {
        var verdicts: [String: Bool] = [:]
        for node in nodes {
            guard let shape = shape(of: node), !dependsOnClass(shape, creation: node),
                  let methodName = shape.method.child(byFieldName: "name")?.text else { continue }
            let typeName = shape.type.type == "generic_type" ? (shape.type.namedChild(at: 0)?.text ?? "") : shape.type.text
            guard !typeName.isEmpty else { continue }
            let key = "\(typeName)#\(methodName)/\(shape.parameterNames.count)"
            let isFunctional: Bool
            if let known = verdicts[key] {
                isFunctional = known
            } else if verdicts.count >= maxResolutions {
                continue
            } else {
                isFunctional = await implementsFunctionalInterface(
                    typeName: typeName, method: methodName, arity: shape.parameterNames.count, node: node, context: context
                )
                verdicts[key] = isFunctional
            }
            guard isFunctional else { continue }
            report(JavaInspectionSupport.inspection(
                rule, message: "Anonymous '\(typeName)' can be replaced with a lambda", node: shape.type, fixTitle: "Replace with lambda"
            ))
        }
    }

    /// Whether `typeName` is an interface with exactly one abstract method, `method` with `arity` parameters.
    private static func implementsFunctionalInterface(
        typeName: String, method: String, arity: Int, node: SyntaxNode, context: JavaInspectionContext
    ) async -> Bool {
        let session = JavaInspectionSupport.session(for: context, at: node.startByte)
        let resolved = await session.resolveType(components: typeName.split(separator: ".").map(String.init))
        guard case .classType(let qualifiedName, _, _)? = resolved else { return false }
        var abstract: Set<String> = []
        var pending = [qualifiedName]
        var seen: Set<String> = []
        while let name = pending.popLast(), seen.count < 12 {
            guard seen.insert(name).inserted, let stub = await context.index.classStub(qualifiedName: name), stub.kind == .interfaceKind else { return false }
            for candidate in stub.methods where !candidate.isConstructor {
                let flags = candidate.modifiers
                guard !flags.contains(.staticFlag), !flags.contains(.privateFlag), !flags.contains(.defaultMethod) else { continue }
                let signature = "\(candidate.name)/\(candidate.parameters.count)"
                if !objectMethods.contains(signature) { abstract.insert(signature) }
            }
            for parent in stub.interfaces {
                switch parent {
                case .classType(let parentName, _, _):
                    pending.append(parentName)
                case .unresolved(let simpleName, _):
                    // Source stubs spell a supertype by its simple name.
                    guard case .classType(let parentName, _, _)? = await session.resolveType(components: [simpleName]) else { return false }
                    pending.append(parentName)
                default:
                    return false
                }
            }
        }
        return abstract == ["\(method)/\(arity)"]
    }

    private static func creation(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> SyntaxNode? {
        let range = ProblemLocator.nsRange(for: diagnostic.range, in: source)
        let start = JavaNavigationText.utf8ByteOffset(forUTF16Offset: range.location, in: source)
        var current: SyntaxNode? = tree.node(atByteOffset: start)
        while let node = current {
            if node.type == "object_creation_expression", node.child(byFieldName: "type")?.startByte == start { return node }
            current = node.parent
        }
        return nil
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = creation(for: diagnostic, tree: tree, source: source), let shape = shape(of: node) else { return [] }
        let parameters = shape.parameterNames.count == 1 ? shape.parameterNames[0] : "(\(shape.parameterNames.joined(separator: ", ")))"
        var body = shape.body.text
        let statements = shape.body.namedChildren.filter { !JavaClassShape.comments.contains($0.type) }
        if statements.count == 1, shape.body.namedChildren.count == 1, let only = statements.first {
            if only.type == "return_statement", let value = only.namedChild(at: 0) {
                body = value.text
            } else if only.type == "expression_statement", let expression = only.namedChild(at: 0),
                      shape.method.child(byFieldName: "type")?.text == "void" {
                body = expression.text
            }
        }
        let edit = JavaInspectionSupport.edit(replacingBytes: node.byteRange, with: "\(parameters) -> \(body)", in: tree)
        return [CodeAction(title: "Replace with lambda", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}
