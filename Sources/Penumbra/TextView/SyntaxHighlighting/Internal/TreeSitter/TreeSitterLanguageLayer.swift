import Foundation

final class TreeSitterLanguageLayer {
    typealias LayerAndNodeTuple = (layer: TreeSitterLanguageLayer, node: TreeSitterNode)

    let language: TreeSitterInternalLanguage
    private(set) var tree: TreeSitterTree?
    var canHighlight: Bool {
        parser.language != nil && tree != nil
    }
    /// `false` when neither this layer nor any injected child layer has a highlights query, i.e.
    /// no query will ever produce a non-default color here. Used to tell "will highlight once the
    /// parse lands" apart from "will never highlight" (see `LineController.isSyntaxHighlightPending`).
    var highlightsQueryAvailable: Bool {
        language.highlightsQuery != nil || childLanguageLayerStore.allLayers.contains { $0.highlightsQueryAvailable }
    }

    private let lineManager: LineManager
    private let parser: TreeSitterParser
    private let stringView: StringView
    private var childLanguageLayerStore = TreeSitterLanguageLayerStore()
    /// Injected layers are not diffed by `ts_tree_get_changed_ranges` on the root tree.
    var hasChildLayers: Bool {
        !childLanguageLayerStore.allLayers.isEmpty
    }
    private weak var parentLanguageLayer: TreeSitterLanguageLayer?
    private let languageProvider: TreeSitterLanguageProvider?
    /// Temporary (Inject-language) injections. Asked on a full parse; shifted across edits between
    /// parses and written back so the provider's store never goes stale.
    private let manualInjectionProvider: ManualInjectionProviding?
    /// Last-known temporaries: provider values (shifted per edit, pushed back) and their carved
    /// parse ranges (shifted per edit, reused by the incremental path without re-asking).
    private var temporarySources: [ManualLanguageInjection] = []
    private var temporaryContents: [ManualInjectionContent] = []
    /// Manual child layers by record key, with their last-parsed ranges for edit shifting and
    /// overlap reconciliation. Separate from the node-keyed store, which query pruning owns.
    private var manualRecords: [String: ManualRecord] = [:]
    /// Included ranges for the root language layer under ``SyntaxParsePolicy/viewport``.
    /// Empty means parse the whole document. Child layers ignore this and use injection ranges.
    private var rootIncludedRanges: [TreeSitterTextRange] = []
    /// What a child layer was last parsed over when its injection left text out (`injection.exclude`).
    /// `nil` means the whole injected node, which `applyEditPreservingIncludedRange` reads back from
    /// the tree's root.
    private var excludedIncludedRanges: [TreeSitterTextRange]?
    private var isEmpty: Bool {
        if let rootNode = tree?.rootNode {
            return rootNode.endByte - rootNode.startByte <= ByteCount(0)
        } else {
            return true
        }
    }

    init(language: TreeSitterInternalLanguage,
         languageProvider: TreeSitterLanguageProvider?,
         parser: TreeSitterParser,
         stringView: StringView,
         lineManager: LineManager,
         manualInjectionProvider: ManualInjectionProviding? = nil) {
        self.language = language
        self.languageProvider = languageProvider
        self.parser = parser
        self.stringView = stringView
        self.lineManager = lineManager
        self.manualInjectionProvider = manualInjectionProvider
    }

    /// Shifts cached temporary ranges across `edit` (keystroke and large-edit paths). Only the
    /// root layer holds temporaries; child layers share the parser and never own manual state.
    func shiftManualRanges(_ edit: TreeSitterInputEdit) {
        guard parentLanguageLayer == nil else {
            return
        }
        guard !temporarySources.isEmpty || !manualRecords.isEmpty else {
            return
        }
        temporarySources = temporarySources.map { source in
            ManualLanguageInjection(utf16Range: Self.shiftedUTF16Range(source.utf16Range, by: edit),
                                    languageIdentifier: source.languageIdentifier,
                                    source: source.source)
        }
        temporaryContents = temporaryContents.map { $0.shifted(by: edit) }
        for key in manualRecords.keys {
            manualRecords[key]?.shift(by: edit)
        }
        if !temporarySources.isEmpty {
            manualInjectionProvider?.manualInjectionsDidShift(temporarySources)
        }
    }
}

// MARK: - Parsing
extension TreeSitterLanguageLayer {
    /// Callback-based parse used after the language mode is attached to a ``TextInputView``.
    /// Honors ``rootIncludedRanges`` so a viewport window does not copy or walk the whole buffer.
    func parseUsingReader() {
        prepareParser(toParse: [])
        if let parsed = parser.parse(oldTree: tree) {
            tree = parsed
        } else if parser.lastParseAborted {
            return
        }
        childLanguageLayerStore.removeAll()
        removeAllManualLayers()
        guard let node = tree?.rootNode else {
            return
        }
        var injectedLanguages: [TreeSitterInjectedLanguage] = []
        if let injectionsQuery = language.injectionsQuery {
            let queryCursor = TreeSitterQueryCursor(query: injectionsQuery, node: node)
            queryCursor.execute()
            let captures = queryCursor.validCaptures(in: stringView)
            injectedLanguages = self.injectedLanguages(from: captures)
        }
        // Manual wins on overlap: an automatic fragment intersecting a manual range is dropped
        // whole — splitting an automatic fragment around a manual one is out of scope.
        // Manual state lives on the root layer only; child layers recurse into their own
        // `injections.scm` without it.
        let manuals = parentLanguageLayer == nil
            ? currentManualContents(rootNode: node, window: nil, refreshingTemporary: true)
            : []
        if !manuals.isEmpty {
            injectedLanguages.removeAll { automatic in
                let automaticRange = ByteRange(from: automatic.textRange.startByte, to: automatic.textRange.endByte)
                return manuals.contains { $0.byteRange.overlaps(automaticRange) }
            }
        }
        for injectedLanguage in injectedLanguages {
            if let childLanguageLayer = childLanguageLayer(withID: injectedLanguage.id, forLanguageNamed: injectedLanguage.languageName) {
                childLanguageLayer.excludedIncludedRanges = injectedLanguage.hasExcludedText ? injectedLanguage.textRanges : nil
                childLanguageLayer.parseUsingReader(ranges: injectedLanguage.textRanges)
            }
        }
        materializeManualLayers(manuals)
    }

    func restoreTree(_ tree: TreeSitterTree?) {
        self.tree = tree
    }

    /// Converts a UTF-16 window to the line/column text range the parser needs. Reads
    /// `LineManager`, so call it on the main thread only; `nil` means the whole document.
    func rootIncludedTextRange(for range: NSRange?, stringLength: Int) -> TreeSitterTextRange? {
        guard let range,
              range.length > 0,
              range != NSRange(location: 0, length: stringLength) else {
            return nil
        }
        return ViewportParseWindow.textRange(for: range, lineManager: lineManager)
    }

    /// Main thread only (see ``rootIncludedTextRange(for:stringLength:)``).
    func setRootIncludedUTF16Range(_ range: NSRange?, stringLength: Int) {
        setRootIncludedRange(rootIncludedTextRange(for: range, stringLength: stringLength))
    }

    /// Takes an already converted window, so a background parse never touches `LineManager`.
    func setRootIncludedRange(_ textRange: TreeSitterTextRange?) {
        guard parentLanguageLayer == nil else {
            return
        }
        rootIncludedRanges = textRange.map { [$0] } ?? []
    }

    func invalidateTree() {
        tree = nil
        rootIncludedRanges = []
        childLanguageLayerStore.removeAll()
        // Manual layers hold trees over the discarded buffer too. The temporary cache survives:
        // its ranges are still in valid coordinates and the next parse re-carves from them.
        if parentLanguageLayer == nil {
            removeAllManualLayers()
        }
    }

    func apply(_ edit: TreeSitterInputEdit) -> LineChangeSet {
        let ranges = [tree?.rootNode.textRange].compactMap { $0 }
        return apply(edit, parsing: ranges)
    }

    /// Cheap `ts_tree_edit` on this layer and every child, with no reparse. Used when the edit is
    /// larger than ``TreeSitterPerformanceConstants/maxSyncEditLength`` so the keystroke does not
    /// wait on an incremental parse; a background parse consumes the edited tree afterwards.
    func applyEditWithoutParsing(_ edit: TreeSitterInputEdit) {
        tree?.apply(edit)
        // The trees below shift with the edit but no reparse follows on this path, so the cached
        // temporary ranges (and the provider's store, via write-back) must shift here too — the
        // next background full parse re-asks the provider and would otherwise read stale ranges.
        shiftManualRanges(edit)
        applyEditWithoutParsingToChildren(edit)
    }

    private func applyEditWithoutParsingToChildren(_ edit: TreeSitterInputEdit) {
        for child in childLanguageLayerStore.allLayers {
            child.applyEditWithoutParsing(edit)
        }
    }

    /// Copy-on-write snapshot of this layer and its injection children, safe to query off `parseLock`.
    func snapshotForQuery() -> TreeSitterQuerySnapshot? {
        guard let tree = tree?.copy() else {
            return nil
        }
        let children = childLanguageLayerStore.allLayers.compactMap { $0.snapshotForQuery() }
        return TreeSitterQuerySnapshot(tree: tree, language: language, children: children)
    }

    /// Applies `edit` and re-parses using the tree's post-edit root range rather than a freshly
    /// queried injection range. Used for child layers that sit entirely after the edited region.
    func applyEditPreservingIncludedRange(_ edit: TreeSitterInputEdit) -> LineChangeSet {
        let oldTree = tree
        tree?.apply(edit)
        let ranges: [TreeSitterTextRange]
        if let excluded = excludedIncludedRanges {
            // The root spans the text that was left out too, so move the ranges themselves.
            ranges = excluded.map { $0.applying(edit) }
            excludedIncludedRanges = ranges
        } else {
            ranges = [tree?.rootNode.textRange].compactMap { $0 }
        }
        return completeApply(oldTree: oldTree, parsing: ranges, childEdit: edit)
    }

    func layerAndNode(at linePosition: LinePosition) -> LayerAndNodeTuple? {
        let point = TreeSitterTextPoint(linePosition)
        guard let node = tree?.rootNode.descendantForRange(from: point, to: point) else {
            return nil
        }
        var result: LayerAndNodeTuple = (layer: self, node: node)
        for childLanguageLayer in childLanguageLayerStore.allLayers {
            if let childRootNode = childLanguageLayer.tree?.rootNode, childRootNode.contains(point) {
                if let childResult = childLanguageLayer.layerAndNode(at: linePosition) {
                    if childResult.node.byteRange.length < result.node.byteRange.length {
                        result = childResult
                    }
                }
            }
        }
        return result
    }

    private func apply(_ edit: TreeSitterInputEdit, parsing ranges: [TreeSitterTextRange] = []) -> LineChangeSet {
        let oldTree = tree
        tree?.apply(edit)
        return completeApply(oldTree: oldTree, parsing: ranges, childEdit: edit)
    }

    private func completeApply(
        oldTree: TreeSitterTree?,
        parsing ranges: [TreeSitterTextRange],
        childEdit edit: TreeSitterInputEdit
    ) -> LineChangeSet {
        prepareParser(toParse: ranges)
        if let parsed = parser.parse(oldTree: tree) {
            tree = parsed
        }
        let lineChangeSet = LineChangeSet()
        if let oldTree = oldTree, let newTree = tree, !parser.lastParseAborted {
            let changedRanges = oldTree.rangesChanged(comparingTo: newTree)
            for changedRange in changedRanges {
                let lastRow = max(lineManager.lineCount - 1, 0)
                let startRow = min(max(Int(changedRange.startPoint.row), 0), lastRow)
                let endRow = min(max(Int(changedRange.endPoint.row), 0), lastRow)
                guard startRow <= endRow else {
                    continue
                }
                for row in startRow ... endRow {
                    let line = lineManager.line(atRow: row)
                    lineChangeSet.markLineEdited(line)
                }
            }
        }
        if parser.lastParseAborted {
            applyEditWithoutParsingToChildren(edit)
            return lineChangeSet
        }
        let childLineChangeSet = updateChildLayers(applying: edit)
        lineChangeSet.union(with: childLineChangeSet)
        return lineChangeSet
    }

    private func parseUsingReader(ranges: [TreeSitterTextRange]) {
        prepareParser(toParse: ranges)
        if let parsed = parser.parse(oldTree: tree) {
            tree = parsed
        }
    }

    private func prepareParser(toParse ranges: [TreeSitterTextRange]) {
        parser.language = language.languagePointer
        if parentLanguageLayer != nil {
            if !ranges.isEmpty {
                parser.setIncludedRanges(ranges)
            } else {
                parser.removeAllIncludedRanges()
            }
        } else if !rootIncludedRanges.isEmpty {
            parser.setIncludedRanges(rootIncludedRanges)
        } else {
            parser.removeAllIncludedRanges()
        }
    }
}

// MARK: - Syntax Highlighting
extension TreeSitterLanguageLayer {
    func captures(in range: ByteRange) -> [TreeSitterCapture] {
        snapshotForQuery()?.captures(in: range, stringView: stringView) ?? []
    }
}

/// Immutable copy of a language layer's trees, queried without holding `parseLock`.
final class TreeSitterQuerySnapshot {
    let tree: TreeSitterTree
    let language: TreeSitterInternalLanguage
    let children: [TreeSitterQuerySnapshot]

    init(tree: TreeSitterTree, language: TreeSitterInternalLanguage, children: [TreeSitterQuerySnapshot]) {
        self.tree = tree
        self.language = language
        self.children = children
    }

    func captures(in range: ByteRange, stringView: StringView) -> [TreeSitterCapture] {
        guard !range.isEmpty else {
            return []
        }
        var captures = allValidCaptures(in: range, stringView: stringView)
        captures.sort(by: TreeSitterCapture.captureLayerSorting)
        return captures
    }

    private func allValidCaptures(in range: ByteRange, stringView: StringView) -> [TreeSitterCapture] {
        guard let highlightsQuery = language.highlightsQuery else {
            return []
        }
        let queryCursor = TreeSitterQueryCursor(query: highlightsQuery, node: tree.rootNode)
        queryCursor.setQueryRange(range)
        queryCursor.execute()
        let captures = queryCursor.validCaptures(in: stringView)
        let capturesInChildren = children.reduce(into: []) { $0 += $1.allValidCaptures(in: range, stringView: stringView) }
        return captures + capturesInChildren
    }
}

// MARK: - Child Language Layers
private extension TreeSitterLanguageLayer {
    @discardableResult
    private func childLanguageLayer(withID id: UnsafeRawPointer, forLanguageNamed languageName: String) -> TreeSitterLanguageLayer? {
        if let childLanguageLayer = childLanguageLayerStore.layer(forKey: id) {
            return childLanguageLayer
        } else if let language = languageProvider?.treeSitterLanguage(named: languageName) {
            let childLanguageLayer = TreeSitterLanguageLayer(
                language: language.internalLanguage,
                languageProvider: languageProvider,
                parser: parser,
                stringView: stringView,
                lineManager: lineManager)
            childLanguageLayer.parentLanguageLayer = self
            childLanguageLayerStore.storeLayer(childLanguageLayer, forKey: id)
            return childLanguageLayer
        } else {
            return nil
        }
    }

    private func updateChildLayers(applying edit: TreeSitterInputEdit) -> LineChangeSet {
        if parentLanguageLayer == nil {
            shiftManualRanges(edit)
        }
        guard let node = tree?.rootNode else {
            childLanguageLayerStore.removeAll()
            if parentLanguageLayer == nil {
                removeAllManualLayers()
            }
            return LineChangeSet()
        }
        let documentRange = node.byteRange
        let editRange = ByteRange(from: edit.startByte, to: max(edit.oldEndByte, edit.newEndByte))
        let pad = ByteCount(utf16Length: TreeSitterPerformanceConstants.highlightQueryWindowUTF16Length)
        let unboundedStart = ByteCount(max(0, editRange.lowerBound.value - pad.value))
        let unboundedEnd = editRange.upperBound + pad
        let unboundedEditWindow = ByteRange(from: unboundedStart, to: unboundedEnd)
        if !documentRange.overlaps(unboundedEditWindow) {
            return shiftChildrenAfterEdit(edit)
        }
        let queryRange = editRange.padded(by: pad, within: documentRange)
        guard !queryRange.isEmpty else {
            return shiftChildrenAfterEdit(edit)
        }
        var injectedLanguages: [TreeSitterInjectedLanguage] = []
        if let injectionsQuery = language.injectionsQuery {
            let injectionsQueryCursor = TreeSitterQueryCursor(query: injectionsQuery, node: node)
            injectionsQueryCursor.setQueryRange(queryRange)
            injectionsQueryCursor.execute()
            let captures = injectionsQueryCursor.validCaptures(in: stringView)
            injectedLanguages = self.injectedLanguages(from: captures)
        }
        // Manual injections on the incremental path use the shifted temporary cache plus comment
        // discovery inside this edit's window — never a document walk per keystroke.
        let manuals = parentLanguageLayer == nil
            ? currentManualContents(rootNode: node, window: queryRange, refreshingTemporary: false)
            : []
        if !manuals.isEmpty {
            injectedLanguages.removeAll { automatic in
                let automaticRange = ByteRange(from: automatic.textRange.startByte, to: automatic.textRange.endByte)
                return manuals.contains { $0.byteRange.overlaps(automaticRange) }
            }
        }
        let capturedIDs = Set(injectedLanguages.map(\.id))
        let currentIDs = childLanguageLayerStore.allIDs
        let lineChangeSet = LineChangeSet()
        for id in currentIDs {
            guard let layer = childLanguageLayerStore.layer(forKey: id) else {
                continue
            }
            let layerRange = layer.tree?.rootNode.byteRange
            if let layerRange, layerRange.length <= 0 {
                childLanguageLayerStore.removeLayer(forKey: id)
                continue
            }
            if let layerRange, layerRange.upperBound <= edit.startByte {
                continue
            }
            let overlapsQuery = layerRange?.overlaps(queryRange) ?? true
            if overlapsQuery && !capturedIDs.contains(id) {
                childLanguageLayerStore.removeLayer(forKey: id)
                continue
            }
            if !overlapsQuery {
                let childLineChangeSet = layer.applyEditPreservingIncludedRange(edit)
                lineChangeSet.union(with: childLineChangeSet)
            }
        }
        for injectedLanguage in injectedLanguages {
            if let childLanguageLayer = childLanguageLayer(withID: injectedLanguage.id, forLanguageNamed: injectedLanguage.languageName) {
                childLanguageLayer.excludedIncludedRanges = injectedLanguage.hasExcludedText ? injectedLanguage.textRanges : nil
                let childLineChangeSet = childLanguageLayer.apply(edit, parsing: injectedLanguage.textRanges)
                lineChangeSet.union(with: childLineChangeSet)
            }
        }
        if parentLanguageLayer == nil {
            lineChangeSet.union(with: reconcileManualLayers(manuals, edit: edit, queryWindow: queryRange))
        }
        return lineChangeSet
    }

    private func shiftChildrenAfterEdit(_ edit: TreeSitterInputEdit) -> LineChangeSet {
        let lineChangeSet = LineChangeSet()
        for layer in childLanguageLayerStore.allLayers {
            guard let range = layer.tree?.rootNode.byteRange, range.upperBound > edit.startByte else {
                continue
            }
            lineChangeSet.union(with: layer.applyEditPreservingIncludedRange(edit))
        }
        return lineChangeSet
    }

    private func injectedLanguages(from captures: [TreeSitterCapture]) -> [TreeSitterInjectedLanguage] {
        let mapper = TreeSitterInjectedLanguageMapper(captures: captures)
        mapper.delegate = self
        return mapper.map()
    }
}

// MARK: - Manual language injections

/// Last-parsed state of one manual child layer. Ranges (not keys) are the reconcile identity:
/// comment anchors and temporary ranges both shift with edits.
private struct ManualRecord {
    var languageName: String
    var byteRange: ByteRange
    var textRanges: [TreeSitterTextRange]

    mutating func shift(by edit: TreeSitterInputEdit) {
        byteRange = TreeSitterLanguageLayer.shiftedByteRange(byteRange, by: edit)
        textRanges = textRanges.map { $0.applying(edit) }
    }
}

private extension ManualInjectionContent {
    func shifted(by edit: TreeSitterInputEdit) -> ManualInjectionContent {
        ManualInjectionContent(
            key: key,
            languageName: languageName,
            byteRange: TreeSitterLanguageLayer.shiftedByteRange(byteRange, by: edit),
            textRanges: textRanges.map { $0.applying(edit) })
    }
}

private extension TreeSitterLanguageLayer {
    /// Desired manual contents: shifted temporaries plus fresh comment discovery. Temporary wins
    /// over comment on overlap. Unknown languages are filtered at materialize time (the provider
    /// resolves them), so they stay visible here for overlap suppression.
    func currentManualContents(rootNode: TreeSitterNode, window: ByteRange?, refreshingTemporary: Bool) -> [ManualInjectionContent] {
        if refreshingTemporary {
            refreshTemporaryContents(rootNode: rootNode)
        }
        // Comment discovery needs no provider, so it always runs; temporaries win on overlap.
        var contents = temporaryContents
        for comment in commentContents(rootNode: rootNode, window: window) {
            guard !temporaryContents.contains(where: { $0.byteRange.overlaps(comment.byteRange) }) else {
                continue
            }
            contents.append(comment)
        }
        return contents
    }

    func removeAllManualLayers() {
        childLanguageLayerStore.removeAllManual()
        manualRecords.removeAll()
    }

    /// Full-parse materialize: every desired injection gets a fresh layer and parse.
    func materializeManualLayers(_ manuals: [ManualInjectionContent]) {
        for manual in manuals {
            guard let layer = makeManualChildLayer(forLanguageNamed: manual.languageName, key: manual.key) else {
                continue
            }
            manualRecords[manual.key] = ManualRecord(languageName: manual.languageName,
                                                     byteRange: manual.byteRange,
                                                     textRanges: manual.textRanges)
            layer.excludedIncludedRanges = manual.textRanges
            layer.parseUsingReader(ranges: manual.textRanges)
        }
    }

    /// Incremental reconcile against `manuals` (already shifted to post-edit coordinates):
    /// reparse records overlapping the query window, shift the rest, drop the unmatched.
    func reconcileManualLayers(_ manuals: [ManualInjectionContent],
                               edit: TreeSitterInputEdit,
                               queryWindow: ByteRange) -> LineChangeSet {
        let lineChangeSet = LineChangeSet()
        var matchedKeys = Set<String>()
        for manual in manuals {
            if let key = manualRecords.first(where: {
                $0.value.languageName == manual.languageName && $0.value.byteRange.overlaps(manual.byteRange)
            })?.key,
               let layer = childLanguageLayerStore.manualLayer(forKey: key) {
                if key != manual.key {
                    childLanguageLayerStore.removeManualLayer(forKey: key)
                    childLanguageLayerStore.storeManualLayer(layer, forKey: manual.key)
                    manualRecords.removeValue(forKey: key)
                }
                manualRecords[manual.key] = ManualRecord(languageName: manual.languageName,
                                                         byteRange: manual.byteRange,
                                                         textRanges: manual.textRanges)
                matchedKeys.insert(manual.key)
                layer.excludedIncludedRanges = manual.textRanges
                lineChangeSet.union(with: layer.apply(edit, parsing: manual.textRanges))
            } else if let layer = makeManualChildLayer(forLanguageNamed: manual.languageName, key: manual.key) {
                manualRecords[manual.key] = ManualRecord(languageName: manual.languageName,
                                                         byteRange: manual.byteRange,
                                                         textRanges: manual.textRanges)
                matchedKeys.insert(manual.key)
                layer.excludedIncludedRanges = manual.textRanges
                lineChangeSet.union(with: layer.apply(edit, parsing: manual.textRanges))
            }
        }
        for key in manualRecords.keys where !matchedKeys.contains(key) {
            guard let record = manualRecords[key] else {
                continue
            }
            if record.byteRange.overlaps(queryWindow) {
                childLanguageLayerStore.removeManualLayer(forKey: key)
                manualRecords.removeValue(forKey: key)
            } else if let layer = childLanguageLayerStore.manualLayer(forKey: key) {
                // Outside the window: keep the layer, its record ranges were already shifted with
                // the edit at the top of `updateChildLayers`.
                lineChangeSet.union(with: layer.applyEditPreservingIncludedRange(edit))
            }
        }
        return lineChangeSet
    }

    /// Creates (but does not parse) a manual child layer. `nil` for unknown language names —
    /// they are ignored, never errors.
    func makeManualChildLayer(forLanguageNamed languageName: String, key: String) -> TreeSitterLanguageLayer? {
        guard let language = languageProvider?.treeSitterLanguage(named: languageName) else {
            return nil
        }
        let layer = TreeSitterLanguageLayer(
            language: language.internalLanguage,
            languageProvider: languageProvider,
            parser: parser,
            stringView: stringView,
            lineManager: lineManager)
        layer.parentLanguageLayer = self
        childLanguageLayerStore.storeManualLayer(layer, forKey: key)
        return layer
    }

    func commentContents(rootNode: TreeSitterNode, window: ByteRange?) -> [ManualInjectionContent] {
        let discovery = ManualLanguageInjectionDiscovery()
        discovery.lineCommentPrefix = language.lineCommentPrefix
        discovery.blockCommentDelimiters = language.blockCommentDelimiters
        discovery.readText = { [stringView] range in stringView.substring(in: range) }
        return discovery.commentInjections(under: rootNode, window: window) { [stringView] in
            stringView.substring(in: NSRange(location: 0, length: stringView.length))
        }
    }

    /// Re-reads the temporary provider and carves fresh contents. Only on a full parse; the
    /// incremental path reuses the shifted cache without re-asking.
    func refreshTemporaryContents(rootNode: TreeSitterNode) {
        guard let provider = manualInjectionProvider else {
            temporarySources = []
            temporaryContents = []
            return
        }
        var sources: [ManualLanguageInjection] = []
        var contents: [ManualInjectionContent] = []
        for injection in provider.manualInjections() {
            guard let content = convertTemporary(injection, rootNode: rootNode) else {
                continue
            }
            sources.append(injection)
            contents.append(content)
        }
        temporarySources = sources
        temporaryContents = contents
    }

    /// Snaps a provider range to the string literal covering it (carving quotes and host
    /// interpolation spans), falling back to the raw range when no string node covers it.
    func convertTemporary(_ injection: ManualLanguageInjection, rootNode: TreeSitterNode) -> ManualInjectionContent? {
        let documentBytes = ByteCount(utf16Length: stringView.length)
        var byteRange = ByteRange(utf16Range: injection.utf16Range)
        byteRange = ByteRange(from: max(byteRange.lowerBound, ByteCount(0)),
                              to: min(byteRange.upperBound, documentBytes))
        guard !byteRange.isEmpty, byteRange.lowerBound < documentBytes else {
            return nil
        }
        let languageName = FenceLanguageName.normalize(injection.languageIdentifier)
            ?? injection.languageIdentifier
        let key = "temporary:\(languageName):\(byteRange.lowerBound.value)-\(byteRange.upperBound.value)"
        let read: (NSRange) -> String? = { [stringView] range in stringView.substring(in: range) }
        if let stringNode = ManualLanguageInjectionDiscovery.stringNode(containing: byteRange, under: rootNode),
           let nodeText = read(NSRange(stringNode.byteRange)) {
            let carved = ManualLanguageInjectionDiscovery.contentTextRanges(of: stringNode, readText: read)
            let carvedBytes = carved.map { ByteRange(from: $0.startByte, to: $0.endByte) }
            let kept = carvedBytes.filter { byteRange.contains($0) }
            if !kept.isEmpty {
                let pieces = kept
                let range = ByteRange(from: pieces.map(\.lowerBound).min()!, to: pieces.map(\.upperBound).max()!)
                let converted = ManualLanguageInjectionDiscovery.textRanges(
                    for: pieces,
                    scanning: Array(nodeText.utf16),
                    baseByte: stringNode.byteRange.lowerBound.value,
                    basePoint: stringNode.startPoint)
                guard !converted.isEmpty else {
                    return nil
                }
                return ManualInjectionContent(key: key, languageName: languageName, byteRange: range, textRanges: converted)
            }
            let intersected = carvedBytes.compactMap { piece -> ByteRange? in
                let lower = max(piece.lowerBound, byteRange.lowerBound)
                let upper = min(piece.upperBound, byteRange.upperBound)
                guard upper > lower else {
                    return nil
                }
                return ByteRange(from: lower, to: upper)
            }
            if !intersected.isEmpty {
                let converted = ManualLanguageInjectionDiscovery.textRanges(
                    for: intersected,
                    scanning: Array(nodeText.utf16),
                    baseByte: stringNode.byteRange.lowerBound.value,
                    basePoint: stringNode.startPoint)
                guard !converted.isEmpty else {
                    return nil
                }
                let range = ByteRange(from: intersected.map(\.lowerBound).min()!,
                                      to: intersected.map(\.upperBound).max()!)
                return ManualInjectionContent(key: key, languageName: languageName, byteRange: range, textRanges: converted)
            }
        }
        // No covering string literal (or nothing usable in it): parse the raw range.
        guard let prefix = read(NSRange(location: 0, length: min(byteRange.upperBound.value / 2, stringView.length))),
              !prefix.isEmpty else {
            return nil
        }
        let converted = ManualLanguageInjectionDiscovery.textRanges(
            for: [byteRange],
            scanning: Array(prefix.utf16),
            baseByte: 0,
            basePoint: TreeSitterTextPoint(row: 0, column: 0))
        guard !converted.isEmpty else {
            return nil
        }
        return ManualInjectionContent(key: key, languageName: languageName, byteRange: byteRange, textRanges: converted)
    }

    static func shiftedByteRange(_ range: ByteRange, by edit: TreeSitterInputEdit) -> ByteRange {
        func moved(_ byte: ByteCount) -> ByteCount {
            if byte >= edit.oldEndByte {
                return ByteCount(byte.value - edit.oldEndByte.value + edit.newEndByte.value)
            }
            if byte > edit.startByte {
                return edit.newEndByte
            }
            return byte
        }
        let lower = moved(range.lowerBound)
        let upper = moved(range.upperBound)
        guard upper > lower else {
            return ByteRange(from: lower, to: lower)
        }
        return ByteRange(from: lower, to: upper)
    }

    static func shiftedUTF16Range(_ range: NSRange, by edit: TreeSitterInputEdit) -> NSRange {
        func moved(_ byteValue: Int) -> Int {
            if byteValue >= edit.oldEndByte.value {
                return (byteValue - edit.oldEndByte.value + edit.newEndByte.value) / 2
            }
            if byteValue > edit.startByte.value {
                return edit.newEndByte.value / 2
            }
            return byteValue / 2
        }
        let start = max(0, moved(range.location * 2))
        let end = max(start, moved(range.upperBound * 2))
        return NSRange(location: start, length: end - start)
    }
}

// MARK: - TreeSitterInjectedLanguageMapperDelegate
extension TreeSitterLanguageLayer: TreeSitterInjectedLanguageMapperDelegate {
    func treeSitterInjectedLanguageMapper(_ mapper: TreeSitterInjectedLanguageMapper, textIn textRange: TreeSitterTextRange) -> String? {
        let byteRange = ByteRange(from: textRange.startByte, to: textRange.endByte)
        let range = NSRange(byteRange)
        return stringView.substring(in: range)
    }
}

// MARK: - Debugging Language Layers
extension TreeSitterLanguageLayer {
    func languageHierarchyStringRepresentation() -> String {
        var str = ""
        if let rootNode = tree?.rootNode {
            str += "● [\(rootNode.byteRange.lowerBound) - \(rootNode.byteRange.upperBound)]"
        } else {
            str += "●"
        }
        if !childLanguageLayerStore.isEmpty {
            str += "\n"
            str += childLanguageHierarchy(indent: 1)
        }
        return str
    }

    private func childLanguageHierarchy(indent: Int) -> String {
        var str = ""
        let languageIDs = childLanguageLayerStore.allIDs
        for (idx, languageID) in languageIDs.enumerated() {
            let indentStr = String(repeating: "  ", count: indent)
            let childLanguageLayer = childLanguageLayerStore.layer(forKey: languageID)!
            if let rootNode = childLanguageLayer.tree?.rootNode {
                str += indentStr + "\(languageID) [\(rootNode.byteRange.lowerBound) - \(rootNode.byteRange.upperBound)]"
            } else {
                str += indentStr + "\(languageID)"
            }
            if !childLanguageLayer.childLanguageLayerStore.isEmpty {
                str += "\n"
                str += childLanguageLayer.childLanguageHierarchy(indent: indent + 1)
            }
            if idx < languageIDs.count - 1 {
                str += indentStr + "\n"
            }
        }
        return str
    }
}

extension TreeSitterLanguageLayer: CustomDebugStringConvertible {
    var debugDescription: String {
        "[TreeSitterLanguageLayer node=\(tree?.rootNode.debugDescription ?? "") childLanguageLayers=\(childLanguageLayerStore)]"
    }
}

private extension TreeSitterCapture {
    static func captureLayerSorting(_ lhs: TreeSitterCapture, _ rhs: TreeSitterCapture) -> Bool {
        // We sort the captures by three parameters:
        // 1. The location. Captures that are early in the text should be sorted first.
        // 2. The length of the capture. If two captures start at the same location, then we sort the longest capture first.
        //    Short captures that start at that location adds another "layer" of capturing on top of a previous capture.
        // 3. The number of components in the name. E.g. "variable.builtin" is sorted after "variable" as the styling of "variable.builtin"
        //    should be applied after applying the styling of "variable", since it's a specialization.
        // 4. The pattern index, descending. The last capture applied wins, and highlight queries put
        //    specific patterns before fallbacks, so `(annotation name: (identifier) @attribute)` must
        //    be applied after the later `(identifier) @variable`.
        if lhs.byteRange.location < rhs.byteRange.location {
            return true
        } else if lhs.byteRange.location > rhs.byteRange.location {
            return false
        } else if lhs.byteRange.length > rhs.byteRange.length {
            return true
        } else if lhs.byteRange.length < rhs.byteRange.length {
            return false
        } else if lhs.nameComponentCount != rhs.nameComponentCount {
            return lhs.nameComponentCount < rhs.nameComponentCount
        } else {
            return lhs.patternIndex > rhs.patternIndex
        }
    }
}

private extension TreeSitterNode {
    func contains(_ point: TreeSitterTextPoint) -> Bool {
        let containsStart = point.row > startPoint.row || (point.row == startPoint.row && point.column >= startPoint.column)
        let containsEnd = point.row < endPoint.row || (point.row == endPoint.row && point.column <= endPoint.column)
        return containsStart && containsEnd
    }
}
