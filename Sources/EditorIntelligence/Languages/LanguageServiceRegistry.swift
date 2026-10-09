import Foundation

/// The language services of one editor, with the lookups the engines and the controller need.
///
/// Immutable after construction, so it is cheap to copy into providers and safe to read from any
/// thread. Routing is a dictionary lookup by language identifier: nothing here scans services per
/// keystroke.
///
/// **Combining services that claim one language** (order is the order given to ``init(services:)``):
/// - engine providers (completion, hover, diagnostics, navigation): all of them, in service order;
/// - code actions: every service's actions, concatenated;
/// - formatting: the first service whose provider ``FormattingProviding/supportsFormatting(_:)``;
/// - signature help: the first non-nil answer;
/// - rename, refactoring, code generation, breadcrumbs, inlay hints, code vision, semantic tokens,
///   line markers, structure, type and call hierarchy: the first service that provides one. These keep state between calls (a rename is prepared, then planned), so
///   one owner per language is required, and a second claimant is ignored for that feature.
public struct LanguageServiceRegistry: Sendable {
    public let services: [any LanguageService]
    private let byIdentifier: [String: [any LanguageService]]

    public init(services: [any LanguageService]) {
        self.services = services
        var index: [String: [any LanguageService]] = [:]
        for service in services {
            for identifier in service.languageIdentifiers {
                index[identifier, default: []].append(service)
            }
        }
        byIdentifier = index
    }

    /// The services that claim `languageIdentifier`, in registration order.
    public func services(for languageIdentifier: String?) -> [any LanguageService] {
        guard let languageIdentifier else { return [] }
        return byIdentifier[languageIdentifier] ?? []
    }

    /// The identifiers whose services opted out of `feature`: what the generic providers are told to skip.
    public func identifiers(disabling feature: GenericFeature) -> Set<String> {
        var result: Set<String> = []
        for service in services where service.policy.disabledGenericFeatures.contains(feature) {
            result.formUnion(service.languageIdentifiers)
        }
        return result
    }

    // MARK: Lifecycle

    /// Starts every service, one after the other in registration order.
    public func start(environment: LanguageEnvironment) async {
        for service in services {
            await service.start(environment: environment)
        }
    }

    /// Stops every service, in reverse registration order.
    public func stop() async {
        for service in services.reversed() {
            await service.stop()
        }
    }

    // MARK: Engine inputs

    public var completionProviders: [any CompletionProvider] { services.flatMap(\.providers.completion) }
    public var hoverProviders: [any HoverProvider] { services.flatMap(\.providers.hover) }
    public var diagnosticProviders: [any DiagnosticProvider] { services.flatMap(\.providers.diagnostics) }
    public var navigationProviders: [any NavigationProvider] { services.flatMap(\.providers.navigation) }

    // MARK: Routed single-slot providers

    /// Hand these to `EditorIntelligenceServices`; each routes by the document's language.
    public var formatting: any FormattingProviding { RoutedFormatting(registry: self) }
    public var signatureHelp: any SignatureHelpProviding { RoutedSignatureHelp(registry: self) }
    public var codeActions: any CodeActionProviding { RoutedCodeActions(registry: self) }
    public var rename: any RenameProviding { RoutedRename(registry: self) }
    public var refactoring: any RefactoringProviding { RoutedRefactoring(registry: self) }
    public var codeGeneration: any CodeGenerationProviding { RoutedCodeGeneration(registry: self) }
    public var breadcrumbs: any BreadcrumbProviding { RoutedBreadcrumbs(registry: self) }
    public var inlayHints: any InlayHintProviding { RoutedInlayHints(registry: self) }
    public var codeVision: any CodeVisionProviding { RoutedCodeVision(registry: self) }

    // MARK: Per-language lookups for features the host drives itself

    /// The provider that owns each feature for `languageIdentifier`, or nil when no service claiming
    /// it has one. The host asks (a gutter column is reserved only when line markers exist), then
    /// calls the provider directly.
    public func semanticTokens(for languageIdentifier: String?) -> (any SemanticTokenProviding)? {
        owner(of: languageIdentifier, \.semanticTokens)
    }
    public func lineMarkers(for languageIdentifier: String?) -> (any LineMarkerProviding)? {
        owner(of: languageIdentifier, \.lineMarkers)
    }
    public func structure(for languageIdentifier: String?) -> (any StructureProviding)? {
        owner(of: languageIdentifier, \.structure)
    }
    public func typeHierarchy(for languageIdentifier: String?) -> (any TypeHierarchyProviding)? {
        owner(of: languageIdentifier, \.typeHierarchy)
    }
    public func callHierarchy(for languageIdentifier: String?) -> (any CallHierarchyProviding)? {
        owner(of: languageIdentifier, \.callHierarchy)
    }

    /// The first provider of a feature among the services claiming `languageIdentifier`.
    func owner<Provider>(
        of languageIdentifier: String?, _ keyPath: KeyPath<LanguageProviders, Provider?>
    ) -> Provider? {
        for service in services(for: languageIdentifier) {
            if let provider = service.providers[keyPath: keyPath] { return provider }
        }
        return nil
    }
}

/// Thrown by a routed provider when no service claiming the document's language provides the feature.
/// The controller asks to prepare first (rename, refactor), so reaching this means the document's
/// language changed in between.
public struct LanguageRoutingError: Error, Sendable, CustomStringConvertible {
    public let languageIdentifier: String?
    public let feature: String

    public var description: String {
        "No \(feature) for \(languageIdentifier ?? "a document without a language")"
    }
}
