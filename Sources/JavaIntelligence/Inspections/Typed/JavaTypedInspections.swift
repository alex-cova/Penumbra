import EditorIntelligence
import Foundation

/// `variable.staticMethod()`: the receiver is a variable of a known declared type and every
/// overload that could be called is static. Resolved once per (declared type, method, argument
/// count) in a file, so a file full of `list.add(...)` costs a handful of lookups.
enum JavaAccessStaticViaInstanceInspection: JavaTypedInspection {
    static let rule = JavaInspectionRule.accessStaticViaInstance
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let maxResolutions = 300

    static func check(nodes: [SyntaxNode], context: JavaInspectionContext, report: (JavaInspection) -> Void) async {
        var verdicts: [String: Bool] = [:]
        for node in nodes {
            guard let object = node.child(byFieldName: "object"), JavaSelfComparison.isSimpleReference(object), object.type != "this",
                  let nameNode = node.child(byFieldName: "name"),
                  let declared = JavaDeclaredTypes.type(of: object), !declared.isArray, !declared.isPrimitiveNumber,
                  !["boolean", "char", "void"].contains(declared.name) else { continue }
            let arity = node.child(byFieldName: "arguments")?.namedChildCount ?? 0
            let key = "\(declared.name).\(nameNode.text)/\(arity)"
            let isStatic: Bool
            if let known = verdicts[key] {
                isStatic = known
            } else if verdicts.count >= maxResolutions {
                continue
            } else {
                isStatic = await onlyStaticOverloads(of: node, nameNode: nameNode, arity: arity, context: context)
                verdicts[key] = isStatic
            }
            guard isStatic else { continue }
            report(JavaInspectionSupport.inspection(
                rule, message: "Static method '\(nameNode.text)()' is accessed via instance reference '\(object.text)'",
                node: object, fixTitle: "Replace with '\(declared.name)'"
            ))
        }
    }

    private static func onlyStaticOverloads(of invocation: SyntaxNode, nameNode: SyntaxNode, arity: Int, context: JavaInspectionContext) async -> Bool {
        let session = JavaInspectionSupport.session(for: context, at: invocation.startByte)
        guard let receiver = await session.receiverInfo(of: invocation, nameNode: nameNode), !receiver.isTypeReference else { return false }
        let candidates = await session.allMethods(named: nameNode.text, on: receiver.type, mode: .instance).map(\.method).filter {
            $0.parameters.count == arity || ($0.modifiers.contains(.varargs) && arity >= $0.parameters.count - 1)
        }
        return !candidates.isEmpty && candidates.allSatisfy { $0.modifiers.contains(.staticFlag) }
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        for type in ["identifier", "field_access"] {
            guard let object = JavaInspectionSupport.node(of: type, for: diagnostic, tree: tree, source: source),
                  let invocation = object.parent, invocation.type == "method_invocation",
                  invocation.child(byFieldName: "object")?.byteRange == object.byteRange,
                  let declared = JavaDeclaredTypes.type(of: object) else { continue }
            let edit = JavaInspectionSupport.edit(replacingBytes: object.byteRange, with: declared.name, in: tree)
            return [CodeAction(title: "Replace with '\(declared.name)'", kind: "quickfix", edits: [edit], isPreferred: true)]
        }
        return []
    }
}

/// `foo(new String[]{"a", "b"})` where `foo(String...)` takes `foo("a", "b")`.
enum JavaRedundantArrayCreationInspection: JavaTypedInspection {
    static let rule = JavaInspectionRule.redundantArrayCreation
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let comments: Set<String> = ["line_comment", "block_comment"]

    /// The array creation passed as the last argument, with its element expressions.
    private static func candidate(_ invocation: SyntaxNode) -> (creation: SyntaxNode, elements: [SyntaxNode], elementType: String, argumentCount: Int)? {
        guard let arguments = invocation.child(byFieldName: "arguments"), let last = arguments.namedChildren.last,
              last.type == "array_creation_expression",
              let type = last.child(byFieldName: "type"), let initializer = last.child(byFieldName: "value"),
              initializer.type == "array_initializer", !last.text.contains("[][]"),
              !initializer.namedChildren.contains(where: { comments.contains($0.type) }) else { return nil }
        let elements = initializer.namedChildren
        guard !elements.isEmpty else { return nil }
        // `new Object[]{ arr }` passes `arr`'s elements once unwrapped, not `arr`.
        if elements.count == 1, elements[0].unparenthesized.type == "null_literal" { return nil }
        return (last, elements, JavaDeclaredTypes.simpleName(of: type), arguments.namedChildCount)
    }

    static func check(nodes: [SyntaxNode], context: JavaInspectionContext, report: (JavaInspection) -> Void) async {
        for node in nodes {
            guard let (creation, elements, elementType, argumentCount) = candidate(node), let nameNode = node.child(byFieldName: "name") else { continue }
            if elements.count == 1, elementType == "Object" { continue }
            let session = JavaInspectionSupport.session(for: context, at: node.startByte)
            guard let receiver = await session.receiverInfo(of: node, nameNode: nameNode) else { continue }
            let overloads = await session.allMethods(
                named: nameNode.text, on: receiver.type, mode: receiver.isTypeReference ? .staticOnly : .instance
            ).map(\.method)
            guard let target = overloads.first(where: { $0.parameters.count == argumentCount }),
                  target.modifiers.contains(.varargs), matchesElement(target, elementType: elementType) else { continue }
            // Unwrapping must not make another overload applicable.
            let unwrappedCount = argumentCount - 1 + elements.count
            let rival = overloads.contains { other in
                other != target && (other.parameters.count == unwrappedCount
                    || (other.modifiers.contains(.varargs) && unwrappedCount >= other.parameters.count - 1))
            }
            guard !rival, overloads.filter({ $0.parameters.count == argumentCount }).count == 1 else { continue }
            report(JavaInspectionSupport.inspection(
                rule, message: "Redundant array creation for calling varargs method '\(nameNode.text)()'",
                node: creation, fixTitle: "Remove explicit array creation"
            ))
        }
    }

    /// The varargs parameter is an array of exactly the creation's element type (no type variables).
    private static func matchesElement(_ method: JavaMethodStub, elementType: String) -> Bool {
        guard let last = method.parameters.last, case .array(let element) = last.type else { return false }
        switch element {
        case .primitive(let primitive): return primitive.rawValue == elementType
        case .classType(let qualifiedName, _, _): return qualifiedName.split(separator: ".").last.map(String.init) == elementType
        // Stubs built from source keep the name as written.
        case .unresolved(let simpleName, _): return simpleName.split(separator: ".").last.map(String.init) == elementType
        default: return false
        }
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let creation = JavaInspectionSupport.node(of: "array_creation_expression", for: diagnostic, tree: tree, source: source),
              let initializer = creation.child(byFieldName: "value") else { return [] }
        let replacement = initializer.namedChildren.map(\.text).joined(separator: ", ")
        let edit = JavaInspectionSupport.edit(replacingBytes: creation.byteRange, with: replacement, in: tree)
        return [CodeAction(title: "Remove explicit array creation", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}
