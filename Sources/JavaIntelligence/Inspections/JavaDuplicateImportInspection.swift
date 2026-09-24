import EditorIntelligence
import Foundation

enum JavaDuplicateImportInspection {
    static func inspect(source: String, tree: JavaSyntaxTree) -> [JavaInspection] {
        let list = JavaImportList(tree: tree)
        var seen = Set<String>()
        var inspections: [JavaInspection] = []
        for entry in list.entries where !entry.isOnDemand {
            let key = "\(entry.isStatic ? "static " : "")\(entry.qualifiedName)"
            if !seen.insert(key).inserted {
                let start = JavaImportInserter.textPosition(forByteOffset: entry.range.lowerBound, in: tree.sourceBytes)
                let end = JavaImportInserter.textPosition(forByteOffset: entry.range.upperBound, in: tree.sourceBytes)
                inspections.append(JavaInspection(
                    id: "duplicate-import",
                    message: "Duplicate import '\(entry.qualifiedName)'",
                    severity: .warning,
                    range: EditorIntelligence.TextRange(start: start, end: end),
                    fixTitle: "Remove duplicate import"
                ))
            }
        }
        return inspections
    }
}
