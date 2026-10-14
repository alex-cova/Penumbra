import EditorIntelligence
import Foundation

/// `assertEquals(actual, "expected")`: JUnit takes the expected value first.
enum JavaAssertEqualsArgumentOrderInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.assertEqualsArgumentOrder
    static let nodeTypes: Set<String> = ["method_invocation"]
    private static let methods: Set<String> = ["assertEquals", "assertNotEquals", "assertSame", "assertNotSame"]
    private static let literals: Set<String> = [
        "string_literal", "decimal_integer_literal", "hex_integer_literal", "decimal_floating_point_literal",
        "character_literal", "true", "false",
    ]

    private enum Dialect { case junit4, jupiter }

    private static func dialect(of tree: JavaSyntaxTree) -> Dialect? {
        var imports: [String] = []
        for child in tree.rootNode.namedChildren where child.type == "import_declaration" { imports.append(child.text) }
        guard !imports.contains(where: { $0.contains("org.testng") }) else { return nil }
        if imports.contains(where: { $0.contains("org.junit.jupiter") }) { return .jupiter }
        if imports.contains(where: { $0.contains("org.junit.") }) { return .junit4 }
        return nil
    }

    /// The expected and actual arguments of an assertion call.
    private static func pair(of call: SyntaxNode) -> (expected: SyntaxNode, actual: SyntaxNode)? {
        guard let name = call.child(byFieldName: "name")?.text, methods.contains(name) else { return nil }
        // Statically imported (`assertEquals(…)`) or called on the framework's class.
        if let object = call.child(byFieldName: "object"), !["Assert", "Assertions"].contains(object.text) { return nil }
        guard let dialect = dialect(of: call.tree), let list = call.child(byFieldName: "arguments") else { return nil }
        let args = list.namedChildren.filter { $0.type != "line_comment" && $0.type != "block_comment" }
        switch args.count {
        case 2:
            return (args[0], args[1])
        case 3:
            if dialect == .junit4, args[0].type == "string_literal" { return (args[1], args[2]) }
            if dialect == .jupiter, args[2].type == "string_literal" { return (args[0], args[1]) }
            return nil
        default:
            return nil
        }
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let pair = pair(of: node), !literals.contains(pair.expected.type), literals.contains(pair.actual.type) else { return }
        let name = node.child(byFieldName: "name")?.text ?? "assertEquals"
        report(JavaInspectionSupport.inspection(
            rule, message: "The arguments of '\(name)' are in the wrong order: the expected value '\(pair.actual.text)' comes first",
            node: node, fixTitle: "Swap the arguments"
        ))
    }

    static var providesFixes: Bool { true }
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let node = JavaInspectionSupport.node(of: "method_invocation", for: diagnostic, tree: tree, source: source),
              let pair = pair(of: node) else { return [] }
        let edits = [
            JavaInspectionSupport.edit(replacingBytes: pair.expected.byteRange, with: pair.actual.text, in: tree),
            JavaInspectionSupport.edit(replacingBytes: pair.actual.byteRange, with: pair.expected.text, in: tree),
        ]
        return [CodeAction(title: "Swap the arguments", kind: "quickfix", edits: edits, isPreferred: true)]
    }
}
