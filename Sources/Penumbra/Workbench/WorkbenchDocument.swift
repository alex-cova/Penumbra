import CoreGraphics
import EditorIntelligence
import Foundation

/// In-memory document tracked by an ``EditorPane``.
public final class WorkbenchDocument: Identifiable, @unchecked Sendable {
    public let id: UUID
    public let documentID: DocumentID
    public var url: URL?
    public var displayName: String
    /// Document text for untitled / contiguous buffers.
    ///
    /// Empty when ``isFileBacked``. Do not write this to disk; use ``save(from:to:)``.
    public var text: String
    public var language: TreeSitterLanguage?
    public var languageIdentifier: String?
    public var isDirty: Bool
    public var selectedRange: NSRange
    public var scrollOffset: CGPoint
    /// One-shot `TextViewState` from ``load(contentsOf:language:languageIdentifier:parsePolicy:io:)``.
    /// Consumed on first apply so the workbench does not rebuild the line index from `text`.
    public var pendingState: TextViewState?
    /// True when the document was loaded as a file-backed piece tree (no `text` copy).
    public var isFileBacked: Bool
    /// Ranged reader for file-backed buffers so EIP snapshots can substring without full text.
    public var rangeReader: TextRangeReader?

    public init(
        id: UUID = UUID(),
        documentID: DocumentID = DocumentID(),
        url: URL? = nil,
        displayName: String = "Untitled",
        text: String = "",
        language: TreeSitterLanguage? = nil,
        languageIdentifier: String? = nil,
        isDirty: Bool = false,
        selectedRange: NSRange = NSRange(location: 0, length: 0),
        scrollOffset: CGPoint = .zero
    ) {
        self.id = id
        self.documentID = documentID
        self.url = url
        self.displayName = displayName
        self.text = text
        self.language = language
        self.languageIdentifier = languageIdentifier
        self.isDirty = isDirty
        self.selectedRange = selectedRange
        self.scrollOffset = scrollOffset
        self.isFileBacked = false
        self.rangeReader = nil
    }

    /// Loads a document from disk via mmap ingest (falling back to streamed reads).
    ///
    /// The returned document carries ``pendingState`` so the first ``TextView/setState`` can reuse
    /// the line index built during load instead of scanning `text` again.
    public static func load(
        contentsOf url: URL,
        theme: Theme = DefaultTheme(),
        language: TreeSitterLanguage? = nil,
        languageIdentifier: String? = nil,
        languageProvider: TreeSitterLanguageProvider? = nil,
        parsePolicy: SyntaxParsePolicy = .viewport,
        io: DocumentLoadIO = .memoryMapped
    ) async throws -> WorkbenchDocument {
        let prepared = try await PenumbraStateBuilder.load(
            contentsOf: url,
            theme: theme,
            language: language,
            languageProvider: languageProvider,
            parsePolicy: parsePolicy,
            io: io
        )
        let document = WorkbenchDocument(
            url: url,
            displayName: url.lastPathComponent,
            text: "",
            language: language,
            languageIdentifier: languageIdentifier
        )
        document.pendingState = prepared.state
        document.isFileBacked = prepared.state.stringView.isFileBacked
        if document.isFileBacked, let snapshot = prepared.state.stringView.contentSnapshot() {
            document.rangeReader = TextRangeReader(utf16Length: snapshot.utf16Length) { offset, length in
                snapshot.substring(utf16Offset: offset, length: length)
            }
        }
        return document
    }

    public func makeEIPDocument(version: Int = 0) -> Document {
        let snapshot: TextSnapshot
        if isFileBacked || rangeReader != nil {
            let length = rangeReader?.utf16Length ?? pendingState?.stringView.length ?? (text as NSString).length
            snapshot = TextSnapshot(version: version, utf16Length: length, text: nil, rangeReader: rangeReader)
        } else {
            snapshot = TextSnapshot(version: version, text: text)
        }
        let start = TextPosition(
            line: 0,
            column: selectedRange.location,
            utf16Offset: selectedRange.location
        )
        let end = TextPosition(
            line: 0,
            column: selectedRange.location + selectedRange.length,
            utf16Offset: selectedRange.location + selectedRange.length
        )
        let selection = Selection(range: EditorIntelligence.TextRange(start: start, end: end))
        return Document(
            id: documentID,
            url: url,
            displayName: displayName,
            contentSnapshot: snapshot,
            selection: selection,
            cursor: Cursor(position: start),
            viewport: Viewport(x: Double(scrollOffset.x), y: Double(scrollOffset.y), width: 0, height: 0),
            languageIdentifier: languageIdentifier
        )
    }

    /// Save-in-place (`to: nil` uses ``url``) or save-as.
    /// File-backed documents must pass the live ``TextView`` (or still-unconsumed ``pendingState``).
    /// Never writes ``text`` when ``isFileBacked`` is true.
    ///
    /// Does **not** compact. When `textView` is provided, compact happens inside ``TextView/write(to:options:progress:)``.
    @MainActor
    public func save(
        from textView: TextView? = nil,
        to url: URL? = nil,
        options: DocumentWriteOptions = .init(),
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> DocumentWriteResult {
        guard let dest = url ?? self.url else {
            throw DocumentWriteError.noDestination
        }
        let result: DocumentWriteResult
        if let textView {
            let identity = textView.stringViewObjectIdentifier
            result = try await textView.write(to: dest, options: options, progress: progress)
            if textView.stringViewObjectIdentifier == identity {
                isDirty = !result.generationMatched
                refreshRangeReader(from: textView.pieceTreeContentSnapshot() ?? pendingState?.stringView.contentSnapshot())
            } else {
                isDirty = true
            }
        } else if let pendingState {
            result = try await writePendingOrContiguous(
                pendingState.stringView,
                to: dest,
                options: options,
                progress: progress
            )
            isDirty = false
            refreshRangeReader(from: pendingState.stringView.contentSnapshot())
        } else if !isFileBacked {
            result = try await writeContiguousText(to: dest, options: options, progress: progress)
            isDirty = false
            rangeReader = nil
        } else {
            throw DocumentWriteError.bufferUnavailable
        }
        self.url = dest
        displayName = dest.lastPathComponent
        return result
    }

    private func refreshRangeReader(from snapshot: PieceTreeContentSnapshot?) {
        if let snapshot {
            rangeReader = TextRangeReader(utf16Length: snapshot.utf16Length) { offset, length in
                snapshot.substring(utf16Offset: offset, length: length)
            }
        } else {
            rangeReader = nil
        }
    }

    private func writePendingOrContiguous(
        _ stringView: StringView,
        to dest: URL,
        options: DocumentWriteOptions,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> DocumentWriteResult {
        let source: DocumentWriteSource
        if let snapshot = stringView.contentSnapshot() {
            source = .pieceTree(snapshot)
        } else {
            source = .contiguous(stringView.string as String)
        }
        return try await writeSource(source, to: dest, options: options, progress: progress)
    }

    private func writeContiguousText(
        to dest: URL,
        options: DocumentWriteOptions,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> DocumentWriteResult {
        try await writeSource(.contiguous(text), to: dest, options: options, progress: progress)
    }

    private func writeSource(
        _ source: DocumentWriteSource,
        to dest: URL,
        options: DocumentWriteOptions,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> DocumentWriteResult {
        let footer = try await DocumentWriter.writeCooperatively(
            source,
            to: dest,
            options: options,
            progress: progress
        )
        return DocumentWriteResult(
            wroteBytes: Int64(footer.utf8Length),
            generationMatched: true,
            compacted: false
        )
    }
}
