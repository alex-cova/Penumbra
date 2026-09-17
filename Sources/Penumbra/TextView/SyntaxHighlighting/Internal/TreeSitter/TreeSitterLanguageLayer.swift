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
    private weak var parentLanguageLayer: TreeSitterLanguageLayer?
    private let languageProvider: TreeSitterLanguageProvider?
    /// Included ranges for the root language layer under ``SyntaxParsePolicy/viewport``.
    /// Empty means parse the whole document. Child layers ignore this and use injection ranges.
    private var rootIncludedRanges: [TreeSitterTextRange] = []
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
         lineManager: LineManager) {
        self.language = language
        self.languageProvider = languageProvider
        self.parser = parser
        self.stringView = stringView
        self.lineManager = lineManager
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
        guard let injectionsQuery = language.injectionsQuery, let node = tree?.rootNode else {
            return
        }
        let queryCursor = TreeSitterQueryCursor(query: injectionsQuery, node: node)
        queryCursor.execute()
        let captures = queryCursor.validCaptures(in: stringView)
        let injectedLanguages = injectedLanguages(from: captures)
        for injectedLanguage in injectedLanguages {
            if let childLanguageLayer = childLanguageLayer(withID: injectedLanguage.id, forLanguageNamed: injectedLanguage.languageName) {
                childLanguageLayer.parseUsingReader(ranges: [injectedLanguage.textRange])
            }
        }
    }

    func restoreTree(_ tree: TreeSitterTree?) {
        self.tree = tree
    }

    func setRootIncludedUTF16Range(_ range: NSRange?, stringLength: Int) {
        guard parentLanguageLayer == nil else {
            return
        }
        guard let range,
              range.length > 0,
              range != NSRange(location: 0, length: stringLength),
              let textRange = ViewportParseWindow.textRange(for: range, lineManager: lineManager) else {
            rootIncludedRanges = []
            return
        }
        rootIncludedRanges = [textRange]
    }

    func invalidateTree() {
        tree = nil
        rootIncludedRanges = []
        childLanguageLayerStore.removeAll()
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
        let ranges = [tree?.rootNode.textRange].compactMap { $0 }
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
        guard let injectionsQuery = language.injectionsQuery, let node = tree?.rootNode else {
            childLanguageLayerStore.removeAll()
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
        let injectionsQueryCursor = TreeSitterQueryCursor(query: injectionsQuery, node: node)
        injectionsQueryCursor.setQueryRange(queryRange)
        injectionsQueryCursor.execute()
        let captures = injectionsQueryCursor.validCaptures(in: stringView)
        let injectedLanguages = injectedLanguages(from: captures)
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
                let childLineChangeSet = childLanguageLayer.apply(edit, parsing: [injectedLanguage.textRange])
                lineChangeSet.union(with: childLineChangeSet)
            }
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
        if lhs.byteRange.location < rhs.byteRange.location {
            return true
        } else if lhs.byteRange.location > rhs.byteRange.location {
            return false
        } else if lhs.byteRange.length > rhs.byteRange.length {
            return true
        } else if lhs.byteRange.length < rhs.byteRange.length {
            return false
        } else {
            return lhs.nameComponentCount < rhs.nameComponentCount
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
