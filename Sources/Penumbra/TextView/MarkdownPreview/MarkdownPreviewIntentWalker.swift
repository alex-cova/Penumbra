import Foundation

/// Walks Foundation's `PresentationIntent` tree (from `.full` markdown parsing) into Penumbra's
/// flat ``MarkdownPreviewBlock`` list.
///
/// `PresentationIntent.components` is ordered innermost-first (e.g. a table cell's chain is
/// `[tableCell, tableHeaderRow, table]`). This walker groups consecutive `AttributedString` runs
/// that share the same *innermost* component identity into one "leaf span" — one heading,
/// paragraph, list item, table cell, or code block's worth of text — then folds each leaf into
/// the growing block list, keeping a list/table "open" across leaves that share the same
/// *outermost* list/table identity so a nested list or a multi-row table stays one flat block.
enum MarkdownPreviewIntentWalker {
    /// Scans the whole document (not just one segment) for link reference definitions
    /// (`[ref]: url "title"`) and returns them as a block of lines to append to every per-segment
    /// parse. `.full` parsing only sees one prose segment at a time (`MermaidFenceExtractor`
    /// already split fences out), so a definition that appears after a fence would otherwise never
    /// reach the prose segments before it.
    static func linkReferenceDefinitions(in source: String) -> String {
        // `(?!\^)` excludes footnote definitions (`[^1]: ...`), which `MarkdownPreviewFootnotes`
        // extracts and handles separately — without it this class would also match a `[^1]:` line,
        // since `^` right after `[` is just a literal caret to `[^\]]`, not a negated class.
        guard let regex = try? NSRegularExpression(
            pattern: #"^\[(?!\^)[^\]]+\]:[ \t]*\S+.*$"#,
            options: [.anchorsMatchLines]
        ) else {
            return ""
        }
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
        return matches.map { ns.substring(with: $0.range) }.joined(separator: "\n")
    }

    /// Parses one prose segment (markdown source with any top-level fenced code already removed)
    /// into blocks.
    static func blocks(in prose: String, linkDefinitions: String) -> [MarkdownPreviewBlock] {
        let trimmed = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let source = linkDefinitions.isEmpty ? trimmed : trimmed + "\n\n" + linkDefinitions
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .full
        options.allowsExtendedAttributes = true
        options.failurePolicy = .returnPartiallyParsedIfPossible

        guard let attributed = try? AttributedString(markdown: source, options: options) else {
            return [MarkdownPreviewBlock(kind: .paragraph(AttributedString(trimmed)))]
        }
        return build(from: attributed)
    }

    // MARK: - Leaf spans

    /// One contiguous run of `AttributedString` text sharing a single innermost
    /// `PresentationIntent` component identity — a heading's text, a paragraph, a list item, a
    /// table cell, or a code block's body.
    private struct LeafSpan {
        /// Innermost-first component chain, as reported for the span's first run.
        var chain: [PresentationIntent.IntentType]
        var text: AttributedString
    }

    private static func leafSpans(in attributed: AttributedString) -> [LeafSpan] {
        var spans: [LeafSpan] = []
        var currentIdentity: Int?
        var currentChain: [PresentationIntent.IntentType] = []
        var spanStart: AttributedString.Index?
        var spanEnd: AttributedString.Index?

        func closeSpan() {
            guard let start = spanStart, let end = spanEnd else { return }
            spans.append(LeafSpan(chain: currentChain, text: AttributedString(attributed[start..<end])))
            spanStart = nil
        }

        for run in attributed.runs {
            let identity = run.presentationIntent?.components.first?.identity
            if identity != currentIdentity {
                closeSpan()
                currentIdentity = identity
                currentChain = run.presentationIntent?.components ?? []
                spanStart = run.range.lowerBound
            }
            spanEnd = run.range.upperBound
        }
        closeSpan()
        return spans
    }

    // MARK: - Chain helpers

    private static func quoteDepth(in chain: [PresentationIntent.IntentType]) -> Int {
        chain.reduce(0) { count, component in
            if case .blockQuote = component.kind { return count + 1 }
            return count
        }
    }

    private static func isListKind(_ kind: PresentationIntent.Kind) -> Bool {
        switch kind {
        case .orderedList, .unorderedList: return true
        default: return false
        }
    }

    /// All list-kind components in the chain, innermost first; `.last` is the outermost list this
    /// leaf ultimately belongs to, which is what groups nested-list leaves into one flat block.
    private static func listComponents(in chain: [PresentationIntent.IntentType]) -> [PresentationIntent.IntentType] {
        chain.filter { isListKind($0.kind) }
    }

    private static func tableComponent(in chain: [PresentationIntent.IntentType]) -> PresentationIntent.IntentType? {
        chain.first {
            if case .table = $0.kind { return true }
            return false
        }
    }

    private static func rowComponent(in chain: [PresentationIntent.IntentType]) -> (isHeader: Bool, rowIndex: Int)? {
        for component in chain {
            switch component.kind {
            case .tableHeaderRow: return (true, 0)
            case .tableRow(let rowIndex): return (false, rowIndex)
            default: continue
            }
        }
        return nil
    }

    private static func tableColumns(from kind: PresentationIntent.Kind) -> [MarkdownPreviewTable.Column] {
        guard case .table(let columns) = kind else { return [] }
        return columns.map { column in
            let alignment: MarkdownPreviewTable.Column.Alignment
            switch column.alignment {
            case .left: alignment = .leading
            case .center: alignment = .center
            case .right: alignment = .trailing
            @unknown default: alignment = .leading
            }
            return MarkdownPreviewTable.Column(alignment: alignment)
        }
    }

    // MARK: - Image / task-list detection

    /// A paragraph whose entire content is a single image run (`![alt](ref)`, possibly with a
    /// title) becomes an `.image` block, matching the scope of the parser this replaces.
    private static func imageKind(from text: AttributedString) -> MarkdownPreviewBlock.Kind? {
        let runs = Array(text.runs)
        guard runs.count == 1, let url = runs[0].imageURL else { return nil }
        return .image(alt: String(text.characters), reference: url.absoluteString)
    }

    /// GFM task-list marker: a `[ ] `/`[x] `/`[X] ` prefix at the very start of an item's text.
    /// Returns the marker and, for a task item, the text with the prefix stripped (preserving the
    /// remaining inline attributes).
    private static func marker(
        for kind: PresentationIntent.Kind,
        ordinal: Int,
        text: AttributedString
    ) -> (marker: MarkdownPreviewList.Marker, text: AttributedString) {
        let characters = text.characters
        if characters.count >= 4 {
            let prefix = String(characters.prefix(4))
            let lowered = prefix.lowercased()
            if lowered == "[ ] " || lowered == "[x] " {
                let cut = characters.index(characters.startIndex, offsetBy: 4)
                return (.task(checked: lowered == "[x] "), AttributedString(text[cut...]))
            }
        }
        if case .orderedList = kind {
            return (.ordered(ordinal), text)
        }
        return (.bullet, text)
    }

    // MARK: - Block assembly

    private struct PendingList {
        let identity: Int
        let quoteDepth: Int
        var list: MarkdownPreviewList
    }

    private struct PendingTable {
        let identity: Int
        let quoteDepth: Int
        var table: MarkdownPreviewTable
    }

    private static func build(from attributed: AttributedString) -> [MarkdownPreviewBlock] {
        var blocks: [MarkdownPreviewBlock] = []
        var pendingList: PendingList?
        var pendingTable: PendingTable?

        func flushList() {
            if let pendingList {
                blocks.append(MarkdownPreviewBlock(kind: .list(pendingList.list), quoteDepth: pendingList.quoteDepth))
            }
            pendingList = nil
        }
        func flushTable() {
            if let pendingTable {
                // `appendCell` only pads a row/header up to the highest column index the parser
                // actually emitted a cell for; a genuinely ragged source row (fewer `|`-delimited
                // cells than the header) never gets a `tableCell` intent for its missing columns
                // at all, so pad every row up to the full column count here.
                var table = pendingTable.table
                let columnCount = table.columns.count
                for index in table.rows.indices {
                    while table.rows[index].count < columnCount {
                        table.rows[index].append(AttributedString())
                    }
                }
                while table.header.count < columnCount {
                    table.header.append(AttributedString())
                }
                blocks.append(MarkdownPreviewBlock(kind: .table(table), quoteDepth: pendingTable.quoteDepth))
            }
            pendingTable = nil
        }

        for span in leafSpans(in: attributed) {
            guard let leaf = span.chain.first else {
                flushList()
                flushTable()
                blocks.append(MarkdownPreviewBlock(kind: .paragraph(span.text)))
                continue
            }
            let depth = quoteDepth(in: span.chain)

            switch leaf.kind {
            case .header(let level):
                flushList()
                flushTable()
                blocks.append(MarkdownPreviewBlock(kind: .heading(level: level, text: span.text), quoteDepth: depth))

            case .thematicBreak:
                flushList()
                flushTable()
                blocks.append(MarkdownPreviewBlock(kind: .thematicBreak, quoteDepth: depth))

            case .codeBlock(let hint):
                flushList()
                flushTable()
                var source = String(span.text.characters)
                if source.hasSuffix("\n") { source.removeLast() }
                blocks.append(MarkdownPreviewBlock(kind: .codeBlock(language: hint, source: source), quoteDepth: depth))

            case .tableCell(let columnIndex):
                flushList()
                guard let table = tableComponent(in: span.chain), let row = rowComponent(in: span.chain) else {
                    blocks.append(MarkdownPreviewBlock(kind: .paragraph(span.text), quoteDepth: depth))
                    continue
                }
                if pendingTable?.identity != table.identity {
                    flushTable()
                    pendingTable = PendingTable(
                        identity: table.identity,
                        quoteDepth: depth,
                        table: MarkdownPreviewTable(columns: tableColumns(from: table.kind))
                    )
                }
                if var pending = pendingTable {
                    appendCell(text: span.text, columnIndex: columnIndex, row: row, into: &pending.table)
                    pendingTable = pending
                }

            case .paragraph:
                if span.chain.count > 1, case .listItem(let ordinal) = span.chain[1].kind,
                   span.chain.count > 2, isListKind(span.chain[2].kind) {
                    flushTable()
                    let directList = span.chain[2]
                    let outermost = listComponents(in: span.chain).last ?? directList
                    if pendingList?.identity != outermost.identity {
                        flushList()
                        pendingList = PendingList(identity: outermost.identity, quoteDepth: depth, list: MarkdownPreviewList())
                    }
                    let level = max(listComponents(in: span.chain).count - 1, 0)
                    let (itemMarker, itemText) = marker(for: directList.kind, ordinal: ordinal, text: span.text)
                    pendingList?.list.items.append(MarkdownPreviewList.Item(text: itemText, level: level, marker: itemMarker))
                } else {
                    flushList()
                    flushTable()
                    if let image = imageKind(from: span.text) {
                        blocks.append(MarkdownPreviewBlock(kind: image, quoteDepth: depth))
                    } else {
                        blocks.append(MarkdownPreviewBlock(kind: .paragraph(span.text), quoteDepth: depth))
                    }
                }

            default:
                // A container kind reported as its own leaf — not expected from `.full` parsing,
                // but degrade to a paragraph rather than silently dropping the text.
                flushList()
                flushTable()
                blocks.append(MarkdownPreviewBlock(kind: .paragraph(span.text), quoteDepth: depth))
            }
        }

        flushList()
        flushTable()
        return blocks
    }

    private static func appendCell(
        text: AttributedString,
        columnIndex: Int,
        row: (isHeader: Bool, rowIndex: Int),
        into table: inout MarkdownPreviewTable
    ) {
        if row.isHeader {
            while table.header.count <= columnIndex {
                table.header.append(AttributedString())
            }
            table.header[columnIndex] = text
        } else {
            let rowIndex = max(0, row.rowIndex - 1) // `tableRow(rowIndex:)` is 1-based (header is separate).
            while table.rows.count <= rowIndex {
                table.rows.append([])
            }
            while table.rows[rowIndex].count <= columnIndex {
                table.rows[rowIndex].append(AttributedString())
            }
            table.rows[rowIndex][columnIndex] = text
        }
    }
}
