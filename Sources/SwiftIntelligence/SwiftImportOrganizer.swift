import EditorIntelligence
import Foundation

/// Organize Imports for one Swift file: drop duplicate import lines, sort the rest, and put
/// `@testable` imports in their own group after a blank line.
///
///     import App
///     import Zoo
///
///     @testable import Tests
///
/// An import the file never spells (`import Foundation` used only through `String`) stays.
/// Removing it needs the compiler, and this organizer does not grow one. The block is rewritten
/// only when it holds nothing but import declarations. A comment between or beside them would be
/// lost, so that file is left as it is.
public enum SwiftImportOrganizer {
    public static func edits(in source: String) -> [TextEdit] {
        guard let parsed = SwiftAnalysis.parse(source) else { return [] }
        let imports = parsed.model.imports
        guard let first = imports.first, let last = imports.last else { return [] }
        let bytes = parsed.text.utf8
        guard blockHoldsOnlyImports(imports, in: bytes) else { return [] }

        let entries = imports.map { importEntry($0, in: parsed.text) }
        let blockStart = lineStart(of: first.bytes.lowerBound, in: bytes)
        let blockEnd = last.bytes.upperBound
        let original = parsed.text.text(bytes: blockStart..<blockEnd)
        let lineEnding = original.contains("\r\n") ? "\r\n" : "\n"
        let organized = layout(entries, lineEnding: lineEnding)
        guard organized != original else { return [] }
        return [TextEdit(
            range: EditorIntelligence.TextRange(
                start: parsed.text.position(atByte: blockStart),
                end: parsed.text.position(atByte: blockEnd)
            ),
            replacement: organized
        )]
    }

    // MARK: - Layout

    static func layout(_ entries: [Entry], lineEnding: String = "\n") -> String {
        func uniqueSorted(_ group: [Entry]) -> [String] {
            var seen = Set<String>()
            return group
                .sorted { sortKey($0) < sortKey($1) }
                .map(\.line)
                .filter { seen.insert($0).inserted }
        }
        let plain = uniqueSorted(entries.filter { !$0.isTestable })
        let testable = uniqueSorted(entries.filter(\.isTestable))
        return [plain, testable].filter { !$0.isEmpty }.map { $0.joined(separator: lineEnding) }.joined(separator: lineEnding + lineEnding)
    }

    struct Entry: Sendable, Equatable {
        var module: String
        var isTestable: Bool
        /// The import as it was written, without the trailing line break.
        var line: String
    }

    private static func importEntry(_ importDecl: SwiftFileModel.Import, in text: SourceTextMap) -> Entry {
        Entry(
            module: importDecl.module,
            isTestable: importDecl.isTestable,
            line: text.text(bytes: importDecl.bytes).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func sortKey(_ entry: Entry) -> String {
        entry.module.lowercased() + "\u{0}" + entry.line.lowercased()
    }

    // MARK: - Ranges

    /// True when, apart from the import declarations, the block from the first import to the last
    /// is whitespace: no comments hiding between or inside the lines.
    private static func blockHoldsOnlyImports(_ imports: [SwiftFileModel.Import], in bytes: [UInt8]) -> Bool {
        guard let first = imports.first, let last = imports.last else { return true }
        var covered = Set<Int>()
        for importDecl in imports { covered.formUnion(importDecl.bytes) }
        for index in first.bytes.lowerBound..<last.bytes.upperBound where !covered.contains(index) {
            let byte = bytes[index]
            if byte != 32, byte != 9, byte != 10, byte != 13 { return false }
        }
        var end = last.bytes.upperBound
        while end < bytes.count, bytes[end] == 32 || bytes[end] == 9 { end += 1 }
        return !(end + 1 < bytes.count && bytes[end] == UInt8(ascii: "/") && (bytes[end + 1] == UInt8(ascii: "/") || bytes[end + 1] == UInt8(ascii: "*")))
    }

    private static func lineStart(of offset: Int, in bytes: [UInt8]) -> Int {
        var probe = offset
        while probe > 0, bytes[probe - 1] == 32 || bytes[probe - 1] == 9 { probe -= 1 }
        return probe == 0 || bytes[probe - 1] == 10 ? probe : offset
    }
}
