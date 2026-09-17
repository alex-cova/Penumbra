import Foundation

/// Controls whether ``TextViewState`` waits for a full tree-sitter parse before `init` returns.
///
/// The default ``eager`` policy preserves the historical contract: after `init`, the syntax tree
/// is complete and ``detectedIndentStrategy`` is populated. ``deferred`` builds the line index
/// only and leaves parsing to ``TextView/setState(_:addUndoAction:)``, so the first layout can
/// paint unhighlighted text while the tree is built on a background queue. ``viewport`` also
/// defers the parse, but only includes the visible window (plus overscan) so a large highlighted
/// file does not build a multi-gigabyte full-document tree.
public enum SyntaxParsePolicy: Sendable, Equatable {
    /// `init` does not return until the full syntax tree exists.
    case eager
    /// `init` builds the line index only. Parse continues after ``TextView/setState(_:addUndoAction:)``.
    case deferred
    /// Like ``deferred``, but `ts_parser_set_included_ranges` limits the tree to the viewport.
    ///
    /// Documents at or below ``TreeSitterPerformanceConstants/maxSyncContentLength`` are still
    /// parsed in full. Larger documents parse a sliding window that follows the viewport.
    case viewport
}

/// Encapsulates the bare informations needed to do syntax highlighting in a text view.
///
/// It is recommended to create an instance of `TextViewState` on a background queue and pass it to a ``TextView`` instead of setting the text, theme and language on the text view separately.
///
/// Use ``SyntaxParsePolicy/deferred`` when open latency matters more than having a complete syntax
/// tree before first paint: ``init(text:theme:language:languageProvider:parsePolicy:)`` then only
/// rebuilds the line index, and ``TextView/setState(_:addUndoAction:)`` finishes the parse off the
/// main thread. Use ``SyntaxParsePolicy/viewport`` when a full-document tree would be too large.
public final class TextViewState: @unchecked Sendable {
    let stringView: StringView
    let theme: Theme
    let lineManager: LineManager
    let languageMode: InternalLanguageMode
    /// Policy used to construct this state. ``TextView/setState(_:addUndoAction:)`` uses it to
    /// choose a full deferred parse versus a viewport-limited one.
    public let parsePolicy: SyntaxParsePolicy

    /// Indent strategy detected in the text.
    ///
    /// The information provided by the detected strategy can be used to update the ``TextView/indentStrategy`` on the text view to align with the existing strategy in a text.
    ///
    /// Under ``SyntaxParsePolicy/deferred`` and ``SyntaxParsePolicy/viewport`` this stays
    /// ``DetectedIndentStrategy/unknown`` until the background parse finishes; read it again from
    /// ``TextView/detectIndentStrategy()`` after ``TextViewDelegate/textViewDidFinishSyntaxParse(_:)``.
    public private(set) var detectedIndentStrategy: DetectedIndentStrategy = .unknown

    /// Line endings detected in the text.
    ///
    /// The information pvoided by the detected line endings can be used to update the ``TextView/lineEndings`` on the text view to align with the existing line endings in a text.
    ///
    /// The value is `nil` if the line ending cannot be detected.
    public private(set) var detectedLineEndings: LineEnding?

    /// The length of the longest line.
    public private(set) var lengthOfLongestLine: Int?

    /// Whether the language mode has finished its initial parse.
    ///
    /// Always `true` for plain text. For a Tree-sitter language this is `true` after an
    /// ``SyntaxParsePolicy/eager`` `init`, and becomes `true` for ``SyntaxParsePolicy/deferred``
    /// or ``SyntaxParsePolicy/viewport`` once ``TextView/setState(_:addUndoAction:)`` completes
    /// the background parse (the visible window only, under ``viewport``).
    public var isSyntaxTreeReady: Bool {
        languageMode.isSyntaxTreeReady
    }

    /// Creates state that can be passed to an instance of ``TextView``.
    /// - Parameters:
    ///   - text: The text to display in the text view.
    ///   - theme: The theme to use when syntax highlighting the text.
    ///   - language: The language to use when parsing the text.
    ///   - languageProvider: Object that can provide embedded languages on demand. A strong reference will be stored to the language provider.
    ///   - parsePolicy: Whether to parse before `init` returns (``SyntaxParsePolicy/eager``, the
    ///     default) or defer the parse until ``TextView/setState(_:addUndoAction:)``.
    public convenience init(
        text: String,
        theme: Theme = DefaultTheme(),
        language: TreeSitterLanguage,
        languageProvider: TreeSitterLanguageProvider? = nil,
        parsePolicy: SyntaxParsePolicy = .eager
    ) {
        self.init(
            stringView: StringView(string: text),
            theme: theme,
            language: language,
            languageProvider: languageProvider,
            parsePolicy: parsePolicy,
            lineMetrics: nil,
            packedIndex: nil
        )
    }

    /// Creates state that can be passed to an instance of ``TextView``.
    ///
    /// The created theme will use an instance of ``PlainTextLanguageMode``.
    /// - Parameters:
    ///   - text: The text to display in the text view.
    ///   - theme: The theme to use when syntax highlighting the text.
    public convenience init(text: String, theme: Theme = DefaultTheme()) {
        self.init(
            stringView: StringView(string: text),
            theme: theme,
            language: nil,
            languageProvider: nil,
            parsePolicy: .eager,
            lineMetrics: nil,
            packedIndex: nil
        )
    }

    /// Loads a document from disk in bounded chunks instead of `String(contentsOf:)`.
    ///
    /// Defaults to ``DocumentLoadIO/memoryMapped``: a private clone of the file is `mmap`'d and
    /// kept as a ``PieceTree`` original buffer. Typing appends to an add buffer; the mapping is
    /// not copied into an `NSMutableString`. ``DocumentLoadIO/streamed`` copies to a temp file
    /// then maps that. Line metrics are scanned from UTF-8 without allocating UTF-16 text.
    ///
    /// Defaults to ``SyntaxParsePolicy/viewport`` so the tree-sitter parse does not block the load
    /// and does not build a full-document tree for large files.
    ///
    /// Only UTF-8 is supported. Cancellation via `Task.cancel()` throws ``DocumentLoadError/cancelled``.
    public static func load(
        contentsOf url: URL,
        theme: Theme = DefaultTheme(),
        language: TreeSitterLanguage? = nil,
        languageProvider: TreeSitterLanguageProvider? = nil,
        parsePolicy: SyntaxParsePolicy = .viewport,
        encoding: String.Encoding = .utf8,
        io: DocumentLoadIO = .memoryMapped,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> TextViewState {
        let loaded = try await DocumentLoader.load(
            from: url,
            encoding: encoding,
            io: io,
            estimatedLineHeight: theme.font.totalLineHeight,
            progress: progress
        )
        return TextViewState(
            stringView: StringView(pieceTree: loaded.pieceTree),
            theme: theme,
            language: language,
            languageProvider: languageProvider,
            parsePolicy: parsePolicy,
            lineMetrics: nil,
            packedIndex: loaded.packedIndex
        )
    }

    /// Cancels an in-flight deferred or viewport parse.
    ///
    /// Safe to call before or after ``TextView/setState(_:addUndoAction:)``: the language mode is
    /// shared with the text view after setState, so this aborts the same background parse.
    /// ``TextViewDelegate/textViewDidFinishSyntaxParse(_:)`` is not called for a cancelled parse.
    public func cancelParse() {
        languageMode.cancelParse()
    }

    func applyDetectedIndentStrategy() {
        detectedIndentStrategy = languageMode.detectIndentStrategy()
    }

    private init(
        stringView: StringView,
        theme: Theme,
        language: TreeSitterLanguage?,
        languageProvider: TreeSitterLanguageProvider?,
        parsePolicy: SyntaxParsePolicy,
        lineMetrics: [LineMetric]?,
        packedIndex: PackedLineIndex?
    ) {
        self.theme = theme
        self.stringView = stringView
        if let packedIndex {
            packedIndex.estimatedLineHeight = theme.font.totalLineHeight
            self.lineManager = LineManager(stringView: stringView, packedIndex: packedIndex)
        } else {
            self.lineManager = LineManager(stringView: stringView)
        }
        self.parsePolicy = parsePolicy
        if let language {
            self.languageMode = TreeSitterInternalLanguageMode(
                language: language.internalLanguage,
                languageProvider: languageProvider,
                stringView: stringView,
                lineManager: lineManager
            )
        } else {
            self.languageMode = PlainTextInternalLanguageMode()
        }
        prepare(lineMetrics: lineMetrics, hasPackedIndex: packedIndex != nil)
    }
}

private extension TextViewState {
    private func prepare(lineMetrics: [LineMetric]?, hasPackedIndex: Bool) {
        PenumbraSignposts.interval("TextViewState.prepare") {
            lineManager.estimatedLineHeight = theme.font.totalLineHeight
            if hasPackedIndex {
                lengthOfLongestLine = lineManager.initialLongestLine?.data.totalLength
            } else if let lineMetrics {
                lineManager.rebuild(fromLineMetrics: lineMetrics)
                lengthOfLongestLine = lineManager.initialLongestLine?.data.totalLength
            } else {
                lineManager.rebuild()
                lengthOfLongestLine = lineManager.initialLongestLine?.data.totalLength
            }
            let lineEndingDetector = LineEndingDetector(lineManager: lineManager, stringView: stringView)
            detectedLineEndings = lineEndingDetector.detect()
            switch parsePolicy {
            case .eager:
                languageMode.parseFromBuffer()
                detectedIndentStrategy = languageMode.detectIndentStrategy()
            case .deferred, .viewport:
                break
            }
        }
    }
}
