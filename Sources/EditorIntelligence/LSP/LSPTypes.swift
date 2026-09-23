import Foundation

/// LSP-compatible position (0-based line and character).
public struct LSPPosition: Sendable, Hashable, CustomStringConvertible {
    public let line: Int
    public let character: Int

    public init(line: Int, character: Int) {
        self.line = line
        self.character = character
    }

    public var description: String {
        "\(line):\(character)"
    }
}

/// LSP-compatible range.
public struct LSPRange: Sendable, Hashable, CustomStringConvertible {
    public let start: LSPPosition
    public let end: LSPPosition

    public init(start: LSPPosition, end: LSPPosition) {
        self.start = start
        self.end = end
    }

    public init(_ range: TextRange) {
        self.init(
            start: LSPPosition(line: range.start.line, character: range.start.column),
            end: LSPPosition(line: range.end.line, character: range.end.column)
        )
    }

    public var description: String {
        "\(start)-\(end)"
    }
}

/// LSP diagnostic payload.
public struct LSPDiagnostic: Sendable, Hashable {
    public let range: LSPRange
    public let severity: Int?
    public let message: String
    public let code: String?
    public let source: String?

    public init(range: LSPRange, severity: Int?, message: String, code: String? = nil, source: String? = nil) {
        self.range = range
        self.severity = severity
        self.message = message
        self.code = code
        self.source = source
    }
}

/// LSP hover payload.
public struct LSPHover: Sendable {
    public let contents: String
    public let range: LSPRange?

    public init(contents: String, range: LSPRange? = nil) {
        self.contents = contents
        self.range = range
    }
}

/// LSP completion item payload.
public struct LSPCompletionItem: Sendable, Hashable {
    public let label: String
    public let insertText: String?
    public let kind: Int?
    public let documentation: String?
    public let detail: String?
    /// `insertTextFormat == 2`: `insertText` is a snippet.
    public let isSnippet: Bool
    public let deprecated: Bool
    /// Edits applied with the item, e.g. an import the server adds for the completed type.
    public let additionalTextEdits: [LSPTextEdit]
    public let filterText: String?
    public let sortText: String?

    public init(
        label: String,
        insertText: String? = nil,
        kind: Int? = nil,
        documentation: String? = nil,
        detail: String? = nil,
        isSnippet: Bool = false,
        deprecated: Bool = false,
        additionalTextEdits: [LSPTextEdit] = [],
        filterText: String? = nil,
        sortText: String? = nil
    ) {
        self.label = label
        self.insertText = insertText
        self.kind = kind
        self.documentation = documentation
        self.detail = detail
        self.isSnippet = isSnippet
        self.deprecated = deprecated
        self.additionalTextEdits = additionalTextEdits
        self.filterText = filterText
        self.sortText = sortText
    }
}

/// LSP location (URI + range).
public struct LSPLocation: Sendable, Hashable {
    public let uri: String
    public let range: LSPRange

    public init(uri: String, range: LSPRange) {
        self.uri = uri
        self.range = range
    }
}

/// A single text edit returned by formatting or rename operations.
public struct LSPTextEdit: Sendable, Hashable {
    public let range: LSPRange
    public let newText: String

    public init(range: LSPRange, newText: String) {
        self.range = range
        self.newText = newText
    }
}

/// Workspace edit returned by rename operations.
public struct LSPWorkspaceEdit: Sendable {
    public let changes: [String: [LSPTextEdit]]

    public init(changes: [String: [LSPTextEdit]]) {
        self.changes = changes
    }
}

/// A code action returned by a language server.
public struct LSPCodeAction: Sendable, Hashable {
    public let title: String
    public let kind: String?
    public let edits: [LSPTextEdit]
    public let isPreferred: Bool

    public init(title: String, kind: String? = nil, edits: [LSPTextEdit], isPreferred: Bool = false) {
        self.title = title
        self.kind = kind
        self.edits = edits
        self.isPreferred = isPreferred
    }
}

/// Signature help payload.
public struct LSPSignatureHelp: Sendable {
    public let signatures: [String]
    public let activeSignature: Int
    public let activeParameter: Int

    public init(signatures: [String], activeSignature: Int = 0, activeParameter: Int = 0) {
        self.signatures = signatures
        self.activeSignature = activeSignature
        self.activeParameter = activeParameter
    }
}

/// Compressed semantic token data from a language server.
public struct LSPSemanticTokens: Sendable {
    public let resultId: String?
    public let data: [UInt32]

    public init(resultId: String?, data: [UInt32]) {
        self.resultId = resultId
        self.data = data
    }
}

/// One edit from `textDocument/semanticTokens/full/delta`.
public struct LSPSemanticTokensEdit: Sendable, Hashable {
    public let start: Int
    public let deleteCount: Int
    public let data: [UInt32]

    public init(start: Int, deleteCount: Int, data: [UInt32] = []) {
        self.start = start
        self.deleteCount = deleteCount
        self.data = data
    }
}

/// Semantic token delta returned by `textDocument/semanticTokens/full/delta`.
public struct LSPSemanticTokensDelta: Sendable {
    public let resultId: String?
    /// Full token array when the server returns `SemanticTokens` instead of a delta.
    public let data: [UInt32]
    /// LSP delta edits against the previous `data` array. Applied in reverse start order.
    public let edits: [LSPSemanticTokensEdit]

    public init(resultId: String?, data: [UInt32], edits: [LSPSemanticTokensEdit] = []) {
        self.resultId = resultId
        self.data = data
        self.edits = edits
    }
}

/// Decoded semantic token used for highlighting and storage.
public struct LSPSemanticToken: Sendable, Hashable {
    public let line: Int
    public let character: Int
    public let length: Int
    public let typeIndex: Int
    public let modifiers: UInt32

    public init(line: Int, character: Int, length: Int, typeIndex: Int, modifiers: UInt32) {
        self.line = line
        self.character = character
        self.length = length
        self.typeIndex = typeIndex
        self.modifiers = modifiers
    }
}
