import Foundation

/// Lightweight workspace service that tracks projects and open documents.
///
/// `Workspace` is an actor: all mutation and queries happen in isolation. It consumes
/// `EditorEvent`s from an adapter and emits `WorkspaceEvent`s through an event bus.
public actor Workspace {
    public let id: UUID
    public nonisolated let eventBus: EventBus<WorkspaceEvent>

    private var projects: [Project] = []
    private var openDocuments: [DocumentID: Document] = [:]
    private var activeDocumentID: DocumentID?
    private var fileSystemWatcher: FileSystemWatcher?
    private var fileSystemWatcherTask: Task<Void, Never>?
    private var adapterEventTask: Task<Void, Never>?

    public init(id: UUID = UUID()) {
        self.id = id
        self.eventBus = EventBus()
    }

    deinit {
        fileSystemWatcherTask?.cancel()
        adapterEventTask?.cancel()
    }

    /// Ends the subscriptions this workspace made (the adapter's events and the file watcher's).
    /// A host calls it when the window goes; dropping the workspace has the same effect.
    public func disconnect() async {
        adapterEventTask?.cancel()
        adapterEventTask = nil
        fileSystemWatcherTask?.cancel()
        fileSystemWatcherTask = nil
        await fileSystemWatcher?.stop()
        fileSystemWatcher = nil
    }

    // MARK: - Projects

    public func addProject(_ project: Project) {
        projects.append(project)
        eventBus.send(.projectAdded(project))
        eventBus.send(.workspaceChanged)
    }

    public func removeProject(_ projectID: UUID) {
        projects.removeAll { $0.id == projectID }
        eventBus.send(.projectRemoved(projectID))
        eventBus.send(.workspaceChanged)
    }

    public func allProjects() -> [Project] {
        projects
    }

    // MARK: - Documents

    public func openDocument(_ document: Document) {
        openDocuments[document.id] = document
        activeDocumentID = document.id
        eventBus.send(.documentOpened(document))
        eventBus.send(.documentActivated(document.id))
        eventBus.send(.workspaceChanged)
    }

    public func closeDocument(_ documentID: DocumentID) {
        openDocuments.removeValue(forKey: documentID)
        eventBus.send(.documentClosed(documentID))
        if activeDocumentID == documentID {
            activeDocumentID = nil
        }
        eventBus.send(.workspaceChanged)
    }

    public func updateDocument(_ document: Document) {
        openDocuments[document.id] = document
        eventBus.send(.documentChanged(document))
    }

    public func activateDocument(_ documentID: DocumentID) {
        guard openDocuments[documentID] != nil else {
            return
        }
        activeDocumentID = documentID
        eventBus.send(.documentActivated(documentID))
    }

    public func document(withID id: DocumentID) -> Document? {
        openDocuments[id]
    }

    public func allOpenDocuments() -> [Document] {
        Array(openDocuments.values)
    }

    public func activeDocument() -> Document? {
        guard let activeDocumentID = activeDocumentID else {
            return nil
        }
        return openDocuments[activeDocumentID]
    }

    // MARK: - Editor Event Handling

    public func handleEditorEvent(_ event: EditorEvent) async {
        switch event {
        case .documentOpened(let document):
            openDocument(document)
        case .documentClosed(let documentID):
            closeDocument(documentID)
        case .documentChanged(let documentID, let snapshot):
            if let document = openDocuments[documentID] {
                let updated = Document(
                    id: document.id,
                    url: document.url,
                    displayName: document.displayName,
                    contentSnapshot: snapshot,
                    selection: document.selection,
                    cursor: document.cursor,
                    viewport: document.viewport,
                    languageIdentifier: document.languageIdentifier
                )
                updateDocument(updated)
            }
        case .documentEdited(let documentID, let edits, newSnapshot: let snapshot):
            if let document = openDocuments[documentID] {
                let updated = Document(
                    id: document.id,
                    url: document.url,
                    displayName: document.displayName,
                    contentSnapshot: snapshot,
                    selection: document.selection,
                    cursor: document.cursor,
                    viewport: document.viewport,
                    languageIdentifier: document.languageIdentifier
                )
                openDocuments[document.id] = updated
                eventBus.send(.documentEdited(updated, edits))
            }
        case .selectionChanged(let documentID, let selection):
            if let document = openDocuments[documentID] {
                openDocuments[documentID] = Document(
                    id: document.id,
                    url: document.url,
                    displayName: document.displayName,
                    contentSnapshot: document.contentSnapshot,
                    selection: selection,
                    cursor: document.cursor,
                    viewport: document.viewport,
                    languageIdentifier: document.languageIdentifier
                )
            }
        case .cursorMoved(let documentID, let cursor):
            if let document = openDocuments[documentID] {
                openDocuments[documentID] = Document(
                    id: document.id,
                    url: document.url,
                    displayName: document.displayName,
                    contentSnapshot: document.contentSnapshot,
                    selection: document.selection,
                    cursor: cursor,
                    viewport: document.viewport,
                    languageIdentifier: document.languageIdentifier
                )
            }
        case .viewportChanged(let documentID, let viewport):
            if let document = openDocuments[documentID] {
                openDocuments[documentID] = Document(
                    id: document.id,
                    url: document.url,
                    displayName: document.displayName,
                    contentSnapshot: document.contentSnapshot,
                    selection: document.selection,
                    cursor: document.cursor,
                    viewport: viewport,
                    languageIdentifier: document.languageIdentifier
                )
            }
        case .documentActivated(let documentID):
            activateDocument(documentID)
        }
    }

    // MARK: - File System Watching

    /// Attach a file-system watcher to the workspace. When files change, the workspace emits
    /// a `workspaceChanged` event so that downstream services can re-index as needed.
    public func setFileSystemWatcher(_ watcher: FileSystemWatcher) async {
        await fileSystemWatcher?.stop()
        fileSystemWatcher = watcher
        fileSystemWatcherTask?.cancel()
        // Weak: the task lives as long as the watcher's stream does, and a strong capture made the
        // workspace and its own task keep each other alive (F12).
        fileSystemWatcherTask = Task { [weak self] in
            await watcher.start()
            for await event in watcher.events {
                guard let self else { return }
                await self.handleFileSystemEvent(event)
            }
        }
    }

    private func handleFileSystemEvent(_ event: FileSystemEvent) {
        // Foundation phase: surface all file-system changes as a generic workspace update.
        // Later phases will route events to the index (added/removed/changed symbols).
        eventBus.send(.workspaceChanged)
    }

    // MARK: - Subscription

    /// Subscribe to an editor adapter's events and update the workspace in the background.
    @discardableResult
    public func connect(to adapter: EditorAdapter) -> Task<Void, Never> {
        adapterEventTask?.cancel()
        let stream = adapter.events
        let task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handleEditorEvent(event)
            }
        }
        adapterEventTask = task
        return task
    }
}
