import Foundation

/// Callbacks fired when documents in an EIP ``Workspace`` should be mirrored to a language server.
public struct LSPDocumentSyncHandlers: Sendable {
    public var onIncrementalChanges: @Sendable ([LSPDocumentSyncService.DocumentChange]) async -> Void
    public var onOpen: @Sendable (Document, String, Int) async -> Void
    public var onFullChange: @Sendable (Document, Int) async -> Void
    public var onClose: @Sendable (DocumentID) async -> Void

    public init(
        onIncrementalChanges: @escaping @Sendable ([LSPDocumentSyncService.DocumentChange]) async -> Void = { _ in },
        onOpen: @escaping @Sendable (Document, String, Int) async -> Void = { _, _, _ in },
        onFullChange: @escaping @Sendable (Document, Int) async -> Void = { _, _ in },
        onClose: @escaping @Sendable (DocumentID) async -> Void = { _ in }
    ) {
        self.onIncrementalChanges = onIncrementalChanges
        self.onOpen = onOpen
        self.onFullChange = onFullChange
        self.onClose = onClose
    }
}

/// Subscribes to ``Workspace`` events and forwards document lifecycle notifications to LSP handlers.
public actor LSPWorkspaceSyncBridge {
  private let syncService: LSPDocumentSyncService
    private let languageResolver: @Sendable (Document) -> String
    private var versions: [DocumentID: Int] = [:]
    private var subscription: Task<Void, Never>?

    public init(
        handlers: LSPDocumentSyncHandlers = LSPDocumentSyncHandlers(),
        batchInterval: TimeInterval = 0.25,
        languageResolver: @escaping @Sendable (Document) -> String = { _ in "plaintext" }
    ) {
        self.syncService = LSPDocumentSyncService(batchInterval: batchInterval, handlers: handlers)
        self.languageResolver = languageResolver
    }

    deinit {
        subscription?.cancel()
    }

    /// Stops following the workspace.
    public func disconnect() {
        subscription?.cancel()
        subscription = nil
    }

    @discardableResult
    public func connect(to workspace: Workspace) -> Task<Void, Never> {
        subscription?.cancel()
        let stream = workspace.eventBus.events
        let task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
        subscription = task
        return task
    }

    private func handle(_ event: WorkspaceEvent) async {
        let signpost = EditorIntelligenceSignposts.performance.beginInterval("LSPWorkspaceSyncBridge.handle")
        defer { EditorIntelligenceSignposts.performance.endInterval("LSPWorkspaceSyncBridge.handle", signpost) }
        switch event {
        case .documentOpened(let document):
            let version = bumpVersion(for: document.id)
            await syncService.notifyOpened(
                document,
                languageID: languageResolver(document),
                version: version
            )
        case .documentChanged(let document):
            let version = bumpVersion(for: document.id)
            await syncService.notifyFullChange(document, version: version)
        case .documentEdited(let document, let edits):
            let version = bumpVersion(for: document.id)
            for edit in edits {
                await syncService.enqueueChange(
                    documentID: document.id,
                    range: LSPRange(edit.range),
                    text: edit.replacement,
                    version: version,
                    rangeLength: max(0, edit.range.end.utf16Offset - edit.range.start.utf16Offset)
                )
            }
        case .documentClosed(let documentID):
            versions.removeValue(forKey: documentID)
            await syncService.documentClosed(documentID: documentID)
        default:
            break
        }
    }

    private func bumpVersion(for documentID: DocumentID) -> Int {
        let version = (versions[documentID] ?? 0) + 1
        versions[documentID] = version
        return version
    }
}
