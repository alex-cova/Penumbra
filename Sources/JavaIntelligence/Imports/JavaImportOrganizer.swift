import EditorIntelligence
import Foundation

/// Optimize Imports: drops the imports nothing uses (see ``JavaUnusedImports``) and puts the rest
/// in IntelliJ's default layout, a blank line between groups:
///
///     everything else, sorted
///     javax.*, then java.*, each sorted
///     static imports, sorted
///
/// Imports are only rewritten when the block holds nothing but import declarations. A comment
/// between or beside them would be lost, so such a file only loses its unused imports and keeps
/// its order.
enum JavaImportOrganizer {
    static func edits(in source: String) -> [TextEdit] {
        guard let analysis = JavaUnusedImports.analyze(source) else { return [] }
        let entries = analysis.list.entries
        guard let first = entries.first, let last = entries.last else { return [] }
        let bytes = analysis.tree.sourceBytes
        let removed = Set(analysis.removable.map(\.range))
        // Duplicates are "removable" entries too; keep one of each by dropping the flagged copy.
        let kept = entries.filter { !removed.contains($0.range) }

        guard blockHoldsOnlyImports(entries, in: bytes) else { return JavaUnusedImports.edits(in: source) }

        let blockStart = lineStart(of: first.range.lowerBound, in: bytes)
        let blockEnd = last.range.upperBound
        if kept.isEmpty {
            // Everything goes: take the block and the blank lines after it, so no gap is left.
            return [deletion(blockStart..<endOfBlankLines(after: blockEnd, in: bytes), in: bytes)]
        }
        let original = String(decoding: bytes[blockStart..<blockEnd], as: UTF8.self)
        let organized = layout(kept, lineEnding: original.contains("\r\n") ? "\r\n" : "\n")
        guard organized != original else { return [] }
        return [TextEdit(
            range: EditorIntelligence.TextRange(
                start: JavaImportInserter.textPosition(forByteOffset: blockStart, in: bytes),
                end: JavaImportInserter.textPosition(forByteOffset: blockEnd, in: bytes)
            ),
            replacement: organized
        )]
    }

    // MARK: - Layout

    static func layout(_ entries: [JavaImportEntry], lineEnding: String = "\n") -> String {
        func line(_ entry: JavaImportEntry) -> String {
            "import \(entry.isStatic ? "static " : "")\(entry.qualifiedName)\(entry.isOnDemand ? ".*" : "");"
        }
        func sorted(_ group: [JavaImportEntry]) -> [String] {
            group.sorted { sortKey($0) < sortKey($1) }.map(line)
        }
        let regular = entries.filter { !$0.isStatic }
        let javax = regular.filter { $0.qualifiedName.hasPrefix("javax.") }
        let java = regular.filter { $0.qualifiedName.hasPrefix("java.") }
        let other = regular.filter { !$0.qualifiedName.hasPrefix("javax.") && !$0.qualifiedName.hasPrefix("java.") }
        let statics = entries.filter(\.isStatic)
        let groups = [sorted(other), sorted(javax) + sorted(java), sorted(statics)].filter { !$0.isEmpty }
        return groups.map { $0.joined(separator: lineEnding) }.joined(separator: lineEnding + lineEnding)
    }

    private static func sortKey(_ entry: JavaImportEntry) -> String {
        entry.isOnDemand ? entry.qualifiedName + ".*" : entry.qualifiedName
    }

    // MARK: - Ranges

    /// True when, apart from the import declarations, the block from the first import to the last
    /// is whitespace: no comments hiding between or inside the lines.
    private static func blockHoldsOnlyImports(_ entries: [JavaImportEntry], in bytes: [UInt8]) -> Bool {
        guard let first = entries.first, let last = entries.last else { return true }
        var covered = Set<Int>()
        for entry in entries { covered.formUnion(entry.range) }
        for index in first.range.lowerBound..<last.range.upperBound where !covered.contains(index) {
            let byte = bytes[index]
            if byte != 32, byte != 9, byte != 10, byte != 13 { return false }
        }
        // A comment sharing the last import's line is outside the block but would end up
        // glued to a different import once the block is reordered.
        var end = last.range.upperBound
        while end < bytes.count, bytes[end] == 32 || bytes[end] == 9 { end += 1 }
        return !(end + 1 < bytes.count && bytes[end] == UInt8(ascii: "/") && (bytes[end + 1] == UInt8(ascii: "/") || bytes[end + 1] == UInt8(ascii: "*")))
    }

    private static func lineStart(of offset: Int, in bytes: [UInt8]) -> Int {
        var probe = offset
        while probe > 0, bytes[probe - 1] == 32 || bytes[probe - 1] == 9 { probe -= 1 }
        return probe == 0 || bytes[probe - 1] == 10 ? probe : offset
    }

    /// The end of the line break after `offset` and of the blank lines that follow it.
    private static func endOfBlankLines(after offset: Int, in bytes: [UInt8]) -> Int {
        var end = offset
        while end < bytes.count {
            var probe = end
            while probe < bytes.count, bytes[probe] == 32 || bytes[probe] == 9 || bytes[probe] == 13 { probe += 1 }
            guard probe < bytes.count, bytes[probe] == 10 else { break }
            end = probe + 1
        }
        return end
    }

    private static func deletion(_ range: Range<Int>, in bytes: [UInt8]) -> TextEdit {
        TextEdit(
            range: EditorIntelligence.TextRange(
                start: JavaImportInserter.textPosition(forByteOffset: range.lowerBound, in: bytes),
                end: JavaImportInserter.textPosition(forByteOffset: range.upperBound, in: bytes)
            ),
            replacement: ""
        )
    }
}
