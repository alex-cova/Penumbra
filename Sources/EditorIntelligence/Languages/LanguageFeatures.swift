import Foundation

// The language features that had no generic protocol while Java was the only language with them:
// semantic colours, gutter markers, the Structure outline and the type and call hierarchies. Each
// is a small protocol over plain values so a host draws them without knowing the language; a
// language fills them through `LanguageProviders` and `LanguageServiceRegistry` hands the host the
// provider that owns a document's language. Offsets are UTF-16 unless stated.

// MARK: - Semantic highlighting

/// One identifier's colour class: a UTF-16 range and the theme's highlight name for it
/// (`"type.class"`, `"function.call"`, …).
public struct SemanticHighlight: Sendable, Hashable {
    public let range: Range<Int>
    public let highlightName: String

    public init(range: Range<Int>, highlightName: String) {
        self.range = range
        self.highlightName = highlightName
    }
}

public protocol SemanticTokenProviding: Sendable {
    /// The highlights of `source` in position order, or nil when cancelled or the source cannot be
    /// analysed. Runs off the main actor; the host drops the result if the text moved on.
    func semanticHighlights(forSource source: String) async -> [SemanticHighlight]?
}

// MARK: - Gutter line markers

/// What a line marker says about a declaration. The six kinds are object-oriented concepts any
/// class-based language has; a host maps each to an icon and a click action.
public enum LineMarkerKind: String, CaseIterable, Hashable, Sendable {
    /// A method that implements an abstract or interface method (↑).
    case implementing
    /// A method that overrides a concrete method (↑).
    case overriding
    /// An abstract or interface method, or an interface, that project types implement (↓).
    case implemented
    /// A concrete method that project subclasses override, or a class they extend (↓).
    case overridden
    /// A method that implements an interface method on behalf of a subclass that inherits it (↕).
    case siblingInherited
    /// A call to the method it sits in.
    case recursiveCall
}

public struct LineMarker: Sendable {
    public let kind: LineMarkerKind
    /// 1-based line, counted as the editor counts them (`\r\n` is one break).
    public let line: Int
    /// UTF-16 offset of the declaration or call name; Go to Super Method or Go to Implementation
    /// resolved here lands where the marker points.
    public let anchorUTF16Offset: Int
    public let tooltip: String
    /// The provider's own record of the marker, handed back to ``LineMarkerProviding/siblingTargets(of:source:fileURL:documentID:)``.
    public let payload: (any Sendable)?

    public init(kind: LineMarkerKind, line: Int, anchorUTF16Offset: Int, tooltip: String, payload: (any Sendable)? = nil) {
        self.kind = kind
        self.line = line
        self.anchorUTF16Offset = anchorUTF16Offset
        self.tooltip = tooltip
        self.payload = payload
    }
}

public protocol LineMarkerProviding: Sendable {
    /// The markers of `kinds` in `source`, ordered by line, or nil when cancelled or unparsable.
    func lineMarkers(source: String, fileURL: URL?, kinds: Set<LineMarkerKind>) async -> [LineMarker]?

    /// Where a ``LineMarkerKind/siblingInherited`` marker leads. `documentID` stands for a target in
    /// `fileURL` itself.
    func siblingTargets(of marker: LineMarker, source: String, fileURL: URL?, documentID: DocumentID) async -> [Location]
}

// MARK: - Structure

public enum StructureKind: String, Sendable {
    case type
    case field
    case method
    case constructor
    case enumConstant
    case recordComponent
}

/// One row of the Structure outline: a declaration with its members.
public struct StructureNode: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let kind: StructureKind
    /// The declaration's name, for jumping the caret to it.
    public let nameRange: Range<Int>
    /// The whole declaration, for finding the member the caret is in.
    public let bodyRange: Range<Int>
    public let children: [StructureNode]

    public init(
        id: String, title: String, kind: StructureKind,
        nameRange: Range<Int>, bodyRange: Range<Int>, children: [StructureNode] = []
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.nameRange = nameRange
        self.bodyRange = bodyRange
        self.children = children
    }

    /// The deepest node under `self` (itself included) whose body holds `offset`, or `self`.
    public func deepestNode(containing offset: Int) -> StructureNode {
        var best = self
        func visit(_ node: StructureNode) {
            guard node.bodyRange.contains(offset) || node.bodyRange.upperBound == offset else { return }
            best = node
            for child in node.children { visit(child) }
        }
        visit(self)
        return best
    }

    /// The nodes from a root down to the one whose name starts at `offset`, if any.
    public static func path(toNameAt offset: Int, in nodes: [StructureNode]) -> [StructureNode]? {
        for node in nodes {
            if node.nameRange.lowerBound == offset { return [node] }
            if node.bodyRange.contains(offset), let rest = path(toNameAt: offset, in: node.children) {
                return [node] + rest
            }
        }
        return nil
    }
}

public protocol StructureProviding: Sendable {
    /// The innermost type at `utf16Offset` with its members as children (the first top-level type when
    /// the caret is outside every body); nil when there is none or the source does not parse.
    func structure(forSource source: String, atUTF16Offset utf16Offset: Int) async -> StructureNode?

    /// Every top-level type of `source` with its members; nil when it does not parse.
    func allStructure(forSource source: String) async -> [StructureNode]?
}

// MARK: - Hierarchies

public enum HierarchyItemKind: Sendable, Hashable {
    case classType
    case interfaceType
    case enumType
    case recordType
    case annotationType
    case method
}

/// Where a hierarchy item comes from, which decides how it is drawn and whether it can be opened.
public enum HierarchyOrigin: Sendable, Hashable {
    /// The project's own sources.
    case project
    /// A dependency.
    case library
    /// The language runtime or standard library.
    case runtime
    /// A call-hierarchy item that several overloads or receivers could be.
    case ambiguous
}

/// One row of a type or call hierarchy. The tree is built lazily: ask the provider for an item's
/// supertypes, subtypes, callers or callees when it is expanded.
public struct HierarchyItem: Sendable, Hashable, Identifiable {
    /// Unique within one tree: the path from the root down to this item.
    public let id: String
    public let name: String
    /// Package or declaring type, shown after the name.
    public let detail: String
    public let kind: HierarchyItemKind
    public let origin: HierarchyOrigin
    /// A short tag drawn after the row for items that are not the project's (`"jar"`, `"JDK"`), in the
    /// language's own words; nil for none.
    public let badge: String?
    /// The provider's own record, handed back to it. Not part of equality.
    public let payload: (any Sendable)?

    public init(
        id: String, name: String, detail: String = "", kind: HierarchyItemKind,
        origin: HierarchyOrigin, badge: String? = nil, payload: (any Sendable)? = nil
    ) {
        self.id = id
        self.name = name
        self.detail = detail
        self.kind = kind
        self.origin = origin
        self.badge = badge
        self.payload = payload
    }

    public static func == (lhs: HierarchyItem, rhs: HierarchyItem) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.detail == rhs.detail
            && lhs.kind == rhs.kind && lhs.origin == rhs.origin && lhs.badge == rhs.badge
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

/// Where a hierarchy item is declared, ready to open.
public struct HierarchyLocation: Sendable, Equatable {
    public let url: URL?
    public let range: TextRange

    public init(url: URL?, range: TextRange) {
        self.url = url
        self.range = range
    }
}

public protocol TypeHierarchyProviding: Sendable {
    /// The type at `utf16Offset` of `source`, else the type the caret is inside; nil outside a type.
    func rootItem(source: String, fileURL: URL?, utf16Offset: Int) async -> HierarchyItem?
    func supertypes(of item: HierarchyItem, file: URL?) async -> [HierarchyItem]
    /// The project's own subtypes; a scan, so only for an explicit request.
    func subtypes(of item: HierarchyItem, file: URL?) async -> [HierarchyItem]
    func location(of item: HierarchyItem, file: URL?) async -> HierarchyLocation?
}

public protocol CallHierarchyProviding: Sendable {
    /// The method at `utf16Offset` of `source`; nil when there is none.
    func rootItem(source: String, fileURL: URL?, utf16Offset: Int) async -> HierarchyItem?
    func callers(of item: HierarchyItem, file: URL?) async -> [HierarchyItem]
    func callees(of item: HierarchyItem, file: URL?) async -> [HierarchyItem]
    func location(of item: HierarchyItem, file: URL?) async -> HierarchyLocation?
}
