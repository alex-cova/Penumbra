import EditorIntelligence
import Foundation

/// Every quick fix for a `java-inspection` diagnostic in one place: the removal of an unused,
/// duplicate or unresolved import, "Add @Override", and the fixes of registered rules. The code
/// action provider (⌥↩) and the batch fixer ("Fix all") both go through it.
enum JavaInspectionFixes {
    static func fixes(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        guard diagnostic.source == "java-inspection", let code = diagnostic.code else { return [] }
        switch code {
        case "unused-import", "duplicate-import", "unresolved-import":
            guard diagnostic.message.contains("import"), let title = removeImportTitle(for: code) else { return [] }
            let edit = TextEdit(range: diagnostic.range, replacement: "")
            return [CodeAction(title: title, kind: "quickfix", edits: [edit], isPreferred: true)]
        case "missing-override":
            return overrideFix(for: diagnostic, tree: tree, source: source)
        default:
            return JavaInspectionRegistry.fixes(for: diagnostic, tree: tree, source: source)
        }
    }

    /// Whether `rule` can offer a fix at all.
    static func hasFixes(_ rule: JavaInspectionRule) -> Bool {
        switch rule {
        case .unusedImport, .duplicateImport, .unresolvedImport, .missingOverride: true
        default:
            JavaInspectionRegistry.inspection(for: rule)?.providesFixes
                ?? JavaInspectionRegistry.typedInspection(for: rule)?.providesFixes
                ?? false
        }
    }

    private static func removeImportTitle(for code: String) -> String? {
        switch code {
        case "unused-import": "Remove unused import"
        case "duplicate-import": "Remove duplicate import"
        case "unresolved-import": "Remove import"
        default: nil
        }
    }

    private static func overrideFix(for diagnostic: Diagnostic, tree: JavaSyntaxTree, source: String) -> [CodeAction] {
        let range = ProblemLocator.nsRange(for: diagnostic.range, in: source)
        let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: range.location, in: source)
        var current: SyntaxNode? = tree.node(atByteOffset: byteOffset)
        var method: SyntaxNode?
        while let node = current {
            if node.type == "method_declaration" { method = node; break }
            current = node.parent
        }
        guard let method else { return [] }
        let lineStart = tree.sourceBytes[..<method.startByte].lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? 0
        let prefix = tree.sourceBytes[lineStart..<method.startByte]
        let indent = String(decoding: prefix.prefix { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }, as: UTF8.self)
        let position = JavaImportInserter.textPosition(forByteOffset: method.startByte, in: tree.sourceBytes)
        let edit = TextEdit(range: EditorIntelligence.TextRange(start: position, end: position), replacement: "@Override\n\(indent)")
        return [CodeAction(title: "Add @Override", kind: "quickfix", edits: [edit], isPreferred: true)]
    }
}

extension JavaInspectionRule {
    /// Whether a quick fix exists for this rule (and so "Fix all" can work).
    public var hasQuickFix: Bool { JavaInspectionFixes.hasFixes(self) }

    /// The rules that need usages from the whole project (they run after a save, or in a batch).
    public static var projectWideRules: Set<JavaInspectionRule> { Set(JavaInspectionRegistry.projectRules) }
}

/// Quick fixes for a finding in a file that is not open in an editor (an Inspect Code result, a
/// Problems row): the rule's own fixes, then the Suppress actions.
public enum JavaInspectionQuickFixes {
    public static func actions(
        for inspection: JavaInspection,
        in text: String,
        suppressionStyle: JavaSuppressionStyle = .annotation
    ) -> [CodeAction] {
        actions(for: inspection.asDiagnostic(), in: text, suppressionStyle: suppressionStyle)
    }

    /// `diagnostic` must be one the inspection service published (`source == "java-inspection"`).
    public static func actions(
        for diagnostic: Diagnostic,
        in text: String,
        suppressionStyle: JavaSuppressionStyle = .annotation
    ) -> [CodeAction] {
        guard diagnostic.source == "java-inspection", let code = diagnostic.code,
              let tree = JavaSyntaxParser().parse(text), !tree.rootNode.hasError else { return [] }
        var actions = JavaInspectionFixes.fixes(for: diagnostic, tree: tree, source: text)
        if diagnostic.severity != .error {
            let range = ProblemLocator.nsRange(for: diagnostic.range, in: text)
            let byteOffset = JavaNavigationText.utf8ByteOffset(forUTF16Offset: range.location, in: text)
            actions.append(contentsOf: JavaSuppression.fixes(
                code: code, atByteOffset: byteOffset, tree: tree, source: text, style: suppressionStyle
            ))
        }
        return actions
    }
}
