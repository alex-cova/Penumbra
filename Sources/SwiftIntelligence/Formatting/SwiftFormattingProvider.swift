import EditorIntelligence
import Foundation

/// Reformats Swift with the built-in ``SwiftFormatter``. A file that does not parse cleanly is
/// left alone, so it never mangles code that is mid-edit.
public actor SwiftFormattingProvider: FormattingProviding {
    private var options = SwiftFormattingOptions()
    private var indentUnitProvider: (@Sendable () async -> String)?

    public init() {}

    /// The indentation unit to lay code out with (`"    "`, `"\t"`), from the editor's settings.
    public func setIndentUnit(_ unit: String) {
        options.indentUnit = unit.isEmpty ? "    " : unit
    }

    /// Asks for the indentation unit each time code is formatted, so a change to the editor's tab
    /// settings applies to the next reformat without any other wiring.
    public func setIndentUnitProvider(_ provider: (@Sendable () async -> String)?) {
        indentUnitProvider = provider
    }

    private func currentOptions() async -> SwiftFormattingOptions {
        // A copy, so clearing the provider returns to the unit set with `setIndentUnit` (or the
        // default) instead of keeping whatever the host answered last.
        var current = options
        if let indentUnitProvider {
            let unit = await indentUnitProvider()
            current.indentUnit = unit.isEmpty ? "    " : unit
        }
        return current
    }

    public nonisolated func supportsFormatting(_ document: Document) -> Bool {
        document.languageIdentifier == "swift"
    }

    /// The document's full text, reading through the ranged reader when the snapshot elided it
    /// (large file-backed documents), the same way Java's providers read.
    private static func fullText(of document: Document) -> String {
        if let text = document.contentSnapshot.text {
            return text
        }
        let length = document.contentSnapshot.utf16Length
        guard length > 0 else { return "" }
        return document.substring(utf16Offset: 0, length: length)
    }

    public func formatDocument(_ document: Document) async -> [TextEdit] {
        guard document.languageIdentifier == "swift" else { return [] }
        let text = Self.fullText(of: document)
        guard let formatted = SwiftFormatter.format(text, options: await currentOptions()) else { return [] }
        return Self.edits(from: text, to: formatted)
    }

    public func formatSelection(in document: Document, range: EditorIntelligence.TextRange) async -> [TextEdit] {
        guard document.languageIdentifier == "swift" else { return [] }
        let text = Self.fullText(of: document)
        // Every line break stays, so line numbers are stable and only the selected lines change.
        var rangeOptions = await currentOptions()
        rangeOptions.maxBlankLines = nil
        guard let formatted = SwiftFormatter.format(text, options: rangeOptions) else { return [] }
        let ns = text as NSString
        let start = min(max(0, range.start.utf16Offset), ns.length)
        let end = min(max(start, range.end.utf16Offset), ns.length)
        func line(at offset: Int) -> Int {
            ns.substring(to: offset).utf16.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
        }
        let first = line(at: start)
        var last = line(at: end)
        // A selection that ends at the start of a line does not include that line.
        if end > start, end <= ns.length, ns.character(at: end - 1) == 0x0A { last = max(first, last - 1) }
        return Self.edits(from: text, to: formatted, lines: first...last)
    }

    /// The smallest edits that turn `old` into `new`: one trimmed edit per changed line when the
    /// line counts match (so carets move with their text), one block edit otherwise. When `lines`
    /// is set, only those (0-based, inclusive) original lines may change, which needs `new` to
    /// have as many lines as `old`.
    static func edits(from old: String, to new: String, lines: ClosedRange<Int>? = nil) -> [TextEdit] {
        guard old != new else { return [] }
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        var starts: [Int] = []
        var offset = 0
        for line in oldLines {
            starts.append(offset)
            offset += line.utf16.count + 1
        }

        if oldLines.count == newLines.count {
            var edits: [TextEdit] = []
            for index in oldLines.indices where oldLines[index] != newLines[index] {
                if let lines, !lines.contains(index) { continue }
                let a = Array(oldLines[index].utf16), b = Array(newLines[index].utf16)
                var prefix = 0
                while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
                var suffix = 0
                while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
                let replacement = String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self)
                edits.append(TextEdit(
                    range: EditorIntelligence.TextRange(
                        start: TextPosition(line: index, column: prefix, utf16Offset: starts[index] + prefix),
                        end: TextPosition(line: index, column: a.count - suffix, utf16Offset: starts[index] + a.count - suffix)
                    ),
                    replacement: replacement
                ))
            }
            return edits
        }

        guard lines == nil else { return [] }

        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count, oldLines[prefix] == newLines[prefix] { prefix += 1 }
        // Keep the last shared line in the block, so the block always starts at a line that exists
        // (adding a final newline shares every old line with the new text).
        prefix = min(prefix, oldLines.count - 1, newLines.count - 1)
        var suffix = 0
        while suffix < oldLines.count - prefix, suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] { suffix += 1 }
        let oldEnd = oldLines.count - suffix
        let newEnd = newLines.count - suffix
        let startOffset = starts[prefix]
        let start = TextPosition(line: prefix, column: 0, utf16Offset: startOffset)
        let end: TextPosition
        if oldEnd < oldLines.count {
            end = TextPosition(line: oldEnd, column: 0, utf16Offset: starts[oldEnd])
        } else {
            let last = oldLines.count - 1
            end = TextPosition(line: last, column: oldLines[last].utf16.count, utf16Offset: offset - 1)
        }
        var replacement = ""
        if newEnd > prefix {
            replacement = newLines[prefix..<newEnd].joined(separator: "\n") + (newEnd < newLines.count ? "\n" : "")
        }
        return [TextEdit(range: EditorIntelligence.TextRange(start: start, end: end), replacement: replacement)]
    }
}
