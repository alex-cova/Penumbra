import Foundation

/// Convert an EIP `TextPosition` to an LSP position.
public func lspPosition(from position: TextPosition) -> LSPPosition {
    LSPPosition(line: position.line, character: position.column)
}

/// Convert an EIP `TextRange` to an LSP range.
public func lspRange(from range: TextRange) -> LSPRange {
    LSPRange(start: lspPosition(from: range.start), end: lspPosition(from: range.end))
}

/// Convert an LSP position to an EIP `TextPosition`.
///
/// The `utf16Offset` is the line-local character here, not a global document offset: without
/// the document text the global offset is unknowable (LSP positions carry no file identity).
/// Anything that navigates to the position must go through line and column (see
/// `ProblemLocator`); anything that needs a global offset must use
/// `textPosition(from:in:)`. Cross-file conversions (navigation targets, other files' edits)
/// keep this form because the target text is not available.
public func textPosition(from position: LSPPosition) -> TextPosition {
    TextPosition(line: position.line, column: position.character, utf16Offset: position.character)
}

/// Convert an LSP range to an EIP `TextRange`. Same line-local caveat as
/// `textPosition(from:)`; prefer `textRange(from:in:)` when the source text is available.
public func textRange(from range: LSPRange) -> TextRange {
    TextRange(start: textPosition(from: range.start), end: textPosition(from: range.end))
}

/// Convert an LSP position to an EIP `TextPosition` with the true global UTF-16 offset resolved
/// against `text`. Out-of-range lines/characters clamp to the end of their line, or the text.
public func textPosition(from position: LSPPosition, in text: String) -> TextPosition {
    TextPosition(
        line: position.line,
        column: position.character,
        utf16Offset: utf16Offset(line: position.line, character: position.character, in: text)
    )
}

/// Convert an LSP range to an EIP `TextRange` with global UTF-16 offsets resolved against `text`.
public func textRange(from range: LSPRange, in text: String) -> TextRange {
    TextRange(start: textPosition(from: range.start, in: text), end: textPosition(from: range.end, in: text))
}

/// Global UTF-16 offset of a line/character position in `text`. Lines are 0-based and terminated
/// by `\n`, `\r\n` or `\r`; columns are UTF-16 code units from the line start. Out-of-range
/// positions clamp to the end of their line, or of the text.
public func utf16Offset(line: Int, character: Int, in text: String) -> Int {
    let utf16 = Array(text.utf16)
    var index = 0
    var current = 0
    while current < line, index < utf16.count {
        let unit = utf16[index]
        index += 1
        if unit == 0x0A || (unit == 0x0D && !(index < utf16.count && utf16[index] == 0x0A)) {
            current += 1
        }
    }
    guard current == line else { return utf16.count }
    var lineEnd = index
    while lineEnd < utf16.count, utf16[lineEnd] != 0x0A, utf16[lineEnd] != 0x0D {
        lineEnd += 1
    }
    return min(index + max(0, character), lineEnd)
}

/// Convert an LSP diagnostic severity integer to an EIP severity.
///
/// LSP severity values: 1 = error, 2 = warning, 3 = information, 4 = hint.
public func diagnosticSeverity(from lspSeverity: Int?) -> DiagnosticSeverity {
    switch lspSeverity {
    case 1: return .error
    case 2: return .warning
    case 3: return .information
    case 4: return .hint
    default: return .information
    }
}

/// Convert an LSP diagnostic to an EIP diagnostic. Same line-local caveat as
/// `textPosition(from:)`; prefer `diagnostic(from:in:source:)` when the source text is available.
public func diagnostic(from lspDiagnostic: LSPDiagnostic, source: String) -> Diagnostic {
    Diagnostic(
        severity: diagnosticSeverity(from: lspDiagnostic.severity),
        message: lspDiagnostic.message,
        range: textRange(from: lspDiagnostic.range),
        source: source,
        code: lspDiagnostic.code
    )
}

/// Convert an LSP diagnostic to an EIP diagnostic with the global range offset resolved
/// against `text`.
public func diagnostic(from lspDiagnostic: LSPDiagnostic, in text: String, source: String) -> Diagnostic {
    Diagnostic(
        severity: diagnosticSeverity(from: lspDiagnostic.severity),
        message: lspDiagnostic.message,
        range: textRange(from: lspDiagnostic.range, in: text),
        source: source,
        code: lspDiagnostic.code
    )
}

/// Convert an LSP completion kind integer to an EIP completion item kind.
///
/// LSP completion item kinds: 1 = text, 2 = method, 3 = function, 4 = constructor, 5 = field,
/// 6 = variable, 7 = class, 8 = interface, 9 = module, 10 = property, 11 = unit, 12 = value,
/// 13 = enum, 14 = keyword, 15 = snippet, 16 = color, 17 = file, 18 = reference, 19 = folder,
/// 20 = enum member, 21 = constant, 22 = struct, 23 = event, 24 = operator, 25 = type parameter.
public func completionItemKind(from lspKind: Int?) -> CompletionItemKind {
    switch lspKind {
    case 2: return .method
    case 3: return .function
    case 4: return .constructor
    case 5: return .field
    case 10: return .property
    case 6, 21: return .variable
    case 7, 22: return .class
    case 8: return .interface
    case 9: return .module
    case 13: return .enum
    case 20: return .enumMember
    case 25: return .type
    case 14: return .keyword
    case 15: return .snippet
    case 17, 19: return .file
    default: return .text
    }
}

/// Convert an LSP completion item to an EIP completion item. Additional edits keep the
/// line-local offset form; prefer `completionItem(from:source:range:in:)` when the text is
/// available.
public func completionItem(from lspItem: LSPCompletionItem, source: String, range: TextRange) -> CompletionItem {
    CompletionItem(
        label: lspItem.label,
        insertText: lspItem.insertText ?? lspItem.label,
        kind: completionItemKind(from: lspItem.kind),
        range: range,
        source: source,
        documentation: lspItem.documentation,
        sortText: lspItem.sortText,
        filterText: lspItem.filterText,
        detail: lspItem.detail,
        isDeprecated: lspItem.deprecated,
        insertTextIsSnippet: lspItem.isSnippet,
        additionalEdits: lspItem.additionalTextEdits.map {
            TextEdit(range: textRange(from: $0.range), replacement: $0.newText)
        }
    )
}

/// Convert an LSP completion item to an EIP completion item with additional-edit ranges
/// resolved to global offsets against `text`.
public func completionItem(from lspItem: LSPCompletionItem, source: String, range: TextRange, in text: String) -> CompletionItem {
    CompletionItem(
        label: lspItem.label,
        insertText: lspItem.insertText ?? lspItem.label,
        kind: completionItemKind(from: lspItem.kind),
        range: range,
        source: source,
        documentation: lspItem.documentation,
        sortText: lspItem.sortText,
        filterText: lspItem.filterText,
        detail: lspItem.detail,
        isDeprecated: lspItem.deprecated,
        insertTextIsSnippet: lspItem.isSnippet,
        additionalEdits: lspItem.additionalTextEdits.map {
            TextEdit(range: textRange(from: $0.range, in: text), replacement: $0.newText)
        }
    )
}
