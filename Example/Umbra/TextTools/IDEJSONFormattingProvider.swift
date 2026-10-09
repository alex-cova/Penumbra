import EditorIntelligence
import Foundation

/// Reformat Code (⌥⌘L) for JSON files, through `IDEJSONText.format`. Invalid JSON, including a
/// file that is mid-edit, is left alone.
struct IDEJSONFormattingProvider: FormattingProviding {
    /// The indentation unit to lay JSON out with, asked at every reformat so a change to the
    /// editor's tab settings applies to the next one.
    let indentUnit: @Sendable () async -> String

    func supportsFormatting(_ document: Document) -> Bool {
        document.languageIdentifier == "json"
    }

    func formatDocument(_ document: Document) async -> [TextEdit] {
        guard supportsFormatting(document) else { return [] }
        let text = Self.fullText(of: document)
        guard let formatted = IDEJSONText.format(text, indentUnit: await unit()) else { return [] }
        return Self.edits(from: text, to: formatted, offset: 0, in: text)
    }

    func formatSelection(in document: Document, range: EditorIntelligence.TextRange) async -> [TextEdit] {
        guard supportsFormatting(document) else { return [] }
        let text = Self.fullText(of: document)
        let ns = text as NSString
        let start = min(max(0, range.start.utf16Offset), ns.length)
        let end = min(max(start, range.end.utf16Offset), ns.length)
        let selected = ns.substring(with: NSRange(location: start, length: end - start))
        // The lines after the first keep the indentation of the line the selection starts on.
        let lineStart = ns.lineRange(for: NSRange(location: start, length: 0)).location
        let baseIndent = String(ns.substring(with: NSRange(location: lineStart, length: start - lineStart)).prefix { $0 == " " || $0 == "\t" })
        guard let formatted = IDEJSONText.format(selected, indentUnit: await unit(), baseIndent: baseIndent) else { return [] }
        return Self.edits(from: selected, to: formatted, offset: start, in: text)
    }

    private func unit() async -> String {
        let unit = await indentUnit()
        return unit.isEmpty ? "  " : unit
    }

    private static func fullText(of document: Document) -> String {
        if let text = document.contentSnapshot.text { return text }
        let length = document.contentSnapshot.utf16Length
        return length > 0 ? document.substring(utf16Offset: 0, length: length) : ""
    }

    /// One edit over the part of `old` that differs from `new`; `offset` is where `old` starts in
    /// `fullText`, which positions are measured in.
    private static func edits(from old: String, to new: String, offset: Int, in fullText: String) -> [TextEdit] {
        guard old != new else { return [] }
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let replacement = String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self)
        let ns = fullText as NSString
        func position(_ utf16Offset: Int) -> TextPosition {
            var line = 0
            var lineStart = 0
            var index = 0
            while index < utf16Offset {
                if ns.character(at: index) == 0x0A {
                    line += 1
                    lineStart = index + 1
                }
                index += 1
            }
            return TextPosition(line: line, column: utf16Offset - lineStart, utf16Offset: utf16Offset)
        }
        let range = EditorIntelligence.TextRange(
            start: position(offset + prefix),
            end: position(offset + a.count - suffix)
        )
        return [TextEdit(range: range, replacement: replacement)]
    }
}
