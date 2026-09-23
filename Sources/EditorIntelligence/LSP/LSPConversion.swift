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
public func textPosition(from position: LSPPosition) -> TextPosition {
    TextPosition(line: position.line, column: position.character, utf16Offset: position.character)
}

/// Convert an LSP range to an EIP `TextRange`.
public func textRange(from range: LSPRange) -> TextRange {
    TextRange(start: textPosition(from: range.start), end: textPosition(from: range.end))
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

/// Convert an LSP diagnostic to an EIP diagnostic.
public func diagnostic(from lspDiagnostic: LSPDiagnostic, source: String) -> Diagnostic {
    Diagnostic(
        severity: diagnosticSeverity(from: lspDiagnostic.severity),
        message: lspDiagnostic.message,
        range: textRange(from: lspDiagnostic.range),
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

/// Convert an LSP completion item to an EIP completion item.
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
