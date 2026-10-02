import EditorIntelligence
import Foundation

/// The type arguments a variable was declared with (`List<String> l` -> `["String"]`).
enum JavaDeclaredTypeArguments {
    static func arguments(of type: SyntaxNode) -> [String]? {
        guard type.type == "generic_type", let list = type.firstNamedChild(ofType: "type_arguments") else { return nil }
        return list.namedChildren.map { JavaDeclaredTypes.simpleName(of: $0) }
    }

    /// The nearest local, parameter or field `name` visible at `node`, read for its type arguments.
    static func arguments(ofVariable name: String, at node: SyntaxNode) -> [String]? {
        var child = node
        var current = node.parent
        while let scope = current {
            switch scope.type {
            case "block", "switch_block", "constructor_body":
                for statement in scope.namedChildren where statement.type == "local_variable_declaration" && statement.endByte <= child.startByte {
                    if statement.namedChildren(ofType: "variable_declarator").contains(where: { $0.child(byFieldName: "name")?.text == name }) {
                        return statement.child(byFieldName: "type").flatMap(arguments(of:))
                    }
                }
            case "enhanced_for_statement":
                if scope.child(byFieldName: "name")?.text == name { return scope.child(byFieldName: "type").flatMap(arguments(of:)) }
            case "method_declaration", "constructor_declaration":
                for parameter in scope.child(byFieldName: "parameters")?.namedChildren(ofType: "formal_parameter") ?? []
                where parameter.child(byFieldName: "name")?.text == name {
                    return parameter.child(byFieldName: "type").flatMap(arguments(of:))
                }
            case "class_body":
                for member in scope.namedChildren where member.type == "field_declaration" {
                    if member.namedChildren(ofType: "variable_declarator").contains(where: { $0.child(byFieldName: "name")?.text == name }) {
                        return member.child(byFieldName: "type").flatMap(arguments(of:))
                    }
                }
            default:
                break
            }
            child = scope
            current = scope.parent
        }
        return nil
    }
}

enum JavaOverridableMethodInConstructorInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.overridableMethodCalledInConstructor
    static let nodeTypes: Set<String> = ["constructor_declaration"]

    private static func isOverridable(_ method: SyntaxNode) -> Bool {
        let words = JavaNameShape.modifierWords(of: method)
        return words.isDisjoint(with: ["private", "static", "final"])
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let owner = node.parent?.parent, owner.type == "class_declaration", !JavaNameShape.modifierWords(of: owner).contains("final"),
              let body = node.child(byFieldName: "body") else { return }
        let members = JavaClassShape.members(of: owner)
        // A class that only has private constructors cannot be extended from outside.
        let constructors = members.filter { $0.type == "constructor_declaration" }
        if !constructors.isEmpty, constructors.allSatisfy({ JavaNameShape.modifierWords(of: $0).contains("private") }) { return }
        let methods = members.filter { $0.type == "method_declaration" }
        var stack = Array(body.namedChildren.reversed())
        while let current = stack.popLast() {
            // Lambdas and local classes run later, not during construction.
            if current.type == "lambda_expression" || current.type == "class_body" { continue }
            stack.append(contentsOf: current.namedChildren.reversed())
            guard current.type == "method_invocation", let name = current.child(byFieldName: "name"),
                  current.child(byFieldName: "object").map({ $0.type == "this" }) ?? true,
                  let arity = current.child(byFieldName: "arguments")?.namedChildCount else { continue }
            let candidates = methods.filter {
                $0.child(byFieldName: "name")?.text == name.text && $0.child(byFieldName: "parameters")?.namedChildCount == arity
                    && $0.child(byFieldName: "parameters")?.namedChildren(ofType: "spread_parameter").isEmpty == true
            }
            guard !candidates.isEmpty, candidates.allSatisfy(isOverridable) else { continue }
            report(JavaInspectionSupport.inspection(
                rule, message: "Overridable method '\(name.text)' is called during construction; a subclass override sees an uninitialized object", node: name
            ))
        }
    }
}

enum JavaSortedCollectionNonComparableInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.sortedCollectionNonComparable
    static let nodeTypes: Set<String> = ["object_creation_expression"]
    private static let sorted: Set<String> = ["TreeSet", "TreeMap", "PriorityQueue", "ConcurrentSkipListSet", "ConcurrentSkipListMap"]

    /// The element (or key) type name the creation spells out, or takes from the declaration it initializes for `<>`.
    private static func elementType(of node: SyntaxNode, created: SyntaxNode) -> String? {
        if let first = JavaDeclaredTypeArguments.arguments(of: created)?.first { return first }
        guard created.firstNamedChild(ofType: "type_arguments") != nil,
              let declarator = node.parent, declarator.type == "variable_declarator",
              declarator.child(byFieldName: "value")?.byteRange == node.byteRange,
              let type = declarator.parent?.child(byFieldName: "type") else { return nil }
        return JavaDeclaredTypeArguments.arguments(of: type)?.first
    }

    /// Whether the class `name` declared in this file is certainly not `Comparable` (its supertypes are in the file too).
    private static func isNotComparable(_ name: String, root: SyntaxNode) -> Bool {
        var current = name
        for _ in 0..<8 {
            guard let declaration = JavaDeclaredTypes.typeDeclaration(named: current, in: root),
                  ["class_declaration", "record_declaration"].contains(declaration.type) else { return false }
            if JavaClassShape.implementedNames(of: declaration).contains("Comparable") { return false }
            guard let superclass = declaration.child(byFieldName: "superclass")?.namedChild(at: 0) else { return true }
            current = JavaDeclaredTypes.simpleName(of: superclass)
        }
        return false
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.namedChildren(ofType: "class_body").isEmpty, node.child(byFieldName: "arguments")?.namedChildCount == 0,
              let created = node.child(byFieldName: "type") else { return }
        let collection = JavaDeclaredTypes.simpleName(of: created)
        guard sorted.contains(collection), let element = elementType(of: node, created: created),
              isNotComparable(element, root: context.tree.rootNode) else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'\(element)' is not 'Comparable'; the \(collection) needs a Comparator", node: created
        ))
    }
}

enum JavaSuspiciousToArrayInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.suspiciousToArray
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let collections: Set<String> = [
        "List", "ArrayList", "LinkedList", "Set", "HashSet", "LinkedHashSet", "TreeSet", "Collection", "Queue", "Deque", "ArrayDeque",
    ]
    /// Final classes: an element of one of these can only be stored in an array of the same class (or `Object`-like supertypes).
    private static let finals: Set<String> = ["String", "Integer", "Long", "Double", "Float", "Short", "Byte", "Boolean", "Character"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.child(byFieldName: "name")?.text == "toArray", let object = node.child(byFieldName: "object"),
              let receiver = JavaDeclaredTypes.type(of: object), !receiver.isArray, collections.contains(receiver.name),
              let arguments = node.child(byFieldName: "arguments") else { return }
        if arguments.namedChildCount == 0 {
            // `(String[]) list.toArray()` fails: the array is an `Object[]`.
            guard let cast = node.parent, cast.type == "cast_expression", cast.child(byFieldName: "value")?.byteRange == node.byteRange,
                  let type = cast.child(byFieldName: "type"), type.type == "array_type", type.text.replacingOccurrences(of: " ", with: "") != "Object[]",
                  // `(E[]) c.toArray()` is an unchecked cast to `Object[]` once `E` is erased.
                  let element = type.child(byFieldName: "element"),
                  !context.tree.declarationCache.typeParameterNames(root: context.tree.rootNode).contains(element.text) else { return }
            report(JavaInspectionSupport.inspection(rule, message: "'toArray()' returns an 'Object[]'; the cast to '\(type.text)' always fails, pass an array to 'toArray(T[])'", node: node))
            return
        }
        guard arguments.namedChildCount == 1, let array = arguments.namedChild(at: 0), array.type == "array_creation_expression",
              let elementNode = array.child(byFieldName: "type"), object.type == "identifier",
              let declared = JavaDeclaredTypeArguments.arguments(ofVariable: object.text, at: object)?.first else { return }
        let target = JavaDeclaredTypes.simpleName(of: elementNode)
        guard finals.contains(declared), finals.contains(target), declared != target else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "'\(declared)' elements cannot be stored in a '\(target)[]': 'toArray' throws ArrayStoreException", node: array
        ))
    }
}

enum JavaListRemoveInLoopInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.listRemoveInLoop
    static let nodeTypes: Set<String> = ["enhanced_for_statement", "for_statement"]
    private static let collections: Set<String> = [
        "List", "ArrayList", "LinkedList", "Set", "HashSet", "LinkedHashSet", "TreeSet", "Collection", "Queue", "Deque", "ArrayDeque",
    ]
    private static let modifying: Set<String> = ["add", "remove", "addAll", "removeAll", "retainAll", "removeIf", "clear"]
    private static let jumps: Set<String> = ["break_statement", "return_statement", "throw_statement"]

    /// The name of the collection a loop iterates over: `for (x : c)` or `i < c.size()`.
    private static func iterated(_ node: SyntaxNode) -> (collection: String, index: String?)? {
        if node.type == "enhanced_for_statement" {
            guard let value = node.child(byFieldName: "value"), value.type == "identifier" else { return nil }
            return (value.text, nil)
        }
        // Without an update clause the body steps the index itself (`else { i++; }`).
        guard node.child(byFieldName: "update") != nil, let condition = node.child(byFieldName: "condition"), condition.type == "binary_expression",
              let op = condition.operatorText, op == "<" || op == "<=",
              let index = condition.child(byFieldName: "left"), index.type == "identifier",
              let call = condition.child(byFieldName: "right"), call.type == "method_invocation", call.child(byFieldName: "name")?.text == "size",
              let object = call.child(byFieldName: "object"), object.type == "identifier" else { return nil }
        return (object.text, index.text)
    }

    /// Whether the statements after `call` in its block leave the loop right away.
    private static func leavesLoop(after call: SyntaxNode) -> Bool {
        var current: SyntaxNode? = call
        while let node = current, let parent = node.parent {
            if parent.type == "block" || parent.type == "switch_block" {
                var following = node.nextNamedSibling
                while let statement = following {
                    if jumps.contains(statement.type) { return true }
                    following = statement.nextNamedSibling
                }
            }
            if parent.type == "enhanced_for_statement" || parent.type == "for_statement" { return false }
            current = parent
        }
        return false
    }

    /// Whether the loop body steps the index back (`i--`), which makes removing by index correct.
    private static func decrements(_ index: String, in body: SyntaxNode) -> Bool {
        var found = false
        body.forEachDescendant { node in
            if node.type == "update_expression", node.text.replacingOccurrences(of: " ", with: "").contains("\(index)--") || node.text.contains("--\(index)") { found = true }
            if node.type == "assignment_expression", node.child(byFieldName: "left")?.text == index, node.operatorText == "-=" || node.operatorText == "=" { found = true }
        }
        return found
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let (collection, index) = iterated(node), let body = node.child(byFieldName: "body"),
              let identifier = node.type == "enhanced_for_statement" ? node.child(byFieldName: "value") : node.child(byFieldName: "condition")?.child(byFieldName: "right")?.child(byFieldName: "object"),
              let declared = JavaDeclaredTypes.type(of: identifier), !declared.isArray, collections.contains(declared.name) else { return }
        if let index, decrements(index, in: body) { return }
        var stack = [body]
        while let current = stack.popLast() {
            if current.type == "lambda_expression" || current.type == "class_body" { continue }
            stack.append(contentsOf: current.namedChildren)
            guard current.type == "method_invocation", current.child(byFieldName: "object")?.text == collection,
                  let name = current.child(byFieldName: "name"), modifying.contains(name.text), !leavesLoop(after: current) else { continue }
            report(JavaInspectionSupport.inspection(
                rule, message: "'\(collection).\(name.text)()' modifies the collection the loop is iterating over", node: name
            ))
        }
    }
}
