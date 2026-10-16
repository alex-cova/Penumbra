import EditorIntelligence
import Foundation

enum JavaUnusedImportInspection {
    /// With `toleratingErrors`, a broken tree still reports the imports that are unused: the
    /// import list only reflects well-formed declarations. The pipeline uses this while the
    /// user is typing; every other caller keeps the strict default.
    static func inspect(source: String, tree: JavaSyntaxTree? = nil, toleratingErrors: Bool = false) -> [JavaInspection] {
        let analysis: JavaUnusedImports.Analysis?
        if let tree, toleratingErrors {
            analysis = JavaUnusedImports.analyzeToleratingErrors(source: source, tree: tree)
        } else if let tree {
            analysis = JavaUnusedImports.analyze(source: source, tree: tree)
        } else {
            analysis = JavaUnusedImports.analyze(source)
        }
        guard let analysis else { return [] }
        return analysis.removable.map { entry in
            let start = JavaImportInserter.textPosition(forByteOffset: entry.range.lowerBound, in: analysis.tree.sourceBytes)
            let end = JavaImportInserter.textPosition(forByteOffset: entry.range.upperBound, in: analysis.tree.sourceBytes)
            return JavaInspection(
                id: "unused-import",
                message: "Unused import '\(entry.qualifiedName)'",
                severity: .warning,
                range: EditorIntelligence.TextRange(start: start, end: end),
                fixTitle: "Remove unused import"
            )
        }
    }
}
