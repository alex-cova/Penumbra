import Foundation

/// Classification of a source declaration, used by breadcrumbs, the outline, and method
/// separators to decide what a tree-sitter node represents.
public enum DeclarationKind: String, Sendable, Hashable, CaseIterable {
    case type
    case function
    case property
    case namespace
}

/// Maps a set of tree-sitter node type names to a ``DeclarationKind``.
///
/// This is the per-language analogue of ``TreeSitterIndentationScopes`` — a table of node type
/// strings — but keyed on a language *identifier* (``TextView/languageIdentifier``) rather than
/// attached to a `TreeSitterLanguage`, so a configuration can exist for a language whose grammar
/// isn't bundled (e.g. Java, Swift).
public struct DeclarationRule: Sendable, Hashable {
    /// Node types (or, when ``matchesBySubstring`` is `true`, substrings of node types) that this
    /// rule recognises.
    public var nodeTypes: Set<String>
    /// What a matched node is.
    public var kind: DeclarationKind
    /// Child node types that may hold the declaration's display name, in preference order. The
    /// scanner walks the matched node's direct children and takes the first whose type appears
    /// here. Empty means "no name" (the declaration is still recognised for containment).
    public var nameNodeTypes: [String]
    /// Draw a method separator hairline above this declaration.
    public var isMethodSeparatorAnchor: Bool
    /// Contribute a breadcrumb segment / outline entry for this declaration.
    public var isBreadcrumbSegment: Bool
    /// Treat ``nodeTypes`` as substrings rather than exact matches — used by
    /// ``LanguageConfiguration/generic`` for languages without a dedicated table.
    public var matchesBySubstring: Bool

    public init(
        nodeTypes: Set<String>,
        kind: DeclarationKind,
        nameNodeTypes: [String] = DeclarationRule.defaultNameNodeTypes,
        isMethodSeparatorAnchor: Bool = false,
        isBreadcrumbSegment: Bool = true,
        matchesBySubstring: Bool = false
    ) {
        self.nodeTypes = nodeTypes
        self.kind = kind
        self.nameNodeTypes = nameNodeTypes
        self.isMethodSeparatorAnchor = isMethodSeparatorAnchor
        self.isBreadcrumbSegment = isBreadcrumbSegment
        self.matchesBySubstring = matchesBySubstring
    }

    /// Identifier node types shared by the C-family grammars plus tree-sitter-swift's
    /// `simple_identifier` / `type_identifier`.
    public static let defaultNameNodeTypes = [
        "identifier", "property_identifier", "type_identifier",
        "simple_identifier", "constructor_name", "name"
    ]

    /// Node-type name fragments that mark something as a *declaration* rather than a container,
    /// used to keep substring matching from also matching `class_body`, `function_body`,
    /// `declaration_list`, and the like.
    private static let declarationLikeFragments = [
        "declaration", "definition", "specifier", "declarator", "signature", "_item"
    ]

    /// Whether `nodeType` is recognised by this rule.
    public func matches(nodeType: String) -> Bool {
        guard matchesBySubstring else {
            return nodeTypes.contains(nodeType)
        }
        guard let hit = nodeTypes.first(where: { nodeType.contains($0) }) else {
            return false
        }
        // Exact hint ("class", "function") or a declaration-shaped type ("class_definition"),
        // never a container ("class_body").
        return nodeType == hit || Self.declarationLikeFragments.contains { nodeType.contains($0) }
    }
}

/// Per-language behaviour for features that vary by language: method separators, breadcrumbs, and
/// occurrence highlighting.
///
/// Resolve one for a language identifier with ``LanguageConfigurationRegistry`` (via
/// ``TextView/languageConfigurations``); the text view exposes the resolved value as
/// ``TextView/languageConfiguration``.
public struct LanguageConfiguration: Sendable, Hashable {
    /// Declaration rules, most specific first. The scanner uses the first rule that matches a
    /// node's type.
    public var declarations: [DeclarationRule]
    /// Master switch for the method-separator overlay for this language.
    public var showsMethodSeparators: Bool
    /// Master switch for the breadcrumb bar for this language.
    public var showsBreadcrumbs: Bool
    /// Master switch for highlighting other occurrences of the selection for this language.
    public var highlightsOccurrences: Bool
    /// Shortest selected / word-under-caret term that triggers occurrence highlighting.
    public var minimumOccurrenceLength: Int

    public init(
        declarations: [DeclarationRule],
        showsMethodSeparators: Bool = true,
        showsBreadcrumbs: Bool = true,
        highlightsOccurrences: Bool = true,
        minimumOccurrenceLength: Int = 2
    ) {
        self.declarations = declarations
        self.showsMethodSeparators = showsMethodSeparators
        self.showsBreadcrumbs = showsBreadcrumbs
        self.highlightsOccurrences = highlightsOccurrences
        self.minimumOccurrenceLength = minimumOccurrenceLength
    }

    /// The first rule whose node types match `nodeType`, or `nil`.
    public func rule(forNodeType nodeType: String) -> DeclarationRule? {
        declarations.first { $0.matches(nodeType: nodeType) }
    }
}
