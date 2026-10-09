import Foundation

/// A generic, name-based feature that a language with its own semantic support usually wants
/// switched off for itself (its own providers answer better, and the generic ones add noise).
public enum GenericFeature: String, Sendable, CaseIterable {
    /// ``SnippetCompletionProvider``'s built-in snippets (they are JavaScript-flavored).
    case snippets
    /// ``DuplicateSymbolDiagnosticProvider``.
    case duplicateSymbolDiagnostics
    /// ``SymbolHoverProvider``.
    case symbolHover
    /// ``GoToDefinitionProvider`` and ``FindReferencesProvider``.
    case symbolNavigation
}

/// Which generic features a language opts out of. "Claimed" and "opted out" differ: `http` has no
/// semantic service of its own to speak of, yet it does not want snippets or duplicate-symbol
/// warnings.
public struct LanguagePolicy: Sendable, Equatable {
    public var disabledGenericFeatures: Set<GenericFeature>

    public init(disabling features: Set<GenericFeature> = []) {
        disabledGenericFeatures = features
    }

    public static let none = LanguagePolicy()
}

/// What a ``LanguageService`` contributes. Everything is optional or empty.
///
/// The array-valued members feed the engines (`CompletionEngine`, `HoverEngine`, `DiagnosticEngine`,
/// `NavigationEngine`), which ask every provider and rely on each provider to answer only for its own
/// language (completion and navigation also use `isPrimary(for:)`). The single-valued members are
/// routed by the document's language identifier through ``LanguageServiceRegistry``. The last five
/// (semantic tokens, line markers, structure, type and call hierarchy) are not part of
/// `EditorIntelligenceServices`: the host asks the registry for the owner of a document's language.
public struct LanguageProviders: Sendable {
    public var completion: [any CompletionProvider]
    public var hover: [any HoverProvider]
    public var diagnostics: [any DiagnosticProvider]
    public var navigation: [any NavigationProvider]
    public var formatting: (any FormattingProviding)?
    public var signatureHelp: (any SignatureHelpProviding)?
    public var codeActions: (any CodeActionProviding)?
    public var rename: (any RenameProviding)?
    public var refactoring: (any RefactoringProviding)?
    public var codeGeneration: (any CodeGenerationProviding)?
    public var breadcrumbs: (any BreadcrumbProviding)?
    public var inlayHints: (any InlayHintProviding)?
    public var codeVision: (any CodeVisionProviding)?
    public var semanticTokens: (any SemanticTokenProviding)?
    public var lineMarkers: (any LineMarkerProviding)?
    public var structure: (any StructureProviding)?
    public var typeHierarchy: (any TypeHierarchyProviding)?
    public var callHierarchy: (any CallHierarchyProviding)?

    public init(
        completion: [any CompletionProvider] = [],
        hover: [any HoverProvider] = [],
        diagnostics: [any DiagnosticProvider] = [],
        navigation: [any NavigationProvider] = [],
        formatting: (any FormattingProviding)? = nil,
        signatureHelp: (any SignatureHelpProviding)? = nil,
        codeActions: (any CodeActionProviding)? = nil,
        rename: (any RenameProviding)? = nil,
        refactoring: (any RefactoringProviding)? = nil,
        codeGeneration: (any CodeGenerationProviding)? = nil,
        breadcrumbs: (any BreadcrumbProviding)? = nil,
        inlayHints: (any InlayHintProviding)? = nil,
        codeVision: (any CodeVisionProviding)? = nil,
        semanticTokens: (any SemanticTokenProviding)? = nil,
        lineMarkers: (any LineMarkerProviding)? = nil,
        structure: (any StructureProviding)? = nil,
        typeHierarchy: (any TypeHierarchyProviding)? = nil,
        callHierarchy: (any CallHierarchyProviding)? = nil
    ) {
        self.completion = completion
        self.hover = hover
        self.diagnostics = diagnostics
        self.navigation = navigation
        self.formatting = formatting
        self.signatureHelp = signatureHelp
        self.codeActions = codeActions
        self.rename = rename
        self.refactoring = refactoring
        self.codeGeneration = codeGeneration
        self.breadcrumbs = breadcrumbs
        self.inlayHints = inlayHints
        self.codeVision = codeVision
        self.semanticTokens = semanticTokens
        self.lineMarkers = lineMarkers
        self.structure = structure
        self.typeHierarchy = typeHierarchy
        self.callHierarchy = callHierarchy
    }
}

/// The intelligence for one or more languages, in one place. See `docs/LANGUAGE_SUPPORT_PLAN.md`.
///
/// Several services may claim the same identifier (Java's own providers plus the app's Run actions
/// for Java files); ``LanguageServiceRegistry`` documents how each feature combines them.
public protocol LanguageService: Sendable {
    /// For tracing and tests.
    var name: String { get }
    /// The ``Document/languageIdentifier``s the single-valued providers answer for.
    var languageIdentifiers: Set<String> { get }
    var providers: LanguageProviders { get }
    /// The generic features switched off for ``languageIdentifiers``.
    var policy: LanguagePolicy { get }

    /// Called once when the editor window starts, before any request. Take what the service needs
    /// from `environment` (open buffers, the indent unit, consent). The default does nothing.
    func start(environment: LanguageEnvironment) async

    /// Called when the window closes: drop everything taken from the environment. The default does
    /// nothing.
    func stop() async
}

public extension LanguageService {
    var policy: LanguagePolicy { .none }
    func start(environment: LanguageEnvironment) async {}
    func stop() async {}
}

/// A ``LanguageService`` that is just its values: for a service whose providers already exist (an app
/// bundling instances it constructed) or a small contribution that needs no type of its own.
public struct BasicLanguageService: LanguageService {
    public let name: String
    public let languageIdentifiers: Set<String>
    public let providers: LanguageProviders
    public let policy: LanguagePolicy

    public init(
        name: String,
        languageIdentifiers: Set<String>,
        providers: LanguageProviders,
        policy: LanguagePolicy = .none
    ) {
        self.name = name
        self.languageIdentifiers = languageIdentifiers
        self.providers = providers
        self.policy = policy
    }
}
