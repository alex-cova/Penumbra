import EditorIntelligence
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
        // `parseInFlight` first: the parse assigns the layer's tree and parser language outside
        // `parseLock`, so the layer may only be read when no parse is running.
        parseLock.withLock { !parseInFlight && hasCompletedInitialParse && rootLanguageLayer.canHighlight }
    }
    /// `false` when this language (and every injected language) has no highlights query, i.e. a
    /// pending parse can never produce a highlight here. Lets `TreeSitterSyntaxHighlighter` report
    /// `canEventuallyHighlight == false` so Metal doesn't hold stale pre-edit glyphs waiting on a
    /// highlight that will never arrive.
    var highlightsQueryAvailable: Bool {
        parseLock.withLock { rootLanguageLayer.highlightsQueryAvailable }
    }
    var lineCommentPrefix: String? {
        rootLanguageLayer.language.lineCommentPrefix
    }

    var enterBehavior: EnterBehavior? {
        rootLanguageLayer.language.enterBehavior
    }

    var hasIndentationScopes: Bool {
        rootLanguageLayer.language.indentationScopes != nil
    }

    func enclosingSyntaxNodes(at linePosition: LinePosition) -> [SyntaxNode] {
        guard var node = treeSitterNode(at: linePosition) else {
            return []
        }
        var result: [SyntaxNode] = []
        while result.count < 64 {
            if let type = node.type {
                result.append(SyntaxNode(type: type,
                                         startLocation: TextLocation(LinePosition(node.startPoint)),
                                         endLocation: TextLocation(LinePosition(node.endPoint))))
            }
            guard let parent = node.parent else {
                break
            }
            node = parent
        }
        return result
    }

    private let stringView: StringView
    private let parser: TreeSitterParser
    private let lineManager: LineManager
    private let rootLanguageLayer: TreeSitterLanguageLayer
    private let operationQueue = OperationQueue()
    private let highlightQueue = OperationQueue()
    private let parseLock = NSLock()
    /// Copy of the root tree taken when the in-flight parse started; what main-thread readers get
    /// while `parseInFlight` (the parse replaces the live tree outside `parseLock`).
    private var treeSnapshotDuringParse: TreeSitterTree?
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
    /// Rows whose syntax tree changed in the last background parse that had a previous tree.
    /// `nil` means the caller should recolor the visible lines (no tree to diff against).
    private var pendingSyntaxRows: [ClosedRange<Int>]?

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

    func parse() {
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

    func parse(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
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
        // Snapshot after `ts_tree_edit` and before the parser replaces `tree`, so the diff
        // compares the edited tree with the one parse returns. A retain of the live tree
        // would be freed when the parser swaps it out.
        let previousTree = rootLanguageLayer.tree?.copy()
        treeSnapshotDuringParse = rootLanguageLayer.tree?.copy()
        parseLock.unlock()

        work()

        parseLock.lock()
        parseInFlight = false
        treeSnapshotDuringParse = nil
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
            // Injected layers (CSS in HTML, …) are not in the root diff; recolor what is on screen.
            if let previousTree, let newTree = rootLanguageLayer.tree, !rootLanguageLayer.hasChildLayers {
                pendingSyntaxRows = Self.changedRowRanges(from: previousTree, to: newTree)
            } else {
                pendingSyntaxRows = nil
            }
        }
        parseLock.unlock()
    }

    /// Rows to recolor after the background parse that just finished.
    /// `nil` means there was no previous tree, so the caller recolors what is on screen.
    func consumePendingSyntaxRows() -> [ClosedRange<Int>]? {
        parseLock.withLock {
            defer { pendingSyntaxRows = nil }
            return pendingSyntaxRows
        }
    }

    private static func changedRowRanges(from oldTree: TreeSitterTree, to newTree: TreeSitterTree) -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        for changed in oldTree.rangesChanged(comparingTo: newTree) {
            let start = Int(changed.startPoint.row)
            let end = Int(changed.endPoint.row)
            guard start <= end else {
                continue
            }
            ranges.append(start ... end)
        }
        return ranges
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
            let deferSyncParse = !PenumbraSyncKeystrokeParse.resolved(
                defaults: UserDefaults.standard.object(forKey: PenumbraSyncKeystrokeParse.defaultsKey) as? Bool
            )
            if deferSyncParse || editUTF16Length > TreeSitterPerformanceConstants.maxSyncEditLength {
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
        capturesIfReady(in: range) ?? []
    }

    /// `nil` when no usable tree exists (a parse is in flight or never finished), as opposed to
    /// `[]` for a range with no captures. A line highlighted from `nil` would be painted in
    /// `theme.textColor` and marked done, and the post-parse refresh only recolours changed rows,
    /// so it would stay white until edited.
    func capturesIfReady(in range: ByteRange) -> [TreeSitterCapture]? {
        parseLock.lock()
        if parseInFlight || !hasCompletedInitialParse {
            parseLock.unlock()
            return nil
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
            return nil
        }
        let captures = PenumbraSignposts.interval("TreeSitterInternalLanguageMode.captures") {
            if Thread.isMainThread, EditorPerformanceTrace.shared.isEnabled {
                EditorPerformanceTrace.shared.recordCount(.syncHighlightLines, count: 1)
            }
            return snapshot.captures(in: queryRange, stringView: stringView)
        }
        // Built before taking the lock: indexing is O(captures).
        let window = CaptureWindow(range: queryRange, captures: captures)
        parseLock.lock()
        // An edit during the query shifted bytes under the snapshot; its captures are off.
        let isCurrent = epoch == parseEpoch
        if isCurrent {
            storeCaptureWindow(window)
        }
        parseLock.unlock()
        guard isCurrent else {
            return nil
        }
        if queryRange == range {
            return captures
        }
        return window.captures(overlapping: range)
    }

    /// Captures for `range` only if an already-queried window covers it; never runs a query.
    /// Lets layout colour a line synchronously during a scroll instead of typesetting it in
    /// `theme.textColor` and again when the async pass lands.
    func cachedCapturesIfReady(in range: ByteRange) -> [TreeSitterCapture]? {
        parseLock.withLock {
            guard !parseInFlight, hasCompletedInitialParse else {
                return nil
            }
            return cachedCaptures(containing: range)
        }
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
        return window.captures(overlapping: range)
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
        let startLayerAndNode = nodeLookup(at: startLinePosition)
        let endLayerAndNode = nodeLookup(at: endLinePosition)
        if let indentationScopes = startLayerAndNode?.language.indentationScopes ?? endLayerAndNode?.language.indentationScopes {
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
        if let node = nodeLookup(at: linePosition)?.node, let type = node.type {
            let startLocation = TextLocation(LinePosition(node.startPoint))
            let endLocation = TextLocation(LinePosition(node.endPoint))
            return SyntaxNode(type: type, startLocation: startLocation, endLocation: endLocation)
        } else {
            return nil
        }
    }

    func detectIndentStrategy() -> DetectedIndentStrategy {
        if let tree = rootTreeSnapshot() {
            let detector = TreeSitterIndentStrategyDetector(lineManager: lineManager, tree: tree, stringView: stringView)
            return detector.detect()
        } else {
            return .unknown
        }
    }

    /// Root of a private copy of the tree, safe to walk on the main thread while a background
    /// parse runs. The node keeps its copy alive.
    var rootSyntaxNode: TreeSitterNode? {
        rootTreeSnapshot()?.rootNode
    }

    /// `ts_tree_copy` is O(1); a copy is what tree-sitter requires to use a tree on two threads.
    private func rootTreeSnapshot() -> TreeSitterTree? {
        parseLock.withLock {
            parseInFlight ? treeSnapshotDuringParse?.copy() : rootLanguageLayer.tree?.copy()
        }
    }

    /// The smallest (injection-aware) tree-sitter node at `linePosition`, for callers that need
    /// the live tree structure — parent chain, sibling rows — rather than the flattened
    /// ``SyntaxNode``. Returns `nil` when the position is outside a viewport parse window. While a
    /// parse is in flight the node comes from the root tree as it was when the parse started
    /// (see `nodeLookup(at:)`).
    ///
    /// - Important: Read what you need from the returned node immediately; never hold it across
    ///   a text edit (edits shift the tree it points into).
    func treeSitterNode(at linePosition: LinePosition) -> TreeSitterNode? {
        let parsed = parseLock.withLock { parseInFlight ? nil : parsedUTF16Range }
        if let parsed, parsed.length < stringView.length {
            let line = lineManager.line(atRow: linePosition.row)
            let location = Int(line.location) + linePosition.column
            if !NSLocationInRange(location, parsed) {
                return nil
            }
        }
        return nodeLookup(at: linePosition)?.node
    }

    /// Smallest node at `linePosition` and the language of the layer it belongs to, read without
    /// racing a background parse, which replaces layer trees outside `parseLock`. With no parse
    /// running the lookup runs under the lock and is injection-aware. During a parse it uses a
    /// copy of the root tree taken when the parse started, so injected layers are skipped until
    /// it lands. The node keeps its tree alive; only the main thread edits trees.
    private func nodeLookup(at linePosition: LinePosition) -> (node: TreeSitterNode, language: TreeSitterInternalLanguage)? {
        parseLock.withLock {
            if parseInFlight {
                guard let tree = treeSnapshotDuringParse?.copy() else {
                    return nil
                }
                let point = TreeSitterTextPoint(linePosition)
                return (tree.rootNode.descendantForRange(from: point, to: point), rootLanguageLayer.language)
            }
            return rootLanguageLayer.layerAndNode(at: linePosition).map { ($0.node, $0.layer.language) }
        }
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

/// The captures of one queried byte window, indexed so a line can pick out the captures that
/// overlap it without scanning the whole window (layout asks once per visible line, under
/// `parseLock`, and a 32k window holds thousands of captures).
struct CaptureWindow {
    let range: ByteRange
    let captures: [TreeSitterCapture]
    /// `maxEnd[i]`: largest capture end among `captures[0...i]` (non-decreasing).
    private let maxEnd: [Int]
    /// `minStart[i]`: smallest capture start among `captures[i...]` (non-decreasing).
    private let minStart: [Int]

    init(range: ByteRange, captures: [TreeSitterCapture]) {
        self.range = range
        self.captures = captures
        var maxEnd: [Int] = []
        maxEnd.reserveCapacity(captures.count)
        var runningEnd = Int.min
        for capture in captures {
            runningEnd = max(runningEnd, capture.byteRange.upperBound.value)
            maxEnd.append(runningEnd)
        }
        var minStart = [Int](repeating: 0, count: captures.count)
        var runningStart = Int.max
        for index in captures.indices.reversed() {
            runningStart = min(runningStart, captures[index].byteRange.lowerBound.value)
            minStart[index] = runningStart
        }
        self.maxEnd = maxEnd
        self.minStart = minStart
    }

    /// Exactly `captures.filter { $0.byteRange.overlaps(range) }`, in the same order. A capture
    /// overlaps (closed ranges) when `start <= range.upper && range.lower <= end`, so everything
    /// before the first `maxEnd >= range.lower` and from the first `minStart > range.upper` on
    /// can't overlap.
    func captures(overlapping range: ByteRange) -> [TreeSitterCapture] {
        let lower = range.lowerBound.value
        let upper = range.upperBound.value
        let first = Self.firstIndex(in: maxEnd) { $0 >= lower }
        let end = Self.firstIndex(in: minStart) { $0 > upper }
        guard first < end else {
            return []
        }
        return captures[first ..< end].filter { $0.byteRange.overlaps(range) }
    }

    /// First index whose value satisfies `predicate`, for a predicate that is false then true
    /// along the (non-decreasing) array; `values.count` when none does.
    private static func firstIndex(in values: [Int], where predicate: (Int) -> Bool) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let mid = (low + high) / 2
            if predicate(values[mid]) {
                high = mid
            } else {
                low = mid + 1
            }
        }
        return low
    }
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
