import Foundation

/// A single, flat block in the rendered markdown preview.
///
/// Nesting (blockquote depth, list item depth) is carried as data on the block/item rather than
/// as recursive structure, so `MarkdownPreviewMetalRenderer`'s tiling — which clips against
/// absolute block frames keyed by array index — keeps working unmodified.
public struct MarkdownPreviewBlock: Sendable, Hashable {
    public var kind: Kind {
        didSet { contentHash = nil }
    }
    /// `0` when the block is not inside a blockquote; `2` for a block inside `>>`, etc.
    public var quoteDepth: Int

    /// `kind.hashValue`, computed once off the main actor by ``MarkdownPreviewDocument/parse(_:)``.
    /// Hashing the attributed text is slow (Unicode normalization of every character), so the
    /// layout's per-block measure cache is keyed by this instead. `nil` until computed, and
    /// again after `kind` changes.
    var contentHash: Int?

    public init(kind: Kind, quoteDepth: Int = 0) {
        self.kind = kind
        self.quoteDepth = quoteDepth
    }

    /// `contentHash`, or the hash computed now for a block that didn't come from `parse`.
    var resolvedContentHash: Int {
        contentHash ?? kind.hashValue
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        if let left = lhs.contentHash, let right = rhs.contentHash, left != right {
            return false
        }
        return lhs.quoteDepth == rhs.quoteDepth && lhs.kind == rhs.kind
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(resolvedContentHash)
        hasher.combine(quoteDepth)
    }

    public enum Kind: Sendable, Hashable {
        case heading(level: Int, text: AttributedString)
        case paragraph(AttributedString)
        case list(MarkdownPreviewList)
        case table(MarkdownPreviewTable)
        case thematicBreak
        case codeBlock(language: String?, source: String)
        case image(alt: String, reference: String)
        case mermaid(source: String)
        case mermaidError(source: String, message: String)
        case footnotes([MarkdownPreviewFootnote])
    }
}

/// A flat, possibly-nested list. `Item.level` (0-based) carries nesting depth instead of the list
/// recursing into sub-lists, matching `MarkdownPreviewBlock`'s flat-block design.
public struct MarkdownPreviewList: Sendable, Hashable {
    public var items: [Item]

    public init(items: [Item] = []) {
        self.items = items
    }

    public struct Item: Sendable, Hashable {
        public var text: AttributedString
        public var level: Int
        public var marker: Marker

        public init(text: AttributedString, level: Int, marker: Marker) {
            self.text = text
            self.level = level
            self.marker = marker
        }
    }

    public enum Marker: Sendable, Hashable {
        case bullet
        case ordered(Int)
        case task(checked: Bool)
    }
}

/// One entry in the trailing "Footnotes" section: `number` is the resolved, first-reference-order
/// display number (not necessarily the source order of `[^label]:` definitions), `label` is the
/// original `[^label]` text for diagnostics, and `text` is the parsed, inline-styled body with any
/// footnote references it itself contains already substituted.
public struct MarkdownPreviewFootnote: Sendable, Hashable {
    public var number: Int
    public var label: String
    public var text: AttributedString

    public init(number: Int, label: String, text: AttributedString) {
        self.number = number
        self.label = label
        self.text = text
    }
}

/// A GFM pipe table with per-column alignment. Rows are padded to `columns.count` so a ragged
/// source row never produces an out-of-bounds cell lookup at layout/paint time.
public struct MarkdownPreviewTable: Sendable, Hashable {
    public var columns: [Column]
    public var header: [AttributedString]
    public var rows: [[AttributedString]]

    public init(columns: [Column] = [], header: [AttributedString] = [], rows: [[AttributedString]] = []) {
        self.columns = columns
        self.header = header
        self.rows = rows
    }

    public struct Column: Sendable, Hashable {
        public enum Alignment: Sendable, Hashable {
            case leading, center, trailing
        }

        public var alignment: Alignment

        public init(alignment: Alignment) {
            self.alignment = alignment
        }
    }
}

/// Parsed markdown ready for layout and painting.
public struct MarkdownPreviewDocument: Sendable, Hashable {
    public var blocks: [MarkdownPreviewBlock]

    public init(blocks: [MarkdownPreviewBlock] = []) {
        self.blocks = blocks
    }

    /// Parses GFM-ish markdown into preview blocks. Footnote definitions (`[^1]: ...`) are
    /// extracted first, from the raw source, since Foundation's markdown parser has no concept of
    /// footnotes at all and would otherwise mangle them (see ``MarkdownPreviewFootnotes``). Mermaid
    /// fences are extracted next (so they never reach Foundation's parser, which would otherwise
    /// just see an ordinary code fence); everything else is walked from Foundation's
    /// `PresentationIntent` tree by ``MarkdownPreviewIntentWalker``. Once every block is built,
    /// inline `[^1]` references are renumbered by first-reference order and a trailing
    /// `.footnotes` block is appended if any definitions were found.
    ///
    /// Pass the same `cache` to successive parses of an edited buffer to re-parse only the
    /// prose that changed (see ``MarkdownPreviewParseCache``).
    public static func parse(_ source: String, cache: MarkdownPreviewParseCache? = nil) -> MarkdownPreviewDocument {
        let cache = cache ?? MarkdownPreviewParseCache()
        cache.begin()
        defer { cache.end() }
        let (strippedSource, footnoteDefinitions) = MarkdownPreviewFootnotes.extract(from: source)
        let linkDefinitions = MarkdownPreviewIntentWalker.linkReferenceDefinitions(in: strippedSource)
        var blocks: [MarkdownPreviewBlock] = []
        for segment in MermaidFenceExtractor.segments(in: strippedSource) {
            switch segment {
            case .prose(let prose):
                for chunk in MarkdownPreviewParseCache.chunks(of: prose) {
                    blocks.append(contentsOf: cache.blocks(forChunk: chunk, linkDefinitions: linkDefinitions))
                }
            case .fencedCode(let language, let body):
                if MermaidFenceExtractor.isMermaidFence(language) {
                    blocks.append(MarkdownPreviewBlock(kind: .mermaid(source: body)))
                } else {
                    blocks.append(MarkdownPreviewBlock(kind: .codeBlock(language: language, source: body)))
                }
            }
        }

        let (numberedBlocks, footnotes) = MarkdownPreviewFootnotes.numberReferences(in: blocks, definitions: footnoteDefinitions)
        blocks = numberedBlocks
        if !footnotes.isEmpty {
            blocks.append(MarkdownPreviewBlock(kind: .thematicBreak))
            blocks.append(MarkdownPreviewBlock(kind: .footnotes(footnotes)))
        }
        // Chunk blocks come hashed; this covers fences, footnotes and blocks whose text footnote
        // numbering rewrote.
        for index in blocks.indices where blocks[index].contentHash == nil {
            blocks[index].contentHash = blocks[index].kind.hashValue
        }
        return MarkdownPreviewDocument(blocks: blocks)
    }

    /// Accessibility text for each block, in document order.
    public var accessibilityDescriptions: [String] {
        blocks.map { block in
            let prefix = block.quoteDepth > 0 ? "Quote level \(block.quoteDepth): " : ""
            switch block.kind {
            case .heading(let level, let text):
                return "\(prefix)Heading \(level): \(String(text.characters))"
            case .paragraph(let text):
                return "\(prefix)\(String(text.characters))"
            case .list(let list):
                let items = list.items.map { item -> String in
                    switch item.marker {
                    case .task(let checked):
                        return "\(checked ? "Checked" : "Unchecked"): \(String(item.text.characters))"
                    case .bullet, .ordered:
                        return String(item.text.characters)
                    }
                }
                return "\(prefix)\(items.joined(separator: ", "))"
            case .table(let table):
                let header = table.header.map { String($0.characters) }.joined(separator: ", ")
                return "\(prefix)Table: \(header)"
            case .thematicBreak:
                return "Thematic break"
            case .codeBlock(_, let source):
                return "Code block: \(source)"
            case .image(let alt, let reference):
                return alt.isEmpty ? "Image: \(reference)" : alt
            case .mermaid(let source), .mermaidError(let source, _):
                return "Mermaid diagram: \(source)"
            case .footnotes(let footnotes):
                let entries = footnotes.map { "\($0.number). \(String($0.text.characters))" }
                return "Footnotes: \(entries.joined(separator: ", "))"
            }
        }
    }
}
