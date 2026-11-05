import Foundation

/// Diagnostic provider that translates LSP diagnostics into EIP diagnostics.
public actor LSPDiagnosticProvider: DiagnosticProvider {
    public let name = "LSP"
    private let client: LSPClient

    public init(client: LSPClient) {
        self.client = client
    }

    public func diagnostics(for document: Document) async -> [Diagnostic] {
        do {
            let lspDiagnostics = try await client.requestDiagnostics(for: document)
            let text = document.text
            return lspDiagnostics.map { diagnostic(from: $0, in: text, source: name) }
        } catch {
            return []
        }
    }
}
