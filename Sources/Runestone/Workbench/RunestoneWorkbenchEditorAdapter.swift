import EditorIntelligence
import Foundation

/// ``EditorAdapter`` that aggregates open ``WorkbenchDocument``s and tracks the active pane's ``TextView``.
public final class RunestoneWorkbenchEditorAdapter: EditorAdapter, @unchecked Sendable {
    public let id: EditorAdapterID
    public let context: EditorContext
    public var events: AsyncStream<EditorEvent> { eventBus.events }

    public let workbench: EditorWorkbench
    public weak var textView: TextView?
    public weak var forwardingDelegate: TextViewDelegate?

    /// Invoked (on the main actor) when ⌘[ / ⌘] lands on an entry belonging to a document
    /// other than the one currently shown. Open that document, focus `entry.location`, and
    /// return `true`; return `false` to let the current text view handle it locally.
    @MainActor
    public var onOpenHistoryEntry: ((NavigationEntry) -> Bool)?

    private let eventBus = EventBus<EditorEvent>()
    private let lock = NSLock()
    private var liveDocumentID: DocumentID?
    private var cachedOpenDocuments: [Document] = []
    private var contentRefreshTask: Task<Void, Never>?
    private var pendingContentChanges: [TextEdit] = []
    /// Matches ``LSPDocumentSyncService``'s default `batchInterval`. See
    /// PERFORMANCE_AUDIT.md Phase 2 #1 — `selected.text = textView.text` is an O(document size)
    /// bridge, and used to run on every keystroke.
    private static let contentRefreshDebounceNanoseconds: UInt64 = 200_000_000

    public init(workbench: EditorWorkbench, textView: TextView? = nil, context: EditorContext = EditorContext()) {
        self.workbench = workbench
        self.textView = textView
        self.context = context
        self.id = context.adapterID
        if let textView {
            MainActor.assumeIsolated {
                textView.editorDelegate = self
            }
        }
        refreshCachedDocuments(emitEvents: false)
    }

    /// Wires the shared workbench cursor history and document identity into `textView` so
    /// ⌘[ / ⌘] step across documents. Call whenever a pane's text view starts showing
    /// `document`.
    @MainActor
    public func bindNavigationHistory(to textView: TextView, document: WorkbenchDocument) {
        textView.navigationHistory = workbench.navigationHistory
        textView.documentIdentifier = document.id
        textView.documentURL = document.url
        textView.onNavigateToHistoryEntry = { [weak self] entry in
            self?.onOpenHistoryEntry?(entry) ?? false
        }
    }

    public var currentDocument: Document? {
        lock.withLock {
            if let liveDocumentID,
               let match = cachedOpenDocuments.first(where: { $0.id == liveDocumentID }) {
                return match
            }
            return workbench.activePane.selectedDocument.map { $0.makeEIPDocument() }
        }
    }

    public var openDocuments: [Document] {
        lock.withLock { cachedOpenDocuments }
    }

    public func document(withID id: DocumentID) -> Document? {
        lock.withLock { cachedOpenDocuments.first { $0.id == id } }
    }

    public func applyEdit(_ edit: TextEdit, toDocumentWithID documentID: DocumentID) async throws {
        guard let textView = textView else {
            throw RunestoneEditorAdapterError.textViewDeallocated
        }
        guard document(withID: documentID) != nil else {
            throw RunestoneEditorAdapterError.unknownDocumentID(documentID)
        }
        await MainActor.run {
            let range = TextEditApplicator.nsRange(for: edit.range, in: textView)
            textView.replace(range, withText: edit.replacement)
        }
    }

    public func focusRange(_ range: EditorIntelligence.TextRange, inDocumentWithID documentID: DocumentID) async throws {
        guard document(withID: documentID) != nil else {
            throw RunestoneEditorAdapterError.unknownDocumentID(documentID)
        }
        guard let textView = textView else {
            throw RunestoneEditorAdapterError.textViewDeallocated
        }
        await MainActor.run {
            let nsRange = TextEditApplicator.nsRange(for: range, in: textView)
            textView.selectedRanges = [nsRange]
        }
    }

    public func refreshCachedDocuments(emitEvents: Bool = true) {
        let activePane = workbench.activePane
        let documents = workbench.allDocuments().map { $0.makeEIPDocument() }
        lock.withLock {
            cachedOpenDocuments = documents
            liveDocumentID = activePane.selectedDocument?.documentID
        }
        guard emitEvents else { return }
        for document in documents {
            eventBus.send(.documentChanged(document.id, document.contentSnapshot))
        }
        if let selected = activePane.selectedDocument {
            let doc = selected.makeEIPDocument()
            eventBus.send(.selectionChanged(doc.id, doc.selection))
            eventBus.send(.cursorMoved(doc.id, doc.cursor))
        }
    }

    /// Selection/scroll-only refresh: cheap (an `NSRange`/`CGPoint` copy), so this stays
    /// synchronous and immediate — unlike ``scheduleContentRefresh(from:)``, it does not touch
    /// `selected.text`, reusing whatever content snapshot is already cached instead of re-bridging
    /// the whole document. Mirrors the same optimization in ``RunestoneEditorAdapter``.
    @MainActor
    func refreshLiveDocumentFromTextView(_ textView: TextView) {
        guard let selected = workbench.activePane.selectedDocument else { return }
        selected.selectedRange = textView.selectedRange
        selected.scrollOffset = textView.contentOffset
        let document = selected.makeEIPDocument()
        lock.withLock {
            liveDocumentID = selected.documentID
            if let index = cachedOpenDocuments.firstIndex(where: { $0.id == document.id }) {
                cachedOpenDocuments[index] = document
            }
        }
        eventBus.send(.selectionChanged(document.id, document.selection))
        eventBus.send(.cursorMoved(document.id, document.cursor))
    }

    /// Debounced: `document.text = textView.text` is an O(document size) bridge, and this used to
    /// run on every keystroke via `textViewDidChange`. See PERFORMANCE_AUDIT.md Phase 2 #1.
    ///
    /// `document` is captured at schedule time (the pane's *active* document at the moment of the
    /// edit), not re-derived from `workbench.activePane.selectedDocument` when the task fires —
    /// this is a multi-pane adapter, so the user can switch tabs during the debounce window, and a
    /// late-firing refresh must still land on the document it was scheduled for, not whatever
    /// happens to be active 200ms later.
    private func scheduleContentRefresh(from textView: TextView, for document: WorkbenchDocument) {
        contentRefreshTask?.cancel()
        contentRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.contentRefreshDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.refreshLiveDocumentContent(from: textView, for: document)
        }
    }

    @MainActor
    private func refreshLiveDocumentContent(from textView: TextView, for document: WorkbenchDocument) {
        if let snapshot = textView.pieceTreeContentSnapshot() {
            document.rangeReader = TextRangeReader(utf16Length: snapshot.utf16Length) { offset, length in
                snapshot.substring(utf16Offset: offset, length: length)
            }
            if textView.isFileBacked {
                document.text = ""
                document.isFileBacked = true
            }
        } else {
            document.text = textView.text
            document.rangeReader = nil
        }
        document.selectedRange = textView.selectedRange
        document.scrollOffset = textView.contentOffset
        let eipDocument = document.makeEIPDocument()
        lock.withLock {
            if let index = cachedOpenDocuments.firstIndex(where: { $0.id == eipDocument.id }) {
                cachedOpenDocuments[index] = eipDocument
            }
            // Only update the "live" pointer if this document is still the active one — a
            // debounced refresh that lands after the user switched tabs shouldn't make a
            // now-inactive document look current.
            if workbench.activePane.selectedDocument === document {
                liveDocumentID = document.documentID
            }
        }
        eventBus.send(editsEvent(for: eipDocument))
        eventBus.send(.selectionChanged(eipDocument.id, eipDocument.selection))
        eventBus.send(.cursorMoved(eipDocument.id, eipDocument.cursor))
    }

    private func editsEvent(for document: Document) -> EditorEvent {
        let edits = pendingContentChanges
        pendingContentChanges = []
        if edits.isEmpty {
            return .documentChanged(document.id, document.contentSnapshot)
        }
        return .documentEdited(document.id, edits, newSnapshot: document.contentSnapshot)
    }

    deinit {
        contentRefreshTask?.cancel()
    }
}

extension RunestoneWorkbenchEditorAdapter: TextViewDelegate {
    public func textViewDidChange(_ textView: TextView) {
        if let selected = workbench.activePane.selectedDocument {
            selected.isDirty = true
            scheduleContentRefresh(from: textView, for: selected)
        }
        forwardingDelegate?.textViewDidChange(textView)
    }

    public func textView(_ textView: TextView, didChangeContent change: TextContentChange) {
        pendingContentChanges.append(change.asTextEdit)
        forwardingDelegate?.textView(textView, didChangeContent: change)
    }

    public func textViewDidChangeSelection(_ textView: TextView) {
        refreshLiveDocumentFromTextView(textView)
        forwardingDelegate?.textViewDidChangeSelection(textView)
    }

    public func textViewShouldBeginEditing(_ textView: TextView) -> Bool {
        forwardingDelegate?.textViewShouldBeginEditing(textView) ?? true
    }

    public func textViewShouldEndEditing(_ textView: TextView) -> Bool {
        forwardingDelegate?.textViewShouldEndEditing(textView) ?? true
    }

    public func textViewDidBeginEditing(_ textView: TextView) {
        forwardingDelegate?.textViewDidBeginEditing(textView)
    }

    public func textViewDidEndEditing(_ textView: TextView) {
        forwardingDelegate?.textViewDidEndEditing(textView)
    }

    public func textView(_ textView: TextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        forwardingDelegate?.textView(textView, shouldChangeTextIn: range, replacementText: text) ?? true
    }

    public func textView(_ textView: TextView,
                         didChangeDistractionFreeChromeVisibility isVisible: Bool,
                         transitionDuration: TimeInterval) {
        forwardingDelegate?.textView(
            textView,
            didChangeDistractionFreeChromeVisibility: isVisible,
            transitionDuration: transitionDuration
        )
    }

    public func textViewDidFinishSyntaxParse(_ textView: TextView) {
        forwardingDelegate?.textViewDidFinishSyntaxParse(textView)
    }
}
