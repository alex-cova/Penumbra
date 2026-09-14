import Foundation
import EditorIntelligence

/// Bridges a Runestone `TextView` to the Editor Intelligence Platform.
///
/// The adapter is non-isolated on the surface: it caches a `Document` snapshot so that EIP
/// services can read `currentDocument` and `openDocuments` without entering `MainActor`. Edits
/// and focus changes are async and run on the main actor because they touch UI. The adapter
/// becomes the `TextView`'s `editorDelegate` and emits `EditorEvent`s for text and selection changes.
public final class RunestoneEditorAdapter: EditorAdapter, @unchecked Sendable {
    public let id: EditorAdapterID
    public let context: EditorContext
    public var events: AsyncStream<EditorEvent> { eventBus.events }

    private(set) weak var textView: TextView?
    /// Optional delegate that receives text-view callbacks after the adapter updates its document snapshot.
    public weak var forwardingDelegate: TextViewDelegate?
    private let eventBus = EventBus<EditorEvent>()
    private let documentID: DocumentID
    private let lock = NSLock()
    private var latestDocument: Document?
    private var refreshTask: Task<Void, Never>?
    private var pendingContentChanges: [TextEdit] = []
    /// Matches ``LSPDocumentSyncService``'s default `batchInterval` — downstream consumers of
    /// this adapter's `.documentChanged` events (`Workspace`, `LSPWorkspaceSyncBridge`,
    /// `IndexingService`, ...) all get throttled for free once the source event rate drops.
    private static let refreshDebounceNanoseconds: UInt64 = 200_000_000

    /// Create an adapter for a Runestone text view.
    /// - Parameters:
    ///   - textView: The text view to bridge.
    ///   - context: Editor context; defaults to a new context.
    @MainActor
    public init(textView: TextView, context: EditorContext = EditorContext()) {
        self.textView = textView
        self.context = context
        self.id = context.adapterID
        self.documentID = DocumentID()
        textView.editorDelegate = self
        captureInitialDocument()
    }

    public var currentDocument: Document? {
        lock.withLock { latestDocument }
    }

    public var openDocuments: [Document] {
        lock.withLock { latestDocument.map { [$0] } ?? [] }
    }

    public func document(withID id: DocumentID) -> Document? {
        lock.withLock { id == documentID ? latestDocument : nil }
    }

    public func applyEdit(_ edit: TextEdit, toDocumentWithID documentID: DocumentID) async throws {
        guard documentID == self.documentID else {
            throw RunestoneEditorAdapterError.unknownDocumentID(documentID)
        }
        guard let textView = textView else {
            throw RunestoneEditorAdapterError.textViewDeallocated
        }
        await MainActor.run {
            let range = TextEditApplicator.nsRange(for: edit.range, in: textView)
            textView.replace(range, withText: edit.replacement)
        }
    }

    public func focusRange(_ range: EditorIntelligence.TextRange, inDocumentWithID documentID: DocumentID) async throws {
        guard documentID == self.documentID else {
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

    // MARK: - Snapshotting

    private func captureInitialDocument() {
        Task { @MainActor in
            guard let textView = textView else { return }
            let document = makeDocument(with: textView)
            setLatestDocument(document)
            eventBus.send(.documentOpened(document))
        }
    }

    /// Debounced: re-bridging the whole document (`makeDocument(with:)`) is O(document size), and
    /// this is called on every keystroke via `textViewDidChange`. Coalescing bursts of edits into
    /// one refresh per quiet period — rather than one per keystroke — is what makes typing on a
    /// large document not pay that cost per character. See PERFORMANCE_AUDIT.md Phase 2 #1.
    private func refreshDocument() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.refreshDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            guard let textView = textView else { return }
            let document = makeDocument(with: textView)
            setLatestDocument(document)
            let edits = pendingContentChanges
            pendingContentChanges = []
            RunestoneSignposts.interval("RunestoneEditorAdapter.refreshDocument") {
                if edits.isEmpty {
                    eventBus.send(.documentChanged(document.id, document.contentSnapshot))
                } else {
                    eventBus.send(.documentEdited(document.id, edits, newSnapshot: document.contentSnapshot))
                }
            }
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    /// Builds a fresh document, re-bridging the text view's content into a new `TextSnapshot`.
    ///
    /// - Important: This copies the entire document (`NSMutableString` -> `String` bridging is
    ///   eager and unavoidable for a mutable backing store). Only call this when content has
    ///   actually changed; for selection/cursor-only updates use
    ///   ``makeDocument(with:snapshot:)`` to reuse the previous snapshot instead.
    @MainActor
    private func makeDocument(with textView: TextView) -> Document {
        let snapshot: TextSnapshot
        if textView.isFileBacked {
            snapshot = TextSnapshot(
                version: nextVersion(),
                utf16Length: textView.documentLength,
                text: nil,
                rangeReader: makeRangeReader(from: textView)
            )
        } else if let reader = makeRangeReader(from: textView) {
            snapshot = TextSnapshot(
                version: nextVersion(),
                utf16Length: textView.documentLength,
                text: nil,
                rangeReader: reader
            )
        } else {
            snapshot = TextSnapshot(version: nextVersion(), text: textView.text)
        }
        return makeDocument(with: textView, snapshot: snapshot)
    }

    /// Builds a document reusing an existing content snapshot, only recomputing
    /// selection/cursor/viewport. Used for selection-only changes so they don't pay the cost of
    /// re-bridging the full document text.
    @MainActor
    private func makeDocument(with textView: TextView, snapshot: TextSnapshot) -> Document {
        let selection = makeSelection(from: textView.selectedRanges, in: textView)
        let cursor = Cursor(position: selection.range.start)
        let viewport = Viewport(
            x: Double(textView.contentOffset.x),
            y: Double(textView.contentOffset.y),
            width: Double(textView.frame.width),
            height: Double(textView.frame.height)
        )
        return Document(
            id: documentID,
            url: context.rootProjectURL,
            displayName: context.rootProjectURL?.lastPathComponent ?? "Untitled",
            contentSnapshot: snapshot,
            selection: selection,
            cursor: cursor,
            viewport: viewport,
            languageIdentifier: textView.languageIdentifier
        )
    }

    @MainActor
    private func makeSelection(from ranges: [NSRange], in textView: TextView) -> Selection {
        guard let primary = ranges.first else {
            let position = makePosition(at: 0, in: textView)
            let range = EditorIntelligence.TextRange(start: position, end: position)
            return Selection(range: range)
        }
        let primaryRange = makeTextRange(from: primary, in: textView)
        let additionalRanges = ranges.dropFirst().map { makeTextRange(from: $0, in: textView) }
        return Selection(range: primaryRange, additionalRanges: additionalRanges)
    }

    @MainActor
    private func makeTextRange(from range: NSRange, in textView: TextView) -> EditorIntelligence.TextRange {
        let start = makePosition(at: range.location, in: textView)
        let end = makePosition(at: range.location + range.length, in: textView)
        return EditorIntelligence.TextRange(start: start, end: end)
    }

    @MainActor
    private func makeSelection(from range: NSRange, in textView: TextView) -> Selection {
        makeSelection(from: [range], in: textView)
    }

    @MainActor
    private func makePosition(at offset: Int, in textView: TextView) -> TextPosition {
        let textLocation = textView.textLocation(at: offset)
        return TextPosition(
            line: textLocation?.lineNumber ?? 0,
            column: textLocation?.column ?? offset,
            utf16Offset: offset
        )
    }

    private func nextVersion() -> Int {
        lock.withLock {
            let version = (latestDocument?.version ?? -1) + 1
            return version
        }
    }

    @MainActor
    private func makeRangeReader(from textView: TextView) -> TextRangeReader? {
        guard let snapshot = textView.pieceTreeContentSnapshot() else {
            return nil
        }
        return TextRangeReader(utf16Length: snapshot.utf16Length) { offset, length in
            snapshot.substring(utf16Offset: offset, length: length)
        }
    }

    private func setLatestDocument(_ document: Document) {
        lock.withLock { latestDocument = document }
    }
}

// MARK: - TextViewDelegate
extension RunestoneEditorAdapter: TextViewDelegate {
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

    public func textViewDidChange(_ textView: TextView) {
        refreshDocument()
        forwardingDelegate?.textViewDidChange(textView)
    }

    public func textView(_ textView: TextView, didChangeContent change: TextContentChange) {
        pendingContentChanges.append(change.asTextEdit)
        forwardingDelegate?.textView(textView, didChangeContent: change)
    }

    public func textViewDidChangeSelection(_ textView: TextView) {
        Task { @MainActor in
            guard textView === self.textView else { return }
            // Selection/cursor movement doesn't change document content, so reuse the existing
            // content snapshot instead of re-bridging the entire NSMutableString into a new
            // String. This is what makes arrow-key navigation and mouse clicks on large
            // documents cheap: previously every selection change paid the same full-document
            // copy as an actual edit.
            let snapshot = currentDocument?.contentSnapshot
                ?? TextSnapshot(
                    version: nextVersion(),
                    utf16Length: textView.documentLength,
                    text: textView.isFileBacked ? nil : textView.text,
                    rangeReader: textView.isFileBacked ? makeRangeReader(from: textView) : nil
                )
            let document = makeDocument(with: textView, snapshot: snapshot)
            setLatestDocument(document)
            eventBus.send(.selectionChanged(document.id, document.selection))
            eventBus.send(.cursorMoved(document.id, document.cursor))
            forwardingDelegate?.textViewDidChangeSelection(textView)
        }
    }

    public func textView(_ textView: TextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        forwardingDelegate?.textView(textView, shouldChangeTextIn: range, replacementText: text) ?? true
    }

    public func textView(_ textView: TextView, shouldInsert characterPair: CharacterPair, in range: NSRange) -> Bool {
        forwardingDelegate?.textView(textView, shouldInsert: characterPair, in: range) ?? true
    }

    public func textView(_ textView: TextView, shouldSkipTrailingComponentOf characterPair: CharacterPair, in range: NSRange) -> Bool {
        forwardingDelegate?.textView(textView, shouldSkipTrailingComponentOf: characterPair, in: range) ?? true
    }

    public func textViewDidChangeGutterWidth(_ textView: TextView) {
        forwardingDelegate?.textViewDidChangeGutterWidth(textView)
    }

    public func textViewDidBeginFloatingCursor(_ textView: TextView) {
        forwardingDelegate?.textViewDidBeginFloatingCursor(textView)
    }

    public func textViewDidEndFloatingCursor(_ textView: TextView) {
        forwardingDelegate?.textViewDidEndFloatingCursor(textView)
    }

    public func textViewDidLoopToLastHighlightedRange(_ textView: TextView) {
        forwardingDelegate?.textViewDidLoopToLastHighlightedRange(textView)
    }

    public func textViewDidLoopToFirstHighlightedRange(_ textView: TextView) {
        forwardingDelegate?.textViewDidLoopToFirstHighlightedRange(textView)
    }

    public func textView(_ textView: TextView, canReplaceTextIn highlightedRange: HighlightedRange) -> Bool {
        forwardingDelegate?.textView(textView, canReplaceTextIn: highlightedRange) ?? false
    }

    public func textView(_ textView: TextView, replaceTextIn highlightedRange: HighlightedRange) {
        forwardingDelegate?.textView(textView, replaceTextIn: highlightedRange)
    }

    public func textViewDidFinishSyntaxParse(_ textView: TextView) {
        forwardingDelegate?.textViewDidFinishSyntaxParse(textView)
    }
}

extension TextContentChange {
    var asTextEdit: TextEdit {
        let startPosition = TextPosition(
            line: start.lineNumber,
            column: start.column,
            utf16Offset: range.location
        )
        let endPosition = TextPosition(
            line: oldEnd.lineNumber,
            column: oldEnd.column,
            utf16Offset: range.location + range.length
        )
        return TextEdit(
            range: TextRange(start: startPosition, end: endPosition),
            replacement: replacementText
        )
    }
}

public enum RunestoneEditorAdapterError: Error {
    case unknownDocumentID(DocumentID)
    case textViewDeallocated
}
