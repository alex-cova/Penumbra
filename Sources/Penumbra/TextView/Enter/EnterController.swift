import Foundation

/// Decides what Enter inserts: runs host and built-in ``EnterHandlerDelegate``-style handlers, then
/// falls back to computing the new line's indentation.
@MainActor
struct EnterController {
    /// Upper bound on how far back structure-aware indentation scans.
    private static let maximumScanLength = 262_144

    let stringView: StringView
    let lineManager: LineManager
    let languageMode: InternalLanguageMode
    let indentStrategy: IndentStrategy
    let hostDelegates: [EnterHandlerDelegate]

    /// Returns the edit for pressing Enter with `range` selected, or `nil` if the position is invalid.
    func makeEdit(in range: NSRange, lineEnding: LineEnding) -> EnterEdit? {
        guard let startPosition = lineManager.linePosition(at: range.lowerBound),
              let endPosition = lineManager.linePosition(at: range.upperBound) else {
            return nil
        }
        let context = makeContext(range: range, lineEnding: lineEnding, startPosition: startPosition)
        for delegate in hostDelegates {
            if let edit = delegate.enterEdit(for: context) {
                return edit
            }
        }
        if let edit = BlockCommentEnterHandler.edit(for: context) {
            return edit
        }
        if let edit = StringLiteralEnterHandler.edit(for: context) {
            return edit
        }
        if !languageMode.hasIndentationScopes || context.usesSmartIndent,
           let edit = EnterBetweenBracesHandler.edit(for: context) {
            return edit
        }
        return indentedLineBreak(context: context, startPosition: startPosition, endPosition: endPosition, lineEnding: lineEnding)
    }

    private func indentedLineBreak(context: EnterContext,
                                   startPosition: LinePosition,
                                   endPosition: LinePosition,
                                   lineEnding: LineEnding) -> EnterEdit {
        let range = context.selectedRange
        let symbol = lineEnding.symbol
        if !context.usesSmartIndent && languageMode.hasIndentationScopes {
            let strategy = languageMode.strategyForInsertingLineBreak(from: startPosition, to: endPosition, using: indentStrategy)
            if strategy.insertExtraLineBreak {
                // Inserting a line break enters a new indentation level: add a second line break and
                // leave the caret on the new, indented line.
                let firstLine = symbol + indentStrategy.string(indentLevel: strategy.indentLevel)
                let secondLine = symbol + indentStrategy.string(indentLevel: strategy.indentLevel - 1)
                return EnterEdit(replacementRange: range, text: firstLine + secondLine, caretOffset: firstLine.utf16.count)
            }
            return EnterEdit(replacementRange: range, text: symbol + indentStrategy.string(indentLevel: strategy.indentLevel))
        }
        let indent = context.indentString(textAfterCaret: context.textAfterCaret)
        let extended = NSRange(location: range.location, length: range.length + context.leadingWhitespaceLengthAfterCaret)
        return EnterEdit(replacementRange: extended, text: symbol + indent)
    }

    private func makeContext(range: NSRange, lineEnding: LineEnding, startPosition: LinePosition) -> EnterContext {
        let startLine = lineManager.line(atRow: startPosition.row)
        let endLine = lineManager.line(atRow: lineManager.linePosition(at: range.upperBound)?.row ?? startPosition.row)
        let beforeRange = NSRange(location: startLine.location, length: max(0, range.lowerBound - startLine.location))
        let afterLength = max(0, endLine.location + endLine.data.length - range.upperBound)
        let before = stringView.substring(in: beforeRange) ?? ""
        let after = stringView.substring(in: NSRange(location: range.upperBound, length: afterLength)) ?? ""
        let fullLine = stringView.substring(in: NSRange(location: startLine.location, length: startLine.data.length)) ?? before
        let leadingWhitespace = String(fullLine.prefix { $0 == " " || $0 == "\t" })

        let behavior = languageMode.enterBehavior
        let smart = behavior?.cStyleIndent == true
        let lineManager = self.lineManager
        let stringView = self.stringView
        let indentStrategy = self.indentStrategy
        let languageMode = self.languageMode
        let scanStart = scanStartLocation(for: range.lowerBound)
        let row = startPosition.row

        let indentProvider: (String) -> String? = { textAfter in
            guard smart, let behavior else {
                return nil
            }
            let provider = CStyleLineIndentProvider(
                behavior: behavior,
                normalIndent: indentStrategy.string(indentLevel: 1),
                continuationIndent: indentStrategy.string(indentLevel: behavior.continuationIndentLevels))
            let text = stringView.substring(in: NSRange(location: scanStart, length: range.lowerBound - scanStart)) ?? ""
            return provider.indent(textBefore: text, textAfter: textAfter, isTruncated: scanStart > 0)
        }
        let lineTextProvider: (Int) -> String? = { offset in
            let target = row + offset
            guard target >= 0, target < lineManager.lineCount else {
                return nil
            }
            let line = lineManager.line(atRow: target)
            return stringView.substring(in: NSRange(location: line.location, length: line.data.length))
        }
        let nodeProvider: () -> [SyntaxNode] = {
            languageMode.enclosingSyntaxNodes(at: startPosition)
        }
        return EnterContext(selectedRange: range,
                            textBeforeCaret: before,
                            textAfterCaret: after,
                            leadingWhitespace: leadingWhitespace,
                            indentStrategy: indentStrategy,
                            lineBreak: lineEnding.symbol,
                            behavior: behavior,
                            usesSmartIndent: smart,
                            indentProvider: indentProvider,
                            lineTextProvider: lineTextProvider,
                            nodeProvider: nodeProvider)
    }

    private func scanStartLocation(for caret: Int) -> Int {
        guard caret > Self.maximumScanLength,
              let position = lineManager.linePosition(at: caret - Self.maximumScanLength) else {
            return 0
        }
        return lineManager.line(atRow: position.row).location
    }
}
