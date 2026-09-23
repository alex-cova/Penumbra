import Foundation

public actor LSPDefinitionProvider: NavigationProvider {
    public let name = "LSPDefinition"
    private let client: LSPClient

    public init(client: LSPClient) {
        self.client = client
    }

    public func provide(context: NavigationContext) async -> NavigationResult? {
        guard context.kind == .definition else { return nil }
        do {
            let locations = try await client.requestDefinition(for: context.document, at: context.cursor.position)
            guard !locations.isEmpty else { return nil }
            if locations.count == 1, let lspLocation = locations.first {
                return .single(navigationLocation(from: lspLocation, documentID: context.document.id))
            }
            return .multiple(locations.map { navigationLocation(from: $0, documentID: context.document.id) })
        } catch {
            return nil
        }
    }
}

public actor LSPReferencesProvider: NavigationProvider {
    public let name = "LSPReferences"
    private let client: LSPClient

    public init(client: LSPClient) {
        self.client = client
    }

    public func provide(context: NavigationContext) async -> NavigationResult? {
        guard context.kind == .references else { return nil }
        do {
            let locations = try await client.requestReferences(for: context.document, at: context.cursor.position)
            guard !locations.isEmpty else { return nil }
            return .multiple(locations.map { navigationLocation(from: $0, documentID: context.document.id) })
        } catch {
            return nil
        }
    }
}

public actor LSPImplementationProvider: NavigationProvider {
    public let name = "LSPImplementation"
    private let client: LSPClient

    public init(client: LSPClient) {
        self.client = client
    }

    public func provide(context: NavigationContext) async -> NavigationResult? {
        guard context.kind == .implementation else { return nil }
        do {
            let locations = try await client.requestImplementation(for: context.document, at: context.cursor.position)
            guard !locations.isEmpty else { return nil }
            if locations.count == 1, let lspLocation = locations.first {
                return .single(navigationLocation(from: lspLocation, documentID: context.document.id))
            }
            return .multiple(locations.map { navigationLocation(from: $0, documentID: context.document.id) })
        } catch {
            return nil
        }
    }
}

public actor LSPFormattingProvider {
    public let name = "LSPFormatting"
    private let client: LSPClient

    public init(client: LSPClient) {
        self.client = client
    }

    public func formatDocument(_ document: Document) async -> [TextEdit] {
        await format(document: document, in: nil)
    }

    public func formatSelection(in document: Document, range: TextRange) async -> [TextEdit] {
        await format(document: document, in: range)
    }

    public func format(document: Document, in range: TextRange?) async -> [TextEdit] {
        do {
            let edits = try await client.requestFormatting(for: document, in: range)
            return edits.map { edit in
                TextEdit(
                    range: textRange(from: edit.range),
                    replacement: edit.newText
                )
            }
        } catch {
            return []
        }
    }
}

public actor LSPRenameProvider {
    private let client: LSPClient

    public init(client: LSPClient) {
        self.client = client
    }

    public func rename(document: Document, at position: TextPosition, to newName: String) async -> LSPWorkspaceEdit? {
        try? await client.requestRename(for: document, at: position, to: newName)
    }
}

public actor LSPSignatureHelpProvider: SignatureHelpProviding {
    private let client: LSPClient

    public init(client: LSPClient) {
        self.client = client
    }

    public func signatureHelp(for document: Document, at position: TextPosition) async -> ParameterHintsModel? {
        guard let help = try? await client.requestSignatureHelp(for: document, at: position),
              !help.signatures.isEmpty else {
            return nil
        }
        return ParameterHintsModel(
            signatures: help.signatures,
            activeSignature: help.activeSignature,
            activeParameter: help.activeParameter
        )
    }
}

private func navigationLocation(from lspLocation: LSPLocation, documentID: DocumentID) -> Location {
    Location(
        documentID: documentID,
        url: URL(string: lspLocation.uri),
        range: textRange(from: lspLocation.range),
        displayName: lspLocation.uri
    )
}
