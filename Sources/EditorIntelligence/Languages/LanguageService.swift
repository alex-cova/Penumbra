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
    public var methodHierarchy: (any MethodHierarchyProviding)?
    public var symbolReference: (any SymbolReferenceProviding)?

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
        callHierarchy: (any CallHierarchyProviding)? = nil,
        methodHierarchy: (any MethodHierarchyProviding)? = nil,
        symbolReference: (any SymbolReferenceProviding)? = nil
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
        self.methodHierarchy = methodHierarchy
        self.symbolReference = symbolReference
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
    /// Syntactic services are the fallback. A semantic service is asked first while it is ready.
    var tier: LanguageServiceTier { get }

    /// `nil` means "derive from ``tier``".
    func fidelity(of feature: LanguageFeature) -> FeatureFidelity?
    /// Features this service will not answer yet. Empty means ready. A property, not a method:
    /// the registry lives in this module, and a method with a default implementation is not
    /// dispatched to the conforming type from here.
    var unavailableFeatures: Set<LanguageFeature> { get }
    /// One request the conformance test cancels. A property for the same reason as
    /// ``unavailableFeatures``: a defaulted method would not reach an override. The default
    /// returns `false` as soon as the task is cancelled, and no result before that.
    var cancellableRequest: @Sendable () async -> Bool { get }
    /// Read on every request, so this must not await. The default is ready.
    func isReady(for feature: LanguageFeature) -> Bool

    /// Called once when the editor window starts, before any request. Take what the service needs
    /// from `environment` (open buffers, the indent unit, consent). The default does nothing.
    func start(environment: LanguageEnvironment) async

    /// The window's folder changed, or closed (`root` is nil). Retarget project-wide state at it.
    ///
    /// Synchronous and on the main actor, unlike `start` and `stop`: the host calls it from code that
    /// reads the result straight away (the file tree, the status bar, the next service's decision),
    /// and an `async` registry call would let a later read run before the change. A service that has
    /// slow work to do starts a task here and returns. The default does nothing.
    @MainActor func projectDidChange(root: URL?)

    /// Files under the project changed on disk (a pull, a build, another program), already batched by
    /// the host's watcher. Same rules as ``projectDidChange(root:)``. The default does nothing.
    @MainActor func filesDidChange(_ urls: [URL])

    /// The host calls this after a save. A semantic service refreshes pushed diagnostics here.
    @MainActor func documentsDidSave(_ urls: [URL])

    /// Called when the window closes: drop everything taken from the environment. The default does
    /// nothing.
    func stop() async
}

/// How complete a service's answers are. A syntactic service is always available. A semantic one
/// answers only while ``LanguageService/isReady(for:)`` is true; the registry falls through to the
/// lower tier until then.
public enum LanguageServiceTier: Int, Comparable, Sendable {
    case syntactic = 1
    case semantic = 2

    public static func < (lhs: LanguageServiceTier, rhs: LanguageServiceTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A feature the registry can route. The set is the matrix in `docs/LANGUAGE_PARITY_PLAN.md`.
public enum LanguageFeature: String, CaseIterable, Sendable {
    case completion, hover, signatureHelp, definition, implementation, typeDefinition, references
    case superMethod, rename, refactoring, codeActions, formatting, diagnostics, semanticTokens
    case inlayHints, codeVision, structure, breadcrumbs, lineMarkers, typeHierarchy, callHierarchy
    case codeGeneration, symbolReference, methodHierarchy
}

/// How accurate a feature's answer is. `nil` from ``LanguageService/fidelity(of:)`` means the
/// registry derives it from the service's tier.
public enum FeatureFidelity: Int, Comparable, Sendable {
    case syntactic, semantic, compiler

    public static func < (lhs: FeatureFidelity, rhs: FeatureFidelity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public extension LanguageService {
    var policy: LanguagePolicy { .none }
    var tier: LanguageServiceTier { .syntactic }

    /// `nil` means "derive from ``tier``". A service that has no provider for `feature` is absent
    /// from the capability report whether or not this returns a value.
    func fidelity(of feature: LanguageFeature) -> FeatureFidelity? { nil }

    var unavailableFeatures: Set<LanguageFeature> { [] }

    var cancellableRequest: @Sendable () async -> Bool {
        {
            while !Task.isCancelled {
                await Task.yield()
            }
            return false
        }
    }

    /// Read on every request, so this must not await. The default follows ``unavailableFeatures``.
    func isReady(for feature: LanguageFeature) -> Bool { !unavailableFeatures.contains(feature) }

    func start(environment: LanguageEnvironment) async {}
    @MainActor func projectDidChange(root: URL?) {}
    @MainActor func filesDidChange(_ urls: [URL]) {}

    /// The host calls this after a save, on the main actor. A semantic service refreshes pushed
    /// diagnostics here. The default does nothing.
    @MainActor func documentsDidSave(_ urls: [URL]) {}

    func stop() async {}
}

/// Who answers one feature for one language, and at what fidelity.
public struct LanguageFeatureOwner: Sendable, Equatable {
    public var service: String
    public var fidelity: FeatureFidelity

    public init(service: String, fidelity: FeatureFidelity) {
        self.service = service
        self.fidelity = fidelity
    }
}

/// The features a language can answer right now, one owner each. Diagnostics are the exception:
/// every ready tier contributes, and this report names the highest.
public struct LanguageCapabilityReport: Sendable, Equatable {
    public var features: [LanguageFeature: LanguageFeatureOwner]

    public init(features: [LanguageFeature: LanguageFeatureOwner] = [:]) {
        self.features = features
    }
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
