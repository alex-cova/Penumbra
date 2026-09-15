import Foundation
import TreeSitter

protocol TreeSitterLanguageModeDelegate: AnyObject {
    nonisolated func treeSitterLanguageMode(_ languageMode: TreeSitterInternalLanguageMode, bytesAt byteIndex: ByteCount) -> TreeSitterTextProviderResult?
}

final class TreeSitterInternalLanguageMode: InternalLanguageMode, @unchecked Sendable {
    weak var delegate: TreeSitterLanguageModeDelegate?
    /// Mirrors the readiness check `captures(in:)` itself makes: a tree existing is not enough —
    /// while a parse is in flight or the initial parse has not completed, `captures(in:)` returns
    /// `[]`. Without this, `LineController` would mark a line "highlighted" after a query that
    /// silently produced zero tokens, leaving it stuck at `theme.textColor` (the Metal white flash).
    var canHighlight: Bool {
        parseLock.withLock { rootLanguageLayer.canHighlight && !parseInFlight && hasCompletedInitialParse }
    }

    private let stringView: StringView
    private let parser: TreeSitterParser
    private let lineManager: LineManager
    private let rootLanguageLayer: TreeSitterLanguageLayer
    private let operationQueue = OperationQueue()
    private let highlightQueue = OperationQueue()
    private let parseLock = NSLock()
    private var hasCompletedInitialParse = false
    /// Highlight captures for recently-queried byte windows, reused by adjacent lines until the
    /// tree changes. `LayoutManager` schedules one highlight per visible line onto `highlightQueue`
    /// (up to `TreeSitterPerformanceConstants.highlightQueueConcurrency` running at once), so a
    /// *single* cached window was measured to thrash under scrolling: each concurrently-running line
    /// recomputes its own ~32k window and immediately evicts the window a sibling line on another
    /// thread just cached, even though the two windows usually overlap. Keeping the last few windows
    /// (most-recently-used order) gives each concurrent lane a slot that survives its siblings' queries.
    private var captureWindows: [CaptureWindow] = []
    /// True while a background parse is running *outside* `parseLock`. Edits bump `parseEpoch`
    /// instead of waiting for that work to finish.
    private var parseInFlight = false
    /// Invalidates an in-flight parse so it cannot publish a tree built against a stale buffer.
    private var parseEpoch: UInt = 0
    /// UTF-16 window currently fed to `ts_parser_set_included_ranges`. `nil` means a full-document tree.
    private(set) var parsedUTF16Range: NSRange?

    init(language: TreeSitterInternalLanguage, languageProvider: TreeSitterLanguageProvider?, stringView: StringView, lineManager: LineManager) {
        self.stringView = stringView
        self.lineManager = lineManager
        operationQueue.name = "TreeSitterLanguageMode"
        operationQueue.qualityOfService = .default
        operationQueue.maxConcurrentOperationCount = 1
        highlightQueue.name = "TreeSitterSyntaxHighlight"
        highlightQueue.qualityOfService = .userInitiated
        highlightQueue.maxConcurrentOperationCount = TreeSitterPerformanceConstants.highlightQueueConcurrency
        parser = TreeSitterParser(encoding: .treeSitterUTF16)
        rootLanguageLayer = TreeSitterLanguageLayer(
            language: language,
            languageProvider: languageProvider,
            parser: parser,
            stringView: stringView,
            lineManager: lineManager)
        parser.delegate = self
    }

    var isSyntaxTreeReady: Bool {
        parseLock.withLock { hasCompletedInitialParse }
    }

    deinit {
        operationQueue.cancelAllOperations()
        highlightQueue.cancelAllOperations()
    }

    func cancelParse() {
        operationQueue.cancelAllOperations()
    }

    func invalidateSyntaxTree() {
        cancelParse()
        parseLock.withLock {
            parseEpoch += 1
            hasCompletedInitialParse = false
            parsedUTF16Range = nil
            captureWindows.removeAll()
            if !parseInFlight {
                rootLanguageLayer.invalidateTree()
            }
        }
    }

    func parse(_ text: NSString) {
        parseFromBuffer()
    }

    func parseFromBuffer() {
        parseLock.withLock {
            captureWindows.removeAll()
            rootLanguageLayer.parseUsingReader()
            let ready = rootLanguageLayer.tree != nil && !parser.lastParseAborted
            hasCompletedInitialParse = ready
            parsedUTF16Range = ready ? NSRange(location: 0, length: stringView.length) : nil
        }
    }

    func parse(_ text: NSString, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        operationQueue.cancelAllOperations()
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation, weak self] in
            guard let self = self, let operation = operation, !operation.isCancelled else {
                DispatchQueue.main.async {
                    completion(false)
                }
                return
            }
            self.parseUsingReader(
                coveringUTF16Range: NSRange(location: 0, length: self.stringView.length),
                isCancelled: { operation.isCancelled }
            )
            DispatchQueue.main.async {
                completion(!operation.isCancelled && self.isSyntaxTreeReady)
            }
        }
        operationQueue.addOperation(operation)
    }

    func parse(coveringUTF16Range range: NSRange, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        operationQueue.cancelAllOperations()
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation, weak self] in
            guard let self = self, let operation = operation, !operation.isCancelled else {
                DispatchQueue.main.async {
                    completion(false)
                }
                return
            }
            self.parseUsingReader(coveringUTF16Range: range, isCancelled: { operation.isCancelled })
            DispatchQueue.main.async {
                completion(!operation.isCancelled && self.isSyntaxTreeReady)
            }
        }
        operationQueue.addOperation(operation)
    }

    func parsedRangeContains(_ utf16Range: NSRange) -> Bool {
        parseLock.withLock {
            guard let parsedUTF16Range else {
                return false
            }
            return parsedUTF16Range.containsUTF16Range(utf16Range)
        }
    }

    private func parse(_ text: NSString, isCancelled: (() -> Bool)?) {
        guard isCancelled != nil else {
            parseLock.withLock {
                captureWindows.removeAll()
                rootLanguageLayer.parse(text)
                hasCompletedInitialParse = true
                parsedUTF16Range = NSRange(location: 0, length: text.length)
            }
            return
        }
        runBackgroundParse(isCancelled: isCancelled) {
            self.rootLanguageLayer.parse(text)
        } publish: {
            NSRange(location: 0, length: text.length)
        }
    }

    private func parseUsingReader(coveringUTF16Range range: NSRange, isCancelled: (() -> Bool)?) {
        runBackgroundParse(isCancelled: isCancelled) {
            self.rootLanguageLayer.setRootIncludedUTF16Range(range, stringLength: self.stringView.length)
            self.rootLanguageLayer.parseUsingReader()
        } publish: {
            range
        }
    }

    /// Runs tree-sitter off `parseLock` so a keystroke can invalidate the work (via `parseEpoch`)
    /// instead of waiting for it. The tree is only published if the epoch still matches.
    private func runBackgroundParse(
        isCancelled: (() -> Bool)?,
        work: () -> Void,
        publish: () -> NSRange
    ) {
        parseLock.lock()
        let epoch = parseEpoch
        parser.shouldCancel = isCancelled
        parseInFlight = true
        parseLock.unlock()

        work()

        parseLock.lock()
        parseInFlight = false
        parser.shouldCancel = nil
        if isCancelled?() == true || epoch != parseEpoch || parser.lastParseAborted {
            parser.reset()
            rootLanguageLayer.invalidateTree()
            hasCompletedInitialParse = false
            parsedUTF16Range = nil
            captureWindows.removeAll()
        } else {
            hasCompletedInitialParse = rootLanguageLayer.tree != nil
            parsedUTF16Range = publish()
            captureWindows.removeAll()
        }
        parseLock.unlock()
    }

    func textDidChange(_ change: TextChange) -> LineChangeSet {
        cancelParse()
        let bytesRemoved = change.byteRange.length
        let bytesAdded = change.bytesAdded
        let edit = TreeSitterInputEdit(
            startByte: change.byteRange.location,
            oldEndByte: change.byteRange.location + bytesRemoved,
            newEndByte: change.byteRange.location + bytesAdded,
            startPoint: TreeSitterTextPoint(change.startLinePosition),
            oldEndPoint: TreeSitterTextPoint(change.oldEndLinePosition),
            newEndPoint: TreeSitterTextPoint(change.newEndLinePosition))
        // Highlight queries copy the tree under this lock and run off it, so a keystroke is not
        // blocked by an in-flight capture. Tree mutation still takes the lock.
        return parseLock.withLock {
            if parseInFlight || rootLanguageLayer.tree == nil {
                // Do not wait for the in-flight parse: bump the epoch so its result is discarded
                // and let the caller reschedule against the edited buffer.
                parseEpoch += 1
                hasCompletedInitialParse = false
                captureWindows.removeAll()
                if rootLanguageLayer.tree == nil {
                    parsedUTF16Range = nil
                }
                return LineChangeSet()
            }
            if var range = parsedUTF16Range {
                range = ViewportParseWindow.shift(
                    range,
                    utf16Location: change.byteRange.location.utf16Length,
                    oldLength: change.byteRange.length.utf16Length,
                    newLength: change.bytesAdded.utf16Length
                )
                let stringLength = stringView.length
                range = NSIntersectionRange(range, NSRange(location: 0, length: stringLength))
                parsedUTF16Range = range
                rootLanguageLayer.setRootIncludedUTF16Range(range, stringLength: stringLength)
            }
            captureWindows.removeAll()
            let editUTF16Length = max(change.byteRange.length.utf16Length, change.bytesAdded.utf16Length)
            if editUTF16Length > TreeSitterPerformanceConstants.maxSyncEditLength {
                parseEpoch += 1
                hasCompletedInitialParse = false
                rootLanguageLayer.applyEditWithoutParsing(edit)
                return LineChangeSet()
            }
            let changeSet = rootLanguageLayer.apply(edit)
            if parser.lastParseAborted {
                parseEpoch += 1
                hasCompletedInitialParse = false
            }
            return changeSet
        }
    }

    func captures(in range: ByteRange) -> [TreeSitterCapture] {
        parseLock.lock()
        if parseInFlight || !hasCompletedInitialParse {
            parseLock.unlock()
            return []
        }
        if let cached = cachedCaptures(containing: range) {
            parseLock.unlock()
            return cached
        }
        // Expanding to a 32k window on the main thread makes every keystroke
        // (`redisplayLines` highlights synchronously) pay for a viewport-sized query.
        // Off the main thread (async line highlighting) we fill the window so the
        // rest of the viewport is a cache hit.
        let queryRange = Thread.isMainThread ? range : expandedCaptureRange(covering: range)
        let snapshot = rootLanguageLayer.snapshotForQuery()
        let epoch = parseEpoch
        parseLock.unlock()

        guard let snapshot else {
            return []
        }
        let captures = RunestoneSignposts.interval("TreeSitterInternalLanguageMode.captures") {
            snapshot.captures(in: queryRange, stringView: stringView)
        }
        parseLock.lock()
        if epoch == parseEpoch {
            storeCaptureWindow(CaptureWindow(range: queryRange, captures: captures))
        }
        parseLock.unlock()
        if queryRange == range {
            return captures
        }
        return captures.filter { $0.byteRange.overlaps(range) }
    }

    /// Must be called while holding `parseLock`. Moves a hit to the most-recently-used end so a
    /// window a concurrent lane keeps reusing survives longer than one used only once.
    private func cachedCaptures(containing range: ByteRange) -> [TreeSitterCapture]? {
        guard let index = captureWindows.firstIndex(where: { $0.range.contains(range) }) else {
            return nil
        }
        let window = captureWindows[index]
        if index != captureWindows.count - 1 {
            captureWindows.remove(at: index)
            captureWindows.append(window)
        }
        return window.captures.filter { $0.byteRange.overlaps(range) }
    }

    /// Must be called while holding `parseLock`.
    private func storeCaptureWindow(_ window: CaptureWindow) {
        captureWindows.append(window)
        let overflow = captureWindows.count - TreeSitterPerformanceConstants.captureWindowCacheSize
        if overflow > 0 {
            captureWindows.removeFirst(overflow)
        }
    }

    func createLineSyntaxHighlighter() -> LineSyntaxHighlighter {
        TreeSitterSyntaxHighlighter(stringView: stringView, languageMode: self, operationQueue: highlightQueue)
    }

    func currentIndentLevel(of line: DocumentLineNode, using indentStrategy: IndentStrategy) -> Int {
        let measurer = IndentLevelMeasurer(stringView: stringView)
        return measurer.indentLevel(lineStartLocation: line.location, lineTotalLength: line.data.totalLength, tabLength: indentStrategy.tabLength)
    }

    func strategyForInsertingLineBreak(from startLinePosition: LinePosition,
                                       to endLinePosition: LinePosition,
                                       using indentStrategy: IndentStrategy) -> InsertLineBreakIndentStrategy {
        let startLayerAndNode = rootLanguageLayer.layerAndNode(at: startLinePosition)
        let endLayerAndNode = rootLanguageLayer.layerAndNode(at: endLinePosition)
        if let indentationScopes = startLayerAndNode?.layer.language.indentationScopes ?? endLayerAndNode?.layer.language.indentationScopes {
            let indentController = TreeSitterIndentController(
                indentationScopes: indentationScopes,
                stringView: stringView,
                lineManager: lineManager,
                tabLength: indentStrategy.tabLength)
            let startNode = startLayerAndNode?.node
            let endNode = endLayerAndNode?.node
            return indentController.strategyForInsertingLineBreak(
                between: startNode,
                and: endNode,
                caretStartPosition: startLinePosition,
                caretEndPosition: endLinePosition)
        } else {
            return InsertLineBreakIndentStrategy(indentLevel: 0, insertExtraLineBreak: false)
        }
    }

    func syntaxNode(at linePosition: LinePosition) -> SyntaxNode? {
        let parsed = parseLock.withLock { parseInFlight ? nil : parsedUTF16Range }
        if let parsed, parsed.length < stringView.length {
            let line = lineManager.line(atRow: linePosition.row)
            let location = Int(line.location) + linePosition.column
            if !NSLocationInRange(location, parsed) {
                return nil
            }
        }
        if let node = rootLanguageLayer.layerAndNode(at: linePosition)?.node, let type = node.type {
            let startLocation = TextLocation(LinePosition(node.startPoint))
            let endLocation = TextLocation(LinePosition(node.endPoint))
            return SyntaxNode(type: type, startLocation: startLocation, endLocation: endLocation)
        } else {
            return nil
        }
    }

    func detectIndentStrategy() -> DetectedIndentStrategy {
        if let tree = rootLanguageLayer.tree {
            let detector = TreeSitterIndentStrategyDetector(lineManager: lineManager, tree: tree, stringView: stringView)
            return detector.detect()
        } else {
            return .unknown
        }
    }

    var rootSyntaxNode: TreeSitterNode? {
        rootLanguageLayer.tree?.rootNode
    }

    /// The smallest (injection-aware) tree-sitter node at `linePosition`, for callers that need
    /// the live tree structure — parent chain, sibling rows — rather than the flattened
    /// ``SyntaxNode``. Returns `nil` while a parse is in flight or the position is outside a
    /// viewport parse window.
    ///
    /// - Important: The returned node points into a tree that is freed on the next reparse.
    ///   Read what you need from it immediately; never hold it across a text edit.
    func treeSitterNode(at linePosition: LinePosition) -> TreeSitterNode? {
        let parsed = parseLock.withLock { parseInFlight ? nil : parsedUTF16Range }
        if let parsed, parsed.length < stringView.length {
            let line = lineManager.line(atRow: linePosition.row)
            let location = Int(line.location) + linePosition.column
            if !NSLocationInRange(location, parsed) {
                return nil
            }
        }
        return rootLanguageLayer.layerAndNode(at: linePosition)?.node
    }

    private func expandedCaptureRange(covering range: ByteRange) -> ByteRange {
        let documentRange = ByteRange(from: 0, to: stringView.byteCount)
        guard documentRange.length > 0 else {
            return range
        }
        let window = ByteCount(utf16Length: TreeSitterPerformanceConstants.highlightQueryWindowUTF16Length)
        if documentRange.length <= window {
            return documentRange
        }
        if range.length >= window {
            let end = min(documentRange.upperBound, range.upperBound)
            let start = min(range.location, end)
            return ByteRange(from: max(documentRange.lowerBound, start), to: end)
        }
        let pad = ByteCount(max(0, window.value - range.length.value) / 2)
        return range.padded(by: pad, within: documentRange)
    }
}

private struct CaptureWindow {
    let range: ByteRange
    let captures: [TreeSitterCapture]
}

extension TreeSitterInternalLanguageMode: TreeSitterParserDelegate {
    func parser(_ parser: TreeSitterParser, bytesAt byteIndex: ByteCount) -> TreeSitterTextProviderResult? {
        if let result = delegate?.treeSitterLanguageMode(self, bytesAt: byteIndex) {
            return result
        }
        return readBytes(at: byteIndex)
    }

    func readBytes(at byteIndex: ByteCount) -> TreeSitterTextProviderResult? {
        guard byteIndex.value >= 0 && byteIndex < stringView.byteCount else {
            return nil
        }
        let targetByteCount: ByteCount = 4 * 1_024
        let endByte = min(byteIndex + targetByteCount, stringView.byteCount)
        let byteRange = ByteRange(from: byteIndex, to: endByte)
        if let result = stringView.bytes(in: byteRange) {
            return TreeSitterTextProviderResult(bytes: result.bytes, length: UInt32(result.length.value))
        }
        return nil
    }
}
