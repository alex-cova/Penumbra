import Foundation

public actor LSPCodeActionProvider: CodeActionProviding {
    public let name = "LSPCodeAction"
    private let client: LSPClient

    public init(client: LSPClient) {
        self.client = client
    }

    public func codeActions(
        for document: Document,
        at position: TextPosition,
        diagnostics: [Diagnostic]
    ) async -> [CodeAction] {
        do {
            let lspDiagnostics = diagnostics.map(lspDiagnostic(from:))
            let actions = try await client.requestCodeActions(
                for: document,
                at: position,
                diagnostics: lspDiagnostics
            )
            return actions.map { action in
                CodeAction(
                    title: action.title,
                    kind: action.kind,
                    edits: action.edits.map { edit in
                        TextEdit(range: textRange(from: edit.range), replacement: edit.newText)
                    },
                    isPreferred: action.isPreferred
                )
            }
        } catch {
            return []
        }
    }
}

private func lspDiagnostic(from diagnostic: Diagnostic) -> LSPDiagnostic {
    LSPDiagnostic(
        range: lspRange(from: diagnostic.range),
        severity: lspSeverity(from: diagnostic.severity),
        message: diagnostic.message,
        code: diagnostic.code,
        source: diagnostic.source
    )
}

private func lspSeverity(from severity: DiagnosticSeverity) -> Int? {
    switch severity {
    case .error: return 1
    case .warning: return 2
    case .information: return 3
    case .hint: return 4
    }
}
