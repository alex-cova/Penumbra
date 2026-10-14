import EditorIntelligence
import Foundation

private let objectMethods: Set<String> = [
    "getClass", "hashCode", "equals", "toString", "notify", "notifyAll", "wait", "clone", "finalize",
]

/// The class bodies `node` sits in, innermost first, when every one is a plain class (no
/// anonymous class, enum, interface) without a superclass: then no instance member can be
/// inherited from code this file cannot see.
private func closedClassChain(of node: SyntaxNode) -> [SyntaxNode]? {
    var bodies: [SyntaxNode] = []
    var current = node.parent
    while let scope = current {
        if scope.type == "class_body" {
            guard let declaration = scope.parent, declaration.type == "class_declaration",
                  declaration.child(byFieldName: "superclass") == nil else { return nil }
            bodies.append(scope)
        }
        current = scope.parent
    }
    return bodies.isEmpty ? nil : bodies
}

private func typeParameterNames(of declaration: SyntaxNode) -> Set<String> {
    Set(
        declaration.firstNamedChild(ofType: "type_parameters")?.namedChildren(ofType: "type_parameter")
            .compactMap { $0.firstNamedChild(ofType: "type_identifier")?.text } ?? []
    )
}

/// A private method that uses nothing of its instance.
enum JavaMethodMayBeStaticInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.methodMayBeStatic
    static let nodeTypes: Set<String> = ["method_declaration"]

    private static func isCandidate(_ node: SyntaxNode, context: JavaInspectionContext) -> Bool {
        guard node.hasModifier("private"), !node.hasModifier("static"), !node.hasModifier("synchronized"),
              !node.hasModifier("abstract"), !node.hasModifier("native"), !node.hasAnnotation,
              let body = node.child(byFieldName: "body"), let name = node.child(byFieldName: "name"),
              let chain = closedClassChain(of: node) else { return false }
        var instanceNames = Set<String>()
        var staticMethodNames = Set<String>()
        var typeParameters = Set<String>()
        var instanceInnerClasses = Set<String>()
        var hasInterfaces = false
        for scope in chain {
            if let declaration = scope.parent {
                typeParameters.formUnion(typeParameterNames(of: declaration))
                if declaration.child(byFieldName: "interfaces") != nil { hasInterfaces = true }
            }
            for member in scope.namedChildren {
                switch member.type {
                case "field_declaration" where !member.hasModifier("static"):
                    for declarator in member.namedChildren(ofType: "variable_declarator") {
                        if let field = declarator.child(byFieldName: "name") { instanceNames.insert(field.text) }
                    }
                case "method_declaration":
                    guard let method = member.child(byFieldName: "name") else { continue }
                    if member.hasModifier("static") {
                        staticMethodNames.insert(method.text)
                    } else if member.byteRange != node.byteRange {
                        instanceNames.insert(method.text)
                    }
                case "class_declaration" where !member.hasModifier("static"):
                    if let inner = member.child(byFieldName: "name") { instanceInnerClasses.insert(inner.text) }
                default:
                    break
                }
            }
        }
        let symbols = node.tree.declarationCache.fileSymbols(context: context)
        var uses = false
        func visit(_ candidate: SyntaxNode) {
            guard !uses else { return }
            switch candidate.type {
            case "this", "super":
                uses = true
            case "type_identifier":
                if typeParameters.contains(candidate.text) || instanceInnerClasses.contains(candidate.text) { uses = true }
            case "method_invocation":
                if candidate.child(byFieldName: "object") == nil, let called = candidate.child(byFieldName: "name")?.text {
                    if objectMethods.contains(called) || instanceNames.contains(called) { uses = true }
                    // Without a superclass only interfaces can bring a method this file does not declare.
                    if hasInterfaces, !staticMethodNames.contains(called), called != name.text { uses = true }
                }
            case "identifier":
                if instanceNames.contains(candidate.text), !symbols.localIdentifiers.contains(candidate.byteRange) {
                    if let parent = candidate.parent {
                        if parent.type == "method_invocation", parent.child(byFieldName: "object") != nil,
                           parent.child(byFieldName: "name")?.byteRange == candidate.byteRange { break }
                        if parent.type == "field_access", parent.child(byFieldName: "field")?.byteRange == candidate.byteRange { break }
                    }
                    uses = true
                }
            default:
                break
            }
            for child in candidate.namedChildren { visit(child) }
        }
        // The class's type parameters may appear in the signature as well as the body.
        for part in [node.child(byFieldName: "type"), node.child(byFieldName: "parameters")].compactMap({ $0 }) { visit(part) }
        visit(body)
        return !uses
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard isCandidate(node, context: context), let name = node.child(byFieldName: "name") else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Method '\(name.text)' does not use instance state and may be 'static'", node: name,
            fixTitle: "Make '\(name.text)' static"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let name = JavaInspectionSupport.node(of: "identifier", for: diagnostic, tree: tree, source: source),
              let method = name.parent, method.type == "method_declaration",
              let modifiers = method.firstNamedChild(ofType: "modifiers"),
              let access = modifiers.children.first(where: { $0.type == "private" }) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: access.endByte..<access.endByte, with: " static", in: tree)
        return [CodeAction(title: "Make '\(name.text)' static", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// `private final int LIMIT = 10;` in an instance.
enum JavaFieldMayBeStaticInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.fieldMayBeStatic
    static let nodeTypes: Set<String> = ["field_declaration"]
    private static let constants: Set<String> = [
        "string_literal", "character_literal", "decimal_integer_literal", "hex_integer_literal", "decimal_floating_point_literal",
        "true", "false",
    ]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        // Making a public or protected field static would change the class's API.
        guard node.hasModifier("final"), !node.hasModifier("static"), !node.hasModifier("transient"), !node.hasModifier("volatile"),
              !node.hasModifier("public"), !node.hasModifier("protected"), !node.hasAnnotation, let body = node.parent, body.type == "class_body",
              let owner = body.parent, owner.type == "class_declaration", !owner.hasAnnotation else { return }
        // An inner (non-static member) class could not hold a static field before Java 16.
        if let container = owner.parent, container.type == "class_body", !owner.hasModifier("static"), !context.supports(16) { return }
        if let container = owner.parent, container.type != "class_body", container.type != "program" { return }
        let declarators = node.namedChildren(ofType: "variable_declarator")
        guard declarators.count == 1, let declarator = declarators.first, let name = declarator.child(byFieldName: "name"),
              let value = declarator.child(byFieldName: "value"), constants.contains(value.unparenthesized.type) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Field '\(name.text)' is a constant and may be 'static'", node: name, fixTitle: "Make '\(name.text)' static"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let name = JavaInspectionSupport.node(of: "identifier", for: diagnostic, tree: tree, source: source),
              let declarator = name.parent, declarator.type == "variable_declarator",
              let field = declarator.parent, field.type == "field_declaration",
              let modifiers = field.firstNamedChild(ofType: "modifiers"),
              let final = modifiers.children.first(where: { $0.type == "final" }) else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: final.startByte..<final.startByte, with: "static ", in: tree)
        return [CodeAction(title: "Make '\(name.text)' static", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// A non-static member class that uses nothing of its enclosing instance.
enum JavaInnerClassMayBeStaticInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.innerClassMayBeStatic
    static let nodeTypes: Set<String> = ["class_declaration"]

    private static func isCandidate(_ node: SyntaxNode, context: JavaInspectionContext) -> Bool {
        guard !node.hasModifier("static"), let outerBody = node.parent, outerBody.type == "class_body",
              let outer = outerBody.parent, outer.type == "class_declaration",
              outer.child(byFieldName: "superclass") == nil,
              let body = node.child(byFieldName: "body") else { return false }
        // The outer class must itself be top-level or static, or `static` here would not compile before Java 16.
        if let container = outer.parent, container.type == "class_body", !outer.hasModifier("static") { return false }
        if let container = outer.parent, container.type != "class_body", container.type != "program" { return false }
        var instanceNames = Set<String>()
        var instanceInnerClasses = Set<String>()
        for member in outerBody.namedChildren {
            switch member.type {
            case "field_declaration" where !member.hasModifier("static"):
                for declarator in member.namedChildren(ofType: "variable_declarator") {
                    if let field = declarator.child(byFieldName: "name") { instanceNames.insert(field.text) }
                }
            case "method_declaration" where !member.hasModifier("static"):
                if let method = member.child(byFieldName: "name") { instanceNames.insert(method.text) }
            case "class_declaration" where !member.hasModifier("static") && member.byteRange != node.byteRange:
                if let inner = member.child(byFieldName: "name") { instanceInnerClasses.insert(inner.text) }
            default:
                break
            }
        }
        let typeParameters = typeParameterNames(of: outer)
        let hasInterfaces = outer.child(byFieldName: "interfaces") != nil
        var staticMethodNames = Set<String>()
        for member in outerBody.namedChildren where member.type == "method_declaration" && member.hasModifier("static") {
            if let method = member.child(byFieldName: "name") { staticMethodNames.insert(method.text) }
        }
        var ownMethods = Set<String>()
        for member in body.namedChildren where member.type == "method_declaration" {
            if let method = member.child(byFieldName: "name") { ownMethods.insert(method.text) }
        }
        // `Outer.this` names the enclosing instance.
        if body.text.contains(".this") { return false }
        // `outer.new Inner()` needs an inner class, so it would stop compiling as a static one.
        if let innerName = node.child(byFieldName: "name")?.text {
            var qualified = false
            node.tree.rootNode.forEachDescendant { candidate in
                if candidate.isQualifiedCreation, candidate.child(byFieldName: "type")?.text == innerName { qualified = true }
            }
            if qualified { return false }
        }
        var uses = false
        func visit(_ candidate: SyntaxNode) {
            guard !uses else { return }
            switch candidate.type {
            case "type_identifier":
                if typeParameters.contains(candidate.text) || instanceInnerClasses.contains(candidate.text) { uses = true }
            case "identifier":
                if instanceNames.contains(candidate.text) {
                    if let parent = candidate.parent {
                        if parent.type == "method_invocation", parent.child(byFieldName: "object") != nil,
                           parent.child(byFieldName: "name")?.byteRange == candidate.byteRange { break }
                        if parent.type == "field_access", parent.child(byFieldName: "field")?.byteRange == candidate.byteRange { break }
                        if parent.type == "variable_declarator", parent.child(byFieldName: "name")?.byteRange == candidate.byteRange { break }
                        if parent.type == "formal_parameter" || parent.type == "method_declaration" { break }
                    }
                    uses = true
                }
            case "method_invocation":
                if candidate.child(byFieldName: "object") == nil, let called = candidate.child(byFieldName: "name")?.text,
                   !ownMethods.contains(called) {
                    if instanceNames.contains(called) || objectMethods.contains(called) { uses = true }
                    if hasInterfaces, !staticMethodNames.contains(called) { uses = true }
                }
            default:
                break
            }
            for child in candidate.namedChildren { visit(child) }
        }
        visit(body)
        return !uses
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard isCandidate(node, context: context), let name = node.child(byFieldName: "name") else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Inner class '\(name.text)' does not use its enclosing instance and may be 'static'", node: name,
            fixTitle: "Make '\(name.text)' static"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let name = JavaInspectionSupport.node(of: "identifier", for: diagnostic, tree: tree, source: source),
              let declaration = name.parent, declaration.type == "class_declaration",
              let keyword = declaration.children.first(where: { $0.type == "class" }) else { return [] }
        // After the access modifier (`private static class`), else before the first keyword modifier.
        let modifiers = declaration.firstNamedChild(ofType: "modifiers")
        let edit: TextEdit
        if let access = modifiers?.children.first(where: { ["public", "protected", "private"].contains($0.type) }) {
            edit = JavaInspectionSupport.edit(replacingBytes: access.endByte..<access.endByte, with: " static", in: tree)
        } else if let first = modifiers?.children.first(where: { $0.type != "marker_annotation" && $0.type != "annotation" }) {
            edit = JavaInspectionSupport.edit(replacingBytes: first.startByte..<first.startByte, with: "static ", in: tree)
        } else {
            edit = JavaInspectionSupport.edit(replacingBytes: keyword.startByte..<keyword.startByte, with: "static ", in: tree)
        }
        return [CodeAction(title: "Make '\(name.text)' static", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

/// A parameter of a private method that is never read.
enum JavaUnusedParameterInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.unusedParameter
    static let nodeTypes: Set<String> = ["method_declaration"]
    private static let serializationHooks: Set<String> = [
        "readObject", "writeObject", "readResolve", "writeReplace", "readObjectNoData",
    ]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.hasModifier("private"), !node.hasAnnotation, node.child(byFieldName: "body") != nil,
              let method = node.child(byFieldName: "name")?.text, !serializationHooks.contains(method),
              let parameters = node.child(byFieldName: "parameters") else { return }
        let symbols = node.tree.declarationCache.fileSymbols(context: context)
        for parameter in parameters.namedChildren where parameter.type == "formal_parameter" || parameter.type == "spread_parameter" {
            let suppressed = parameter.firstNamedChild(ofType: "modifiers")?.text.contains("SuppressWarnings") == true
            guard !suppressed, let name = parameter.child(byFieldName: "name")
                    ?? parameter.namedChildren(ofType: "variable_declarator").first?.child(byFieldName: "name"),
                  name.text != "_", !name.text.hasPrefix("unused"), !name.text.hasPrefix("ignored"),
                  let local = symbols.locals[name.byteRange], local.uses.isEmpty else { continue }
            report(JavaInspectionSupport.inspection(
                rule, message: "Parameter '\(name.text)' of '\(method)' is never used", node: name
            ))
        }
    }
}

/// `Serializable` class with a non-transient field of a type that cannot be serialized.
enum JavaNonSerializableFieldInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.nonSerializableField
    static let nodeTypes: Set<String> = ["field_declaration"]
    private static let knownNonSerializable: Set<String> = [
        "Thread", "InputStream", "OutputStream", "Reader", "Writer", "Socket", "ServerSocket", "Connection", "Statement",
        "PreparedStatement", "ResultSet", "Logger", "ExecutorService", "ScheduledExecutorService", "Process",
        "ByteBuffer", "CountDownLatch",
    ]
    private static let serializable: Set<String> = ["Serializable", "java.io.Serializable", "Externalizable", "java.io.Externalizable"]

    private static func implementsSerializable(_ declaration: SyntaxNode) -> Bool {
        guard let interfaces = declaration.child(byFieldName: "interfaces") else { return false }
        var found = false
        interfaces.forEachDescendant { if ($0.type == "type_identifier" || $0.type == "scoped_type_identifier"), serializable.contains($0.text) { found = true } }
        return found
    }

    /// A class of this file that has no supertypes at all, so it cannot be Serializable.
    private static func isPlainClass(named name: String, in root: SyntaxNode) -> Bool {
        guard let declaration = JavaDeclaredTypes.typeDeclaration(named: name, in: root), declaration.type == "class_declaration" else { return false }
        return declaration.child(byFieldName: "superclass") == nil && declaration.child(byFieldName: "interfaces") == nil
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard !node.hasModifier("static"), !node.hasModifier("transient"), let body = node.parent, body.type == "class_body",
              let owner = body.parent, owner.type == "class_declaration", implementsSerializable(owner),
              let type = node.child(byFieldName: "type"), type.type == "type_identifier" else { return }
        let name = type.text
        guard knownNonSerializable.contains(name) || isPlainClass(named: name, in: context.tree.rootNode) else { return }
        for declarator in node.namedChildren(ofType: "variable_declarator") {
            guard let field = declarator.child(byFieldName: "name") else { continue }
            report(JavaInspectionSupport.inspection(
                rule, message: "Field '\(field.text)' of type '\(name)' is not serializable; mark it 'transient'", node: field
            ))
        }
    }
}

/// `List` where `List<String>` was meant.
enum JavaRawTypeUsageInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.rawTypeUsage
    static let nodeTypes: Set<String> = ["type_identifier"]
    private static let genericJDK: Set<String> = [
        "List", "ArrayList", "LinkedList", "Map", "HashMap", "TreeMap", "LinkedHashMap", "Set", "HashSet", "TreeSet",
        "LinkedHashSet", "Collection", "Iterator", "Iterable", "Comparable", "Comparator", "Optional", "Stream", "Queue",
        "Deque", "ArrayDeque", "PriorityQueue", "Future", "Callable", "Supplier", "Consumer", "Function", "Predicate",
        "BiFunction", "CompletableFuture", "ConcurrentHashMap", "AtomicReference", "ThreadLocal",
    ]
    private static let contexts: Set<String> = [
        "local_variable_declaration", "field_declaration", "formal_parameter", "spread_parameter", "method_declaration",
        "cast_expression", "object_creation_expression",
    ]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        let name = node.text
        guard genericJDK.contains(name) || node.tree.declarationCache.genericTypeNames(root: node.tree.rootNode).contains(name),
              let parent = node.parent, contexts.contains(parent.type),
              parent.child(byFieldName: "type")?.byteRange == node.byteRange else { return }
        // `new ArrayList<>()` is a generic_type, so reaching here means no type arguments at all.
        report(JavaInspectionSupport.inspection(rule, message: "Raw use of the parameterized class '\(name)'", node: node))
    }
}

/// `(List<String>) object`.
enum JavaUncheckedCastInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.uncheckedCast
    static let nodeTypes: Set<String> = ["cast_expression"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let type = node.child(byFieldName: "type"), type.type == "generic_type",
              let arguments = type.firstNamedChild(ofType: "type_arguments"),
              arguments.namedChildren.contains(where: { $0.type != "wildcard" }) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Unchecked cast to '\(type.text)': the type arguments are erased at run time", node: node
        ))
    }
}
