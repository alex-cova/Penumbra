import EditorIntelligence
import Foundation

/// Reformats Java with the built-in ``JavaFormatter``. A file that does not parse cleanly is left
/// alone, so it never mangles code that is mid-edit.
public actor JavaFormattingProvider: FormattingProviding {
    private var options = JavaFormattingOptions()
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

    private func currentOptions() async -> JavaFormattingOptions {
        if let indentUnitProvider {
            let unit = await indentUnitProvider()
            options.indentUnit = unit.isEmpty ? "    " : unit
        }
        return options
    }

    public nonisolated func supportsFormatting(_ document: Document) -> Bool {
        document.languageIdentifier == "java"
    }

    public func formatDocument(_ document: Document) async -> [TextEdit] {
        guard document.languageIdentifier == "java" else { return [] }
        let text = JavaNavigationText.fullText(of: document)
        guard let formatted = JavaFormatter.format(text, options: await currentOptions()) else { return [] }
        return JavaFormatEdits.edits(from: text, to: formatted)
    }

    public func formatSelection(in document: Document, range: EditorIntelligence.TextRange) async -> [TextEdit] {
        guard document.languageIdentifier == "java" else { return [] }
        let text = JavaNavigationText.fullText(of: document)
        // Every line break stays, so line numbers are stable and only the selected lines change.
        var rangeOptions = await currentOptions()
        rangeOptions.maxBlankLines = nil
        guard let formatted = JavaFormatter.format(text, options: rangeOptions) else { return [] }
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
        return JavaFormatEdits.edits(from: text, to: formatted, lines: first...last)
    }
}
