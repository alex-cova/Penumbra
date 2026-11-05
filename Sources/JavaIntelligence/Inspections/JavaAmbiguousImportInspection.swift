import EditorIntelligence
import Foundation

/// A simple type name that two (or more) on-demand imports both provide: JLS 6.5.2 makes the
/// reference ambiguous — a compile error — and the resolver leaves it `.unresolved` instead of
/// picking the first match, so this rule is what tells the user.
///
/// Only names actually referenced in type position report, and only when the colliding
/// candidates both exist in the index. A single provider stays silent (that resolves fine),
/// and so does a name no import provides (the unresolved-type rule owns that).
enum JavaAmbiguousImportInspection: JavaTypedInspection {
    static let rule = JavaInspectionRule.ambiguousImport
    static let nodeTypes: Set<String> = ["type_identifier"]

    static func check(nodes: [SyntaxNode], context: JavaInspectionContext, report: (JavaInspection) -> Void) async {
        let imports = JavaImportList(tree: context.tree).entries.filter { $0.isOnDemand && !$0.isStatic }
        guard imports.count > 1 else { return }
        var seen = Set<String>()
        for node in nodes where !isQualifierSegment(node) {
            let name = node.text
            guard seen.insert(name).inserted else { continue }
            var providers: [String] = []
            for entry in imports {
                let candidate = "\(entry.qualifiedName).\(name)"
                if await context.index.classStub(qualifiedName: candidate) != nil, !providers.contains(candidate) {
                    providers.append(candidate)
                }
            }
            guard providers.count > 1 else { continue }
            report(JavaInspectionSupport.inspection(
                rule,
                message: "Reference to '\(name)' is ambiguous, both \(providers.map { "'\($0)'" }.joined(separator: " and ")) match; qualify it or add a single-type import",
                node: node
            ))
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
