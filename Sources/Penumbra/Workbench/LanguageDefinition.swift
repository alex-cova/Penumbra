import Foundation

/// Everything the editor needs to know about a language that is not intelligence: its identifier,
/// the files and Markdown fences that mean it, its grammar, and how it appears in menus.
///
/// Register one with ``LanguageDefinitionRegistry/register(_:)`` and every lookup follows:
/// ``LanguageIdentifier`` (extension and file name → identifier), ``FenceLanguageName`` (fence tag →
/// name), the grammar (``LanguageDefinitionRegistry/grammar(forIdentifier:)``, which `PenumbraLanguages`'
/// `BundledLanguages` reads), ``LanguageConfigurationRegistry/builtIns`` and, with
/// ``isSelectable``, the host's Set Syntax menu. The bundled languages are definitions too
/// (``builtIns``).
///
/// Identifiers are lowercase strings (`"rust"`, `"graphql"`) and are what ``TextView/languageIdentifier``
/// and `Document.languageIdentifier` carry. See `docs/ADDING_A_LANGUAGE.md`.
public struct LanguageDefinition: Sendable {
    /// The identifier documents of this language carry.
    public var id: String
    /// The name shown in menus and the status bar (`"Shell Script"`).
    public var displayName: String
    /// File extensions without the dot, matched case-insensitively. `""` matches files without one.
    /// When several definitions claim an extension, the one registered last wins.
    public var fileExtensions: [String]
    /// Full file names for files whose extension says nothing (`".zshrc"`), matched case-insensitively
    /// before the extension.
    public var fileNames: [String]
    /// Other identifiers that mean this language (`"bash"`, `"sh"` for `"shell"`): grammar and
    /// definition lookups accept them. They do not change what ``LanguageIdentifier`` returns.
    public var aliases: [String]
    /// Tags that may follow a Markdown code fence (` ```rs `), matched case-insensitively. They
    /// normalize to ``fenceName`` (default ``id``).
    public var fenceAliases: [String]
    /// The name a fence tag normalizes to, when it differs from ``id`` (shell fences become `"bash"`).
    public var fenceName: String?
    /// Method separators, breadcrumb and sticky-line rules; nil leaves the generic configuration.
    public var configuration: LanguageConfiguration?
    /// Whether a host's Set Syntax menu lists it. Meaningful only for languages that highlight
    /// something; a definition kept for identity only (`"csv"`) leaves it off.
    public var isSelectable: Bool
    /// The tree-sitter grammar, or nil for a language without one. Registering a definition installs
    /// it as the grammar of ``id``, replacing an earlier one.
    public var grammar: (@Sendable () -> TreeSitterLanguage?)?

    public init(
        id: String,
        displayName: String,
        fileExtensions: [String] = [],
        fileNames: [String] = [],
        aliases: [String] = [],
        fenceAliases: [String] = [],
        fenceName: String? = nil,
        configuration: LanguageConfiguration? = nil,
        isSelectable: Bool = false,
        grammar: (@Sendable () -> TreeSitterLanguage?)? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.fileExtensions = fileExtensions
        self.fileNames = fileNames
        self.aliases = aliases
        self.fenceAliases = fenceAliases
        self.fenceName = fenceName
        self.configuration = configuration
        self.isSelectable = isSelectable
        self.grammar = grammar
    }
}
