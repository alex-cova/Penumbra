import EditorIntelligence
import Foundation

enum JavaUnresolvedImportInspection {
    static func inspect(context: JavaInspectionContext, index: JavaIndex) async -> [JavaInspection] {
        var inspections: [JavaInspection] = []
        for entry in context.file.imports where !entry.isOnDemand {
            let simple = entry.qualifiedName.split(separator: ".").last.map(String.init) ?? entry.qualifiedName
            let candidates = await index.classes(simpleNamePrefix: simple, limit: 50).filter { $0.qualifiedName == entry.qualifiedName || $0.simpleName == simple }
            guard candidates.isEmpty else { continue }
            guard let importEntry = JavaImportList(tree: context.tree).entries.first(where: { $0.qualifiedName == entry.qualifiedName && $0.isStatic == entry.isStatic }) else {
                continue
            }
            let start = JavaImportInserter.textPosition(forByteOffset: importEntry.range.lowerBound, in: context.tree.sourceBytes)
            let end = JavaImportInserter.textPosition(forByteOffset: importEntry.range.upperBound, in: context.tree.sourceBytes)
            inspections.append(JavaInspection(
                id: "unresolved-import",
                message: "Cannot resolve import '\(entry.qualifiedName)'",
                severity: .warning,
                range: EditorIntelligence.TextRange(start: start, end: end),
                fixTitle: "Remove import"
            ))
        }
        return inspections
    }
}
