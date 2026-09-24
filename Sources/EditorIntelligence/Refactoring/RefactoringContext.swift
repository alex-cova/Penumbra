import Foundation

/// Context for a refactoring operation.
public struct RefactoringContext: Sendable {
    public let document: Document
    public let cursor: Cursor
    public let selection: Selection
    public let workspace: Workspace?
    public let index: SymbolIndex?
    public let documentURL: URL?

    public init(
        document: Document,
        cursor: Cursor,
        selection: Selection,
        workspace: Workspace? = nil,
        index: SymbolIndex? = nil,
        documentURL: URL? = nil
    ) {
        self.document = document
        self.cursor = cursor
        self.selection = selection
        self.workspace = workspace
        self.index = index
        self.documentURL = documentURL ?? document.url
    }
}
