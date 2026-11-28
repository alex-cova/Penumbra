import Foundation

/// A span of an inlay hint's label that leads somewhere when it is ⌘-clicked: a type name that links to
/// its declaration, say.
public struct InlayHintLabelPart: Sendable, Hashable {
    public enum Target: Sendable, Hashable {
        /// A place in a document (an LSP `Location`).
        case location(uri: String, range: LSPRange)
        /// Opaque to the editor: the provider that made the hint resolves it, and runs it, on the click.
        case token(Data)
    }

    /// UTF-16 range inside ``InlayHint/label``.
    public let range: NSRange
    public let target: Target
    public let tooltip: String?

    public init(range: NSRange, target: Target, tooltip: String? = nil) {
        self.range = range
        self.target = target
        self.tooltip = tooltip
    }
}

/// What a click on a label part that carries a token turned out to mean.
public enum InlayHintActivation: Sendable, Equatable {
    /// The provider does not know the token. Nothing happens.
    case unhandled
    /// The provider did what the part asks (ran a server command, say).
    case handled
    /// Go to this place.
    case open(uri: String, range: LSPRange)
}

/// A virtual annotation anchored to a UTF-16 boundary in the document.
public struct InlayHint: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// The name of the parameter an argument is passed to.
        case parameter
        /// The type of a variable declared without one (`var`, an implicit lambda parameter): `: List<String>`.
        case type
        /// An inline (ghost text) completion suggestion, drawn in the editor font with no chip.
        case inlineCompletion
        case other
    }

    public enum Affinity: Sendable, Hashable {
        /// An insertion at the anchor leaves the hint before the inserted text.
        case beforeInsertion
        /// An insertion at the anchor moves the hint after the inserted text.
        case afterInsertion
    }

    /// The UTF-16 boundary in the document.
    public let utf16Offset: Int
    /// The text shown, with any punctuation (`count:`).
    public let label: String
    public let kind: Kind

    public let providerID: String?
    public let symbol: String?
    public let tooltip: String?
    /// A bounded provider token for resolving optional presentation metadata.
    public let resolutionData: Data?
    /// An explicit acceptance action for the document revision that produced this hint.
    public let edits: [TextEdit]
    /// The provider can check for text edits when the user explicitly accepts the hint.
    public let mayResolveEdits: Bool
    public let paddingLeft: Bool
    public let paddingRight: Bool
    public let affinity: Affinity
    /// Spans of ``label`` that ⌘-click follows. Empty for most hints.
    public let parts: [InlayHintLabelPart]

    public init(
        utf16Offset: Int, label: String, kind: Kind = .parameter,
        providerID: String? = nil, symbol: String? = nil, tooltip: String? = nil, resolutionData: Data? = nil,
        edits: [TextEdit] = [], mayResolveEdits: Bool = false,
        affinity: Affinity = .beforeInsertion, paddingLeft: Bool = false, paddingRight: Bool = false,
        parts: [InlayHintLabelPart] = []
    ) {
        self.utf16Offset = utf16Offset
        self.label = label
        self.kind = kind
        self.providerID = providerID
        self.symbol = symbol
        self.tooltip = tooltip
        self.resolutionData = resolutionData
        self.edits = edits
        self.mayResolveEdits = mayResolveEdits
        self.affinity = affinity
        self.paddingLeft = paddingLeft
        self.paddingRight = paddingRight
        // A part outside the label has nothing to point at.
        let length = (label as NSString).length
        self.parts = parts.filter { $0.range.location >= 0 && NSMaxRange($0.range) <= length && $0.range.length > 0 }
    }

    public func anchored(at offset: Int) -> Self {
        Self(
            utf16Offset: offset, label: label, kind: kind, providerID: providerID,
            symbol: symbol, tooltip: tooltip, resolutionData: resolutionData,
            edits: edits, mayResolveEdits: mayResolveEdits, affinity: affinity, paddingLeft: paddingLeft, paddingRight: paddingRight,
            parts: parts
        )
    }
}

/// Supplies the inlay hints for a range of a document.
public protocol InlayHintProviding: Sendable {
    /// The hints whose offsets fall in `range` (a hint at either end is included). A provider
    /// should bound its work, since this runs whenever the visible text changes.
    func inlayHints(for document: Document, in range: TextRange) async -> [InlayHint]
    func resolveInlayTooltip(for hint: InlayHint, in document: Document) async -> String?
    func resolveInlayEdits(for hint: InlayHint, in document: Document) async -> [TextEdit]
    /// A ⌘-click on a label part that carries a token. Runs only for an explicit click.
    func activateInlayHintPart(_ part: InlayHintLabelPart, of hint: InlayHint, in document: Document) async -> InlayHintActivation
}

public extension InlayHintProviding {
    func resolveInlayTooltip(for hint: InlayHint, in document: Document) async -> String? {
        hint.tooltip
    }

    func resolveInlayEdits(for hint: InlayHint, in document: Document) async -> [TextEdit] {
        hint.edits
    }

    func activateInlayHintPart(_ part: InlayHintLabelPart, of hint: InlayHint, in document: Document) async -> InlayHintActivation {
        .unhandled
    }
}
