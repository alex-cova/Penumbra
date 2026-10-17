import EditorIntelligence
import Foundation

enum JavaUnresolvedTypeInspection {
    static func inspect(source: String, url: URL?, index: JavaIndex, walker: JavaSemanticWalker) async -> [JavaInspection] {
        var inspections: [JavaInspection] = []
        for name in walker.undeclaredTypeNames.sorted() {
            // A name some known type bears resolves without an import (`java.lang`, the file's
            // own package) or is one import away (auto-import and the import fix own those, so
            // this rule stays silent). Only a name no known type bears is reported.
            let candidates = await index.classes(simpleName: name, limit: 50)
            guard candidates.isEmpty else { continue }
            guard let range = firstTypeReference(to: name, in: walker.syntaxTree) else { continue }
            let start = JavaImportInserter.textPosition(forByteOffset: range.lowerBound, in: walker.syntaxTree.sourceBytes)
            let end = JavaImportInserter.textPosition(forByteOffset: range.upperBound, in: walker.syntaxTree.sourceBytes)
            inspections.append(JavaInspection(
                id: "unresolved-type",
                message: "Cannot resolve type '\(name)'",
                severity: .warning,
                range: EditorIntelligence.TextRange(start: start, end: end)
            ))
        }
        return inspections
    }

    /// The first reference to `name` in type position: a plain `type_identifier` with exactly
    /// that text that is not a qualifier segment. That covers simple names and the last segment
    /// of qualified names; qualifier segments (`io` and `java` in `java.io.OutputStream`) are
    /// packages, not types, so a name that only ever qualifies never reports. Resolving the
    /// qualifier itself (`unknown` in `unknown.Known`) is name resolution's job, not this rule's.
    /// `var` in one of its legal positions (see `isLegalVarPosition`) is local type inference,
    /// not a missing type, so those references never report.
    private static func firstTypeReference(to name: String, in tree: JavaSyntaxTree) -> Range<Int>? {
        var stack = [tree.rootNode]
        while let node = stack.popLast() {
            if node.type == "type_identifier", node.text == name, !isQualifierSegment(node),
               !(name == "var" && isLegalVarPosition(node)) {
                return node.byteRange
            }
            for index in (0..<node.namedChildCount).reversed() {
                stack.append(node.namedChild(at: index)!)
            }
        }
        return nil
    }

    /// Whether a `var` reference is local type inference (Java 10+) rather than a type name:
    /// a local variable's type, an enhanced-`for` variable's type, a try-with-resources
    /// variable's type, or a lambda parameter's type (`(var x) -> ...`, Java 11+). Anywhere
    /// else (`var` as a field type, a `List<var>` argument) is a real error and still reports.
    private static func isLegalVarPosition(_ node: SyntaxNode) -> Bool {
        guard let parent = node.parent else { return false }
        switch parent.type {
        case "local_variable_declaration", "enhanced_for_statement", "resource":
            return true
        case "formal_parameter":
            // `void m(var x)` is illegal; only a lambda's parameters may use `var`.
            var current = parent.parent
            while let ancestor = current {
                if ancestor.type == "lambda_expression" { return true }
                current = ancestor.parent
            }
            return false
        default:
            return false
        }
    }

    /// Whether `node` sits on the scope (left-hand) side of a qualified name: the scope is
    /// always followed by `.name`, so a scope segment ends strictly before the outermost
    /// qualified name does, while the trailing segment ends exactly where it does.
    private static func isQualifierSegment(_ node: SyntaxNode) -> Bool {
        var top = node
        while let parent = top.parent, parent.type == "scoped_type_identifier" {
            top = parent
        }
        return top.byteRange.upperBound > node.byteRange.upperBound
    }
}
