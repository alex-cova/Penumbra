import EditorIntelligence
import Foundation

/// Tells one language server what the editor holds: `textDocument/didOpen` for each open document in
/// the server's languages, the whole text again after a change, and `didClose`. Without it a server
/// answers every request about an edited file with "No language service found", because it has never
/// been sent the file.
///
/// It follows an EIP ``Workspace``, whose events already say when a tab opens, closes or changes (the
/// app's indexer and Java support read the same stream), and syncs the **whole text** on each change.
/// The workbench adapter has already debounced edits by then, and that adapter itself copies the text
/// once per pause, so this costs the same order of work. Any later change resends everything, so a
/// missed one heals itself.
///
/// What counts as a change: ``Workspace/updateDocument(_:)`` is also called for every document on
/// routine refreshes (tab switches, pane syncs) with nothing new, so a `.documentChanged` event is
/// acted on only when the UTF-16 length differs from what the server has, without copying any text.
/// The client applies the same rule before each request, because the adapter's debounce means a
/// completion asked a keystroke after typing reaches a server that has not been sent that keystroke.
/// A `.documentEdited` event is always acted on. The gap is a same-length replacement that arrives as
/// a plain change (a reload from disk of a file of identical length): the server keeps the old text
/// until the next edit.
///
/// Documents with no file URL, in other languages, or longer than ``maximumUTF16Length`` are not sent.
public actor LSPWorkspaceDocumentSync {
    private let client: LanguageServerClient
    private let languages: Set<String>
    private let maximumUTF16Length: Int
    private let maximumGeneratedInterfaceUTF16Length: Int
    /// The documents the server has been sent. Their versions and lengths are the client's
    /// (`LanguageServerClient.syncFullText`), which also refreshes a document before any request about it.
    private var tracked: Set<DocumentID> = []
    private var task: Task<Void, Never>?
    /// Set by ``stop()``. A stop can arrive while ``start(workspace:)`` is still opening documents (an
    /// actor lets other calls in at each `await`), and a follower started after it would outlive the server.
    private var stopped = false

    /// `languages` are the identifiers the server serves (`swift`); `maximumUTF16Length` keeps a
    /// generated or minified file from being copied to the server on every pause. A server-generated
    /// interface (`DependencySourceLocation`) is read-only, so it is sent once and never again: it gets
    /// a higher limit, because `Foundation`'s is 2.3 MB and the server answers inside it only once sent.
    public init(
        client: LanguageServerClient,
        languages: Set<String>,
        maximumUTF16Length: Int = 2_000_000,
        maximumGeneratedInterfaceUTF16Length: Int = 16_000_000
    ) {
        self.client = client
        self.languages = languages
        self.maximumUTF16Length = maximumUTF16Length
        self.maximumGeneratedInterfaceUTF16Length = maximumGeneratedInterfaceUTF16Length
    }

    /// Opens what is open now, then follows the workspace until ``stop()``. The subscription is made
    /// before the snapshot is read, so a document opened in between is seen twice and handled once.
    public func start(workspace: Workspace) async {
        guard !stopped else { return }
        task?.cancel()
        let events = workspace.eventBus.events
        for document in await workspace.allOpenDocuments() {
            guard !stopped else { return }
            await opened(document)
        }
        guard !stopped else { return }
        task = Task { [weak self] in
            for await event in events {
                if Task.isCancelled { return }
                await self?.handle(event)
            }
        }
    }

    /// Stops following. Sends nothing: the server is going away, or a new sync replaces this one.
    public func stop() {
        stopped = true
        task?.cancel()
        task = nil
        tracked = []
    }

    /// The documents the server currently has, for tests.
    public var syncedDocumentCount: Int { tracked.count }

    // MARK: - Events

    private func handle(_ event: WorkspaceEvent) async {
        switch event {
        case .documentOpened(let document): await opened(document)
        case .documentChanged(let document): await changed(document, force: false)
        case .documentEdited(let document, _): await changed(document, force: true)
        case .documentClosed(let id): await closed(id)
        default: break
        }
    }

    private func opened(_ document: Document) async {
        guard isSynced(document) else { return }
        guard !tracked.contains(document.id) else { return await changed(document, force: false) }
        tracked.insert(document.id)
        await client.notifyOpened(document, languageID: document.languageIdentifier ?? "plaintext", version: 1)
    }

    private func changed(_ document: Document, force: Bool) async {
        guard tracked.contains(document.id) else { return await opened(document) }
        guard isSynced(document) else { return await closed(document.id) }
        await client.syncFullText(of: document, force: force)
    }

    private func closed(_ id: DocumentID) async {
        guard tracked.remove(id) != nil else { return }
        await client.notifyClosed(documentID: id)
    }

    private func isSynced(_ document: Document) -> Bool {
        guard let url = document.url, url.isFileURL,
              let language = document.languageIdentifier, languages.contains(language) else { return false }
        let limit = DependencySourceLocation.isGeneratedInterface(url) ? maximumGeneratedInterfaceUTF16Length : maximumUTF16Length
        return document.contentSnapshot.utf16Length <= limit
    }
}
