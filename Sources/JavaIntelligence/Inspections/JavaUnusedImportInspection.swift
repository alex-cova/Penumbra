import EditorIntelligence
import Foundation

enum JavaUnusedImportInspection {
    static func inspect(source: String, tree: JavaSyntaxTree? = nil) -> [JavaInspection] {
        let analysis: JavaUnusedImports.Analysis?
        if let tree {
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
