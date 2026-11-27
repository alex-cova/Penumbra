import Foundation

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

    public init(
        utf16Offset: Int, label: String, kind: Kind = .parameter,
        providerID: String? = nil, symbol: String? = nil, tooltip: String? = nil, resolutionData: Data? = nil,
        edits: [TextEdit] = [], mayResolveEdits: Bool = false,
        affinity: Affinity = .beforeInsertion, paddingLeft: Bool = false, paddingRight: Bool = false
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
    }

    public func anchored(at offset: Int) -> Self {
        Self(
            utf16Offset: offset, label: label, kind: kind, providerID: providerID,
            symbol: symbol, tooltip: tooltip, resolutionData: resolutionData,
            edits: edits, mayResolveEdits: mayResolveEdits, affinity: affinity, paddingLeft: paddingLeft, paddingRight: paddingRight
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
}

public extension InlayHintProviding {
    func resolveInlayTooltip(for hint: InlayHint, in document: Document) async -> String? {
        hint.tooltip
    }

    func resolveInlayEdits(for hint: InlayHint, in document: Document) async -> [TextEdit] {
        hint.edits
    }
}
