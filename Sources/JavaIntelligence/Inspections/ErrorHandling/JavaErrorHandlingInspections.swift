import EditorIntelligence
import Foundation

enum JavaCatchClauses {
    private static let ignoredPrefixes = ["ignor", "expected", "unused", "_"]

    static func parameterName(of clause: SyntaxNode) -> SyntaxNode? {
        clause.firstNamedChild(ofType: "catch_formal_parameter")?.child(byFieldName: "name")
    }

    /// `ignored`, `expected`, `unused` and `_` say the exception is deliberately dropped.
    static func isDeliberatelyIgnored(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return ignoredPrefixes.contains { lowered.hasPrefix($0) }
    }

    static func hasComment(_ block: SyntaxNode) -> Bool {
        block.namedChildren.contains { $0.type == "line_comment" || $0.type == "block_comment" }
    }
}

enum JavaEmptyCatchBlockInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.emptyCatchBlock
    static let nodeTypes: Set<String> = ["catch_clause"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let body = node.child(byFieldName: "body"), body.namedChildCount == 0,
              let name = JavaCatchClauses.parameterName(of: node), !JavaCatchClauses.isDeliberatelyIgnored(name.text) else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Empty 'catch' block swallows '\(name.text)'", node: node))
    }
}

enum JavaCatchOfThrowableInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.catchOfThrowable
    static let nodeTypes: Set<String> = ["catch_type"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        for type in node.namedChildren where JavaDeclaredTypes.simpleName(of: type) == "Throwable" {
            report(JavaInspectionSupport.inspection(rule, message: "'catch' of 'Throwable' also catches errors such as OutOfMemoryError", node: type))
        }
    }
}

enum JavaCaughtExceptionRethrownInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.caughtExceptionRethrown
    static let nodeTypes: Set<String> = ["catch_clause"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let name = JavaCatchClauses.parameterName(of: node), let body = node.child(byFieldName: "body"),
              let only = body.namedChildren.first, body.namedChildren.count == 1, only.type == "throw_statement",
              only.namedChild(at: 0)?.type == "identifier", only.namedChild(at: 0)?.text == name.text else { return }
        // A narrower catch before a broader one is how an exception is let through, so it is deliberate.
        guard node.nextNamedSibling?.type != "catch_clause" else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Caught exception '\(name.text)' is immediately rethrown", node: only))
    }
}

enum JavaJumpOutOfFinallyInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.jumpOutOfFinally
    static let nodeTypes: Set<String> = ["finally_clause"]
    private static let boundaries: Set<String> = [
        "lambda_expression", "class_body", "method_declaration", "constructor_declaration", "try_statement", "try_with_resources_statement",
    ]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        node.forEachDescendant { statement in
            guard statement.type == "return_statement" || statement.type == "throw_statement" else { return }
            // A nested try may catch the throw, and a lambda or class body is a different frame.
            var current = statement.parent
            while let ancestor = current, ancestor.byteRange != node.byteRange {
                if boundaries.contains(ancestor.type) { return }
                current = ancestor.parent
            }
            let keyword = statement.type == "return_statement" ? "return" : "throw"
            report(JavaInspectionSupport.inspection(rule, message: "'\(keyword)' in 'finally' discards any pending exception", node: statement))
        }
    }
}

enum JavaEmptyFinallyBlockInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.emptyFinallyBlock
    static let nodeTypes: Set<String> = ["finally_clause"]

    /// Removing `finally {}` leaves a valid `try` only when a `catch` or a resource remains.
    private static func isRemovable(_ clause: SyntaxNode) -> Bool {
        guard let attempt = clause.parent else { return false }
        return attempt.type == "try_with_resources_statement" || attempt.namedChildren.contains { $0.type == "catch_clause" }
    }

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard node.firstNamedChild(ofType: "block")?.namedChildCount == 0 else { return }
        report(JavaInspectionSupport.inspection(
            rule, message: "Empty 'finally' block", node: node, fixTitle: isRemovable(node) ? "Remove 'finally' block" : nil
        ))
    }

    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard let clause = JavaInspectionSupport.node(of: "finally_clause", for: diagnostic, tree: tree, source: source),
              isRemovable(clause), let previous = clause.previousNamedSibling else { return [] }
        let edit = JavaInspectionSupport.edit(replacingBytes: previous.endByte..<clause.endByte, with: "", in: tree)
        return [CodeAction(title: "Remove 'finally' block", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

enum JavaEmptyTryBlockInspection: JavaNodeInspection {
    static let rule = JavaInspectionRule.emptyTryBlock
    static let nodeTypes: Set<String> = ["try_statement"]

    static func check(node: SyntaxNode, context: JavaInspectionContext, report: (JavaInspection) -> Void) {
        guard let body = node.child(byFieldName: "body"), body.namedChildCount == 0 else { return }
        report(JavaInspectionSupport.inspection(rule, message: "Empty 'try' block", node: body))
    }
}
