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
    static func edits(in source: String, policy: JavaImportPolicy = .intellij) -> [TextEdit] {
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
        let organized = layout(collapsed(kept, policy: policy), lineEnding: original.contains("\r\n") ? "\r\n" : "\n")
        guard organized != original else { return [] }
        return [TextEdit(
            range: EditorIntelligence.TextRange(
                start: JavaImportInserter.textPosition(forByteOffset: blockStart, in: bytes),
                end: JavaImportInserter.textPosition(forByteOffset: blockEnd, in: bytes)
            ),
            replacement: organized
        )]
    }

    /// One edit (or a few, when a comment forbids rewriting the block) that adds `additions`.
    /// A clean block is rewritten in ``layout`` order and collapsed at the policy's star counts.
    static func editsAdding(
        _ additions: [(qualifiedName: String, isStatic: Bool)],
        list: JavaImportList,
        bytes: [UInt8],
        policy: JavaImportPolicy
    ) -> [TextEdit] {
        let fresh = additions.filter { addition in
            let container = importContainer(addition.qualifiedName)
            return !list.entries.contains { existing in
                existing.isStatic == addition.isStatic && (
                    (!existing.isOnDemand && existing.qualifiedName == addition.qualifiedName)
                        || (existing.isOnDemand && existing.qualifiedName == container)
                )
            }
        }
        guard !fresh.isEmpty else { return [] }
        let lineEnding = bytes.contains(13) ? "\r\n" : "\n"
        if list.entries.isEmpty || blockHoldsOnlyImports(list.entries, in: bytes) {
            return rewrite(adding: fresh, list: list, bytes: bytes, policy: policy, lineEnding: lineEnding)
        }
        return pointInserts(fresh, list: list, bytes: bytes, lineEnding: lineEnding)
    }

    /// Replaces one star import with the single imports in `additions`, without collapsing them
    /// straight back into a star. A comment in the block limits the edit to that one line.
    static func editsReplacing(
        star: JavaImportEntry,
        with additions: [(qualifiedName: String, isStatic: Bool)],
        list: JavaImportList,
        bytes: [UInt8]
    ) -> [TextEdit] {
        guard !additions.isEmpty else { return [] }
        let lineEnding = bytes.contains(13) ? "\r\n" : "\n"
        func line(_ addition: (qualifiedName: String, isStatic: Bool)) -> String {
            "import \(addition.isStatic ? "static " : "")\(addition.qualifiedName);"
        }
        if !blockHoldsOnlyImports(list.entries, in: bytes) {
            let range = JavaUnusedImports.lineRange(of: star.range, in: bytes)
            return [TextEdit(
                range: EditorIntelligence.TextRange(
                    start: JavaImportInserter.textPosition(forByteOffset: range.lowerBound, in: bytes),
                    end: JavaImportInserter.textPosition(forByteOffset: range.upperBound, in: bytes)
                ),
                replacement: additions.map(line).joined(separator: lineEnding) + lineEnding
            )]
        }
        var entries = list.entries.filter { $0.range != star.range }
        for addition in additions {
            entries.append(JavaImportEntry(
                qualifiedName: addition.qualifiedName, isStatic: addition.isStatic, isOnDemand: false, range: 0..<0
            ))
        }
        guard let first = list.entries.first, let last = list.entries.last else { return [] }
        let blockStart = lineStart(of: first.range.lowerBound, in: bytes)
        let blockEnd = last.range.upperBound
        return [TextEdit(
            range: EditorIntelligence.TextRange(
                start: JavaImportInserter.textPosition(forByteOffset: blockStart, in: bytes),
                end: JavaImportInserter.textPosition(forByteOffset: blockEnd, in: bytes)
            ),
            replacement: layout(entries, lineEnding: lineEnding)
        )]
    }

    /// The package or enclosing type of `a.b.C` (`a.b`), which is what `import a.b.*` names.
    static func importContainer(_ qualifiedName: String) -> String {
        guard let dot = qualifiedName.lastIndex(of: ".") else { return "" }
        return String(qualifiedName[..<dot])
    }

    /// Single imports that share a container become one star import once they reach the threshold.
    /// An existing star for that container absorbs its single imports, which the star already covers.
    static func collapsed(_ entries: [JavaImportEntry], policy: JavaImportPolicy) -> [JavaImportEntry] {
        var stars: [JavaImportEntry] = []
        var singles: [JavaImportEntry] = []
        for entry in entries {
            if entry.isOnDemand || importContainer(entry.qualifiedName).isEmpty {
                stars.append(entry)
            } else {
                singles.append(entry)
            }
        }
        struct Key: Hashable {
            var isStatic: Bool
            var container: String
        }
        let grouped = Dictionary(grouping: singles) { entry in
            Key(isStatic: entry.isStatic, container: importContainer(entry.qualifiedName))
        }
        var result = stars
        for (key, group) in grouped {
            let threshold = key.isStatic ? policy.staticStarThreshold : policy.classStarThreshold
            let alreadyStar = stars.contains { $0.isStatic == key.isStatic && $0.isOnDemand && $0.qualifiedName == key.container }
            if !alreadyStar, group.count >= threshold {
                result.append(JavaImportEntry(
                    qualifiedName: key.container, isStatic: key.isStatic, isOnDemand: true, range: group[0].range
                ))
            } else if alreadyStar {
                continue
            } else {
                result.append(contentsOf: group)
            }
        }
        return result
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

    private static func rewrite(
        adding fresh: [(qualifiedName: String, isStatic: Bool)],
        list: JavaImportList,
        bytes: [UInt8],
        policy: JavaImportPolicy,
        lineEnding: String
    ) -> [TextEdit] {
        var entries = list.entries
        for addition in fresh {
            entries.append(JavaImportEntry(
                qualifiedName: addition.qualifiedName, isStatic: addition.isStatic, isOnDemand: false, range: 0..<0
            ))
        }
        let text = layout(collapsed(entries, policy: policy), lineEnding: lineEnding)
        guard let first = list.entries.first, let last = list.entries.last else {
            if let packageEnd = list.packageDeclarationEnd {
                return [insertion("\(lineEnding)\(lineEnding)\(text)", atByte: packageEnd, in: bytes)]
            }
            return [insertion("\(text)\(lineEnding)\(lineEnding)", atByte: 0, in: bytes)]
        }
        let blockStart = lineStart(of: first.range.lowerBound, in: bytes)
        let blockEnd = last.range.upperBound
        let original = String(decoding: bytes[blockStart..<blockEnd], as: UTF8.self)
        guard text != original else { return [] }
        return [TextEdit(
            range: EditorIntelligence.TextRange(
                start: JavaImportInserter.textPosition(forByteOffset: blockStart, in: bytes),
                end: JavaImportInserter.textPosition(forByteOffset: blockEnd, in: bytes)
            ),
            replacement: text
        )]
    }

    /// Inserts lines without moving what is already there. Several additions that land on the same
    /// spot become one edit, so applying them does not shift each other.
    private static func pointInserts(
        _ fresh: [(qualifiedName: String, isStatic: Bool)],
        list: JavaImportList,
        bytes: [UInt8],
        lineEnding: String
    ) -> [TextEdit] {
        var texts: [Int: String] = [:]
        let sorted = fresh.sorted { lhs, rhs in
            if lhs.isStatic != rhs.isStatic { return !lhs.isStatic }
            return lhs.qualifiedName < rhs.qualifiedName
        }
        for addition in sorted {
            let line = "import \(addition.isStatic ? "static " : "")\(addition.qualifiedName);"
            let (byte, text) = anchor(for: line, isStatic: addition.isStatic, name: addition.qualifiedName, list: list, bytes: bytes, lineEnding: lineEnding)
            texts[byte, default: ""] += text
        }
        return texts.keys.sorted().map { byte in
            insertion(texts[byte] ?? "", atByte: byte, in: bytes)
        }
    }

    private static func anchor(
        for line: String, isStatic: Bool, name: String, list: JavaImportList, bytes: [UInt8], lineEnding: String
    ) -> (Int, String) {
        let pool = list.entries.filter { $0.isStatic == isStatic }
        if let next = pool.first(where: { $0.qualifiedName > name }) {
            return (lineStart(of: next.range.lowerBound, in: bytes), "\(line)\(lineEnding)")
        }
        if let last = pool.last ?? list.entries.last {
            return (last.range.upperBound, "\(lineEnding)\(line)")
        }
        return (0, "\(line)\(lineEnding)\(lineEnding)")
    }

    private static func insertion(_ replacement: String, atByte byteOffset: Int, in bytes: [UInt8]) -> TextEdit {
        let position = JavaImportInserter.textPosition(forByteOffset: byteOffset, in: bytes)
        return TextEdit(range: EditorIntelligence.TextRange(start: position, end: position), replacement: replacement)
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
