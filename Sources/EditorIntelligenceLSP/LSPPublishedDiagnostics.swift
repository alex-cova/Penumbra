import EditorIntelligence
import Foundation
import LanguageServerProtocol

/// Diagnostics a server has pushed for each file. An empty list removes that file.
public struct LSPPublishedDiagnostics: Sendable, Equatable {
    public private(set) var files: [String: File] = [:]

    public struct File: Sendable, Equatable {
        public var version: Int?
        public var diagnostics: [EditorIntelligence.LSPDiagnostic]
    }

    public init() {}

    public mutating func apply(_ params: PublishDiagnosticsParams) {
        let uri = params.uri
        if params.diagnostics.isEmpty {
            files[uri] = nil
            return
        }
        files[uri] = File(version: params.version, diagnostics: params.diagnostics.map(lspDiagnostic))
    }

    public func diagnostics(for uri: String) -> [EditorIntelligence.LSPDiagnostic] {
        files[uri]?.diagnostics ?? []
    }

    public func version(for uri: String) -> Int? {
        files[uri]?.version
    }
}

/// Why a watched file changed, for `workspace/didChangeWatchedFiles`.
public enum LSPWatchedFileChange: Sendable {
    case created, changed, deleted

    var lsp: FileChangeType {
        switch self {
        case .created: return .created
        case .changed: return .changed
        case .deleted: return .deleted
        }
    }
}

/// One outline row from `documentSymbol` or `workspace/symbol`.
public struct LSPOutlineSymbol: Sendable, Equatable {
    public var name: String
    public var kind: String
    public var detail: String?
    public var uri: String?
    public var range: EditorIntelligence.LSPRange
    public var children: [LSPOutlineSymbol]

    public init(
        name: String, kind: String, detail: String? = nil, uri: String? = nil,
        range: EditorIntelligence.LSPRange, children: [LSPOutlineSymbol] = []
    ) {
        self.name = name
        self.kind = kind
        self.detail = detail
        self.uri = uri
        self.range = range
        self.children = children
    }

    public init(_ symbol: DocumentSymbol) {
        self.init(
            name: symbol.name,
            kind: String(describing: symbol.kind),
            detail: symbol.detail,
            range: eipRange(from: symbol.selectionRange),
            children: (symbol.children ?? []).map(LSPOutlineSymbol.init)
        )
    }

    public init(_ symbol: SymbolInformation) {
        self.init(
            name: symbol.name,
            kind: String(describing: symbol.kind),
            detail: symbol.containerName,
            uri: symbol.location.uri,
            range: eipRange(from: symbol.location.range)
        )
    }

    public init(workspace symbol: WorkspaceSymbol) {
        let uri: String?
        let range: EditorIntelligence.LSPRange
        switch symbol.location {
        case .optionA(let location):
            uri = location.uri
            range = eipRange(from: location.range)
        case .optionB(let document):
            uri = document.uri
            range = EditorIntelligence.LSPRange(
                start: EditorIntelligence.LSPPosition(line: 0, character: 0),
                end: EditorIntelligence.LSPPosition(line: 0, character: 0)
            )
        case nil:
            uri = nil
            range = EditorIntelligence.LSPRange(
                start: EditorIntelligence.LSPPosition(line: 0, character: 0),
                end: EditorIntelligence.LSPPosition(line: 0, character: 0)
            )
        }
        self.init(name: symbol.name, kind: String(describing: symbol.kind), detail: symbol.containerName, uri: uri, range: range)
    }
}

/// One inlay hint with a display label and the original protocol item.
public struct LSPRenderedInlayHint: Sendable, Equatable {
    public var line: Int
    public var character: Int
    public var label: String
    public var kind: String?
    public private(set) var protocolHint: LanguageServerProtocol.InlayHint?
    public private(set) var tooltip: String?

    public init(line: Int, character: Int, label: String, kind: String? = nil) {
        self.line = line
        self.character = character
        self.label = label
        self.kind = kind
    }

    public init(_ hint: LanguageServerProtocol.InlayHint) {
        let label: String
        switch hint.label {
        case .optionA(let text):
            label = text
        case .optionB(let parts):
            label = parts.map(\.value).joined()
        }
        let kind: String?
        switch hint.kind {
        case .type: kind = "type"
        case .parameter: kind = "parameter"
        case nil: kind = nil
        }
        self.init(line: hint.position.line, character: hint.position.character, label: label, kind: kind)
        protocolHint = hint
        let labelTooltips: [String]
        switch hint.label {
        case .optionA: labelTooltips = []
        case .optionB(let parts): labelTooltips = parts.compactMap { Self.text($0.tooltip) }
        }
        tooltip = Self.text(hint.tooltip) ?? (labelTooltips.isEmpty ? nil : labelTooltips.joined(separator: "\n"))
    }

    /// Equality describes the flattened display value exposed before wire metadata was retained.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.line == rhs.line && lhs.character == rhs.character && lhs.label == rhs.label && lhs.kind == rhs.kind
    }

    func acceptanceEdits(in map: SourceTextMap) -> [EditorIntelligence.TextEdit] {
        guard let edits = protocolHint?.textEdits, !edits.isEmpty, edits.count <= 8 else { return [] }
        var result: [EditorIntelligence.TextEdit] = []
        for edit in edits {
            let start = edit.range.start
            let end = edit.range.end
            guard let lower = map.utf16Offset(line: start.line, column: start.character),
                  let upper = map.utf16Offset(line: end.line, column: end.character),
                  lower <= upper, edit.newText.utf16.count <= 4096 else { return [] }
            let range = EditorIntelligence.TextRange(
                start: TextPosition(line: start.line, column: start.character, utf16Offset: lower),
                end: TextPosition(line: end.line, column: end.character, utf16Offset: upper)
            )
            result.append(EditorIntelligence.TextEdit(range: range, replacement: edit.newText))
        }
        result.sort { $0.range.start.utf16Offset < $1.range.start.utf16Offset }
        for (lhs, rhs) in zip(result, result.dropFirst()) {
            guard lhs.range.start.utf16Offset < rhs.range.start.utf16Offset,
                  lhs.range.end.utf16Offset <= rhs.range.start.utf16Offset else { return [] }
        }
        return result
    }

    private static func text(_ value: TwoTypeOption<String, MarkupContent>?) -> String? {
        switch value {
        case .optionA(let text): text
        case .optionB(let markup): markup.value
        case nil: nil
        }
    }
}

private func lspDiagnostic(_ diagnostic: LanguageServerProtocol.Diagnostic) -> EditorIntelligence.LSPDiagnostic {
    EditorIntelligence.LSPDiagnostic(
        range: eipRange(from: diagnostic.range),
        severity: diagnostic.severity?.rawValue,
        message: diagnostic.message,
        code: nil,
        source: diagnostic.source
    )
}
