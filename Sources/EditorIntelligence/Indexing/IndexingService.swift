import Foundation

/// Background indexing service that keeps the `SymbolIndex` in sync with the workspace.
///
/// The service listens to `WorkspaceEvent`s, parses changed documents with a `LanguageParser`, and
/// forwards extracted symbols and words to the `SymbolIndex`. It runs entirely on its own actor.
public actor IndexingService {
    /// Names (words and parser symbols) longer than this are not indexed. They are never something a
    /// person completes or looks up (Base64 blobs, hashes, minified runs), and each one would cost a
    /// trie node per character.
    public static let maxNameLength = 256

    public let index: SymbolIndex
    private let parser: LanguageParser
    private let debounceNanoseconds: UInt64
    private var workspaceEventTask: Task<Void, Never>?
    private var pendingTasks: [DocumentID: Task<Void, Never>] = [:]
    private var lastIndexedVersion: [DocumentID: Int] = [:]

    /// `debounceMilliseconds` coalesces a burst of edits to one document into a single re-parse.
    public init(parser: LanguageParser, index: SymbolIndex = SymbolIndex(), debounceMilliseconds: UInt64 = 300) {
        self.parser = parser
        self.index = index
        self.debounceNanoseconds = debounceMilliseconds * 1_000_000
    }

    /// Subscribe to workspace events and index documents in the background.
    @discardableResult
    public func connect(to workspace: Workspace) -> Task<Void, Never> {
        workspaceEventTask?.cancel()
        let events = workspace.eventBus.events
        let task = Task {
            for await event in events {
                await handleWorkspaceEvent(event)
            }
        }
        workspaceEventTask = task
        return task
    }

    /// Manually index a single document. Useful for seeding the index outside of workspace events.
    public func indexDocument(_ document: Document) async {
        let signpost = EditorIntelligenceSignposts.performance.beginInterval("IndexingService.indexDocument")
        defer { EditorIntelligenceSignposts.performance.endInterval("IndexingService.indexDocument", signpost) }
        if document.contentSnapshot.isElided {
            return
        }
        let tree = await parser.parse(document: document)
        // The parse can outlive its document: a close or a newer edit cancels this task meanwhile.
        guard !Task.isCancelled else { return }
        var symbols = tree.symbols.filter { $0.name.count <= Self.maxNameLength }
        let wordSymbols = tree.words.filter { $0.count <= Self.maxNameLength }.map { word in
            Symbol(
                name: word,
                kind: .word,
                documentID: document.id,
                range: TextRange(start: TextPosition(line: 0, column: 0, utf16Offset: 0),
                                 end: TextPosition(line: 0, column: 0, utf16Offset: 0))
            )
        }
        symbols.append(contentsOf: wordSymbols)
        if let url = document.url {
            symbols.append(Symbol(
                name: url.lastPathComponent,
                kind: .fileName,
                documentID: document.id,
                range: TextRange(start: TextPosition(line: 0, column: 0, utf16Offset: 0),
                                 end: TextPosition(line: 0, column: 0, utf16Offset: 0))
            ))
        }
        guard !Task.isCancelled else { return }
        lastIndexedVersion[document.id] = document.version
        await index.index(symbols, for: document.id)
    }

    private func handleWorkspaceEvent(_ event: WorkspaceEvent) async {
        switch event {
        case .documentOpened(let document), .documentChanged(let document):
            schedule(document, debounced: false)
        case .documentEdited(let document, _):
            schedule(document, debounced: true)
        case .documentClosed(let documentID):
            pendingTasks.removeValue(forKey: documentID)?.cancel()
            lastIndexedVersion[documentID] = nil
            await index.remove(documentID: documentID)
        default:
            break
        }
    }

    /// Replaces any pending index of the same document, so only the latest snapshot is parsed.
    private func schedule(_ document: Document, debounced: Bool) {
        let documentID = document.id
        pendingTasks[documentID]?.cancel()
        let delay = debounced ? debounceNanoseconds : 0
        pendingTasks[documentID] = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled, let self else { return }
            // An edit that leaves the version where it was (a selection-only update) has nothing new
            // to index. Opens and changes skip this check: the file name can change without it.
            if debounced, await self.lastIndexedVersion[documentID] == document.version { return }
            await self.indexDocument(document)
        }
    }
}
