import Foundation
import EditorIntelligence

/// Keeps ``JavaIndex``'s overlay in sync with open/edited Java documents -- the equivalent of
/// `EditorIntelligence`'s `IndexingService`, scoped to Java and to updating `JavaIndex` rather than
/// the generic `SymbolIndex`.
///
/// Each open document is re-parsed independently (`documentEdited`/`documentOpened`/
/// `documentChanged` are debounced per document, keyed by `DocumentID`, and skipped entirely if the
/// document's `version` hasn't advanced since the last rebuild), and the merged result across every
/// currently-open Java document is republished to `JavaIndex.setOverlay` after each change -- so
/// one document's overlay entries never get clobbered by another's rebuild.
public actor JavaOverlayService {
    private let index: JavaIndex
    private let debounceNanoseconds: UInt64

    private var debounceTasks: [DocumentID: Task<Void, Never>] = [:]
    private var lastIndexedVersion: [DocumentID: Int] = [:]
    private var fileStubsByDocument: [DocumentID: JavaSourceFileStubs] = [:]
    private var workspaceEventTask: Task<Void, Never>?

    public init(index: JavaIndex, debounceMilliseconds: UInt64 = 300) {
        self.index = index
        self.debounceNanoseconds = debounceMilliseconds * 1_000_000
    }

    /// Subscribes to workspace events and keeps the overlay updated in the background. Cancels any
    /// previous subscription first, so calling this again re-targets a new `Workspace`.
    @discardableResult
    public func connect(to workspace: Workspace) -> Task<Void, Never> {
        workspaceEventTask?.cancel()
        let events = workspace.eventBus.events
        let task = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handle(event)
            }
        }
        workspaceEventTask = task
        return task
    }

    /// The package/import list the overlay parsed for a document, for the semantics layer to
    /// resolve `.unresolved` type references against. `nil` until the document has been indexed at
    /// least once (or if it was never a Java document).
    public func fileStubs(for documentID: DocumentID) -> JavaSourceFileStubs? {
        fileStubsByDocument[documentID]
    }

    // MARK: - Event handling

    private func handle(_ event: WorkspaceEvent) async {
        switch event {
        case .documentOpened(let document), .documentChanged(let document):
            guard isJava(document) else { return }
            scheduleRebuild(for: document, debounced: false)
        case .documentEdited(let document, _):
            guard isJava(document) else { return }
            scheduleRebuild(for: document, debounced: true)
        case .documentClosed(let documentID):
            removeDocument(documentID)
        default:
            break
        }
    }

    private func isJava(_ document: Document) -> Bool {
        document.languageIdentifier == "java"
    }

    private func scheduleRebuild(for document: Document, debounced: Bool) {
        let documentID = document.id
        debounceTasks[documentID]?.cancel()
        let delay = debounced ? debounceNanoseconds : 0
        debounceTasks[documentID] = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled, let self else { return }
            await self.rebuild(document)
        }
    }

    private func rebuild(_ document: Document) async {
        guard lastIndexedVersion[document.id] != document.version else { return }
        guard !document.contentSnapshot.isElided else { return }
        let url = document.url ?? URL(fileURLWithPath: "/unsaved/\(document.id).java")
        let fileStubs = JavaSourceStubBuilder.build(source: document.text, url: url)
        fileStubsByDocument[document.id] = fileStubs
        lastIndexedVersion[document.id] = document.version
        await publishOverlay()
    }

    private func removeDocument(_ documentID: DocumentID) {
        debounceTasks[documentID]?.cancel()
        debounceTasks[documentID] = nil
        guard fileStubsByDocument.removeValue(forKey: documentID) != nil else { return }
        lastIndexedVersion[documentID] = nil
        Task { await self.publishOverlay() }
    }

    private func publishOverlay() async {
        var merged: [String: JavaClassStub] = [:]
        for fileStubs in fileStubsByDocument.values {
            for stub in fileStubs.classes {
                merged[stub.qualifiedName] = stub
            }
        }
        await index.setOverlay(merged)
    }
}
