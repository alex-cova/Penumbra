import Foundation

/// The language services of one editor, with the lookups the engines and the controller need.
///
/// Immutable after construction, so it is cheap to copy into providers and safe to read from any
/// thread. Routing is a dictionary lookup by language identifier: nothing here scans services per
/// keystroke.
///
/// **Combining services that claim one language.** Services are ordered by tier, highest first, and
/// otherwise by registration order. A service whose ``LanguageService/unavailableFeatures`` contains
/// the feature is skipped.
/// - completion, hover and navigation: one tiered provider per language. Completion yields the
///   syntactic batch first, then replaces it with the semantic batch. Hover and navigation ask the
///   top ready tier and fall back when it returns nil.
/// - diagnostics: one tiered provider per language that keeps every ready tier. The diagnostic
///   engine deduplicates.
/// - code actions: every ready service's actions, concatenated;
/// - formatting: the first ready service whose provider ``FormattingProviding/supportsFormatting(_:)``;
/// - signature help: the first non-nil answer from a ready service;
/// - rename, refactoring, code generation, breadcrumbs, inlay hints, code vision, semantic tokens,
///   line markers, structure, type and call hierarchy: the first ready service that provides one.
///   These keep state between calls (a rename is prepared, then planned), so one owner per language
///   is required.
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

    /// The services that claim `languageIdentifier`, highest tier first and otherwise in
    /// registration order. `sorted` is stable, so two syntactic services keep the order they were
    /// registered in.
    public func services(for languageIdentifier: String?) -> [any LanguageService] {
        guard let languageIdentifier else { return [] }
        return (byIdentifier[languageIdentifier] ?? []).sorted { $0.tier > $1.tier }
    }

    /// The highest ready service that provides each feature for `languageIdentifier`.
    public func capabilities(for languageIdentifier: String) -> LanguageCapabilityReport {
        var features: [LanguageFeature: LanguageFeatureOwner] = [:]
        for feature in LanguageFeature.allCases {
            guard let service = services(for: languageIdentifier).first(where: { service in
                !service.unavailableFeatures.contains(feature) && provides(feature, service.providers)
            }) else { continue }
            let fidelity = service.fidelity(of: feature) ?? (service.tier == .semantic ? .semantic : .syntactic)
            features[feature] = LanguageFeatureOwner(service: service.name, fidelity: fidelity)
        }
        return LanguageCapabilityReport(features: features)
    }

    private func provides(_ feature: LanguageFeature, _ providers: LanguageProviders) -> Bool {
        switch feature {
        case .completion: return !providers.completion.isEmpty
        case .hover: return !providers.hover.isEmpty
        case .signatureHelp: return providers.signatureHelp != nil
        case .definition, .implementation, .typeDefinition, .references, .superMethod:
            return !providers.navigation.isEmpty
        case .rename: return providers.rename != nil
        case .refactoring: return providers.refactoring != nil
        case .codeActions: return providers.codeActions != nil
        case .formatting: return providers.formatting != nil
        case .diagnostics: return !providers.diagnostics.isEmpty
        case .semanticTokens: return providers.semanticTokens != nil
        case .inlayHints: return providers.inlayHints != nil
        case .codeVision: return providers.codeVision != nil
        case .structure: return providers.structure != nil
        case .breadcrumbs: return providers.breadcrumbs != nil
        case .lineMarkers: return providers.lineMarkers != nil
        case .typeHierarchy: return providers.typeHierarchy != nil
        case .callHierarchy: return providers.callHierarchy != nil
        case .methodHierarchy: return providers.methodHierarchy != nil
        case .codeGeneration: return providers.codeGeneration != nil
        case .symbolReference: return providers.symbolReference != nil
        }
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

    /// Tells every service the folder changed, one after the other in registration order, before this
    /// returns (see ``LanguageService/projectDidChange(root:)``).
    @MainActor
    public func projectDidChange(root: URL?) {
        for service in services {
            service.projectDidChange(root: root)
        }
    }

    /// Tells every service that files changed on disk, in registration order.
    @MainActor
    public func filesDidChange(_ urls: [URL]) {
        for service in services {
            service.filesDidChange(urls)
        }
    }

    /// Tells every service that these documents were saved, in registration order.
    @MainActor
    public func documentsDidSave(_ urls: [URL]) {
        for service in services {
            service.documentsDidSave(urls)
        }
    }

    /// Stops every service, in reverse registration order.
    public func stop() async {
        for service in services.reversed() {
            await service.stop()
        }
    }

    // MARK: Engine inputs

    /// One provider per language that has completion. A later snapshot from the same provider
    /// replaces the earlier one inside ``CompletionEngine``.
    public var completionProviders: [any CompletionProvider] {
        tiered(include: { !$0.completion.isEmpty }) { language, services in
            TieredCompletionProvider(name: language, languageIdentifier: language, services: services)
        }
    }

    /// One provider per language. The top ready tier answers; a nil result falls through.
    public var hoverProviders: [any HoverProvider] {
        tiered(include: { !$0.hover.isEmpty }) { language, services in
            TieredHoverProvider(name: language, languageIdentifier: language, services: services)
        }
    }

    /// One provider per language. Every ready tier contributes; the engine deduplicates.
    public var diagnosticProviders: [any DiagnosticProvider] {
        tiered(include: { !$0.diagnostics.isEmpty }) { language, services in
            TieredDiagnosticProvider(name: language, languageIdentifier: language, services: services)
        }
    }

    /// One provider per language. The top ready tier answers; a nil result falls through.
    public var navigationProviders: [any NavigationProvider] {
        tiered(include: { !$0.navigation.isEmpty }) { language, services in
            TieredNavigationProvider(name: language, languageIdentifier: language, services: services)
        }
    }

    /// Languages in the order their services were registered. Identifiers inside one service are
    /// sorted so a `Set` cannot change the engine's provider order between runs.
    private var languageOrder: [String] {
        var seen = Set<String>()
        var order: [String] = []
        for service in services {
            for identifier in service.languageIdentifiers.sorted() where seen.insert(identifier).inserted {
                order.append(identifier)
            }
        }
        return order
    }

    private func tiered<Provider>(
        include: (LanguageProviders) -> Bool,
        make: (String, [any LanguageService]) -> Provider
    ) -> [Provider] {
        languageOrder.compactMap { identifier in
            let claiming = services.filter {
                $0.languageIdentifiers.contains(identifier) && include($0.providers)
            }
            guard !claiming.isEmpty else { return nil }
            return make(identifier, claiming)
        }
    }

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
    public var symbolReference: any SymbolReferenceProviding { RoutedSymbolReference(registry: self) }

    // MARK: Per-language lookups for features the host drives itself

    /// The provider that owns each feature for `languageIdentifier`, or nil when no service claiming
    /// it has one. The host asks (a gutter column is reserved only when line markers exist), then
    /// calls the provider directly.
    public func semanticTokens(for languageIdentifier: String?) -> (any SemanticTokenProviding)? {
        owner(of: languageIdentifier, feature: .semanticTokens, \.semanticTokens)
    }
    public func lineMarkers(for languageIdentifier: String?) -> (any LineMarkerProviding)? {
        owner(of: languageIdentifier, feature: .lineMarkers, \.lineMarkers)
    }
    public func structure(for languageIdentifier: String?) -> (any StructureProviding)? {
        owner(of: languageIdentifier, feature: .structure, \.structure)
    }
    public func typeHierarchy(for languageIdentifier: String?) -> (any TypeHierarchyProviding)? {
        owner(of: languageIdentifier, feature: .typeHierarchy, \.typeHierarchy)
    }
    public func callHierarchy(for languageIdentifier: String?) -> (any CallHierarchyProviding)? {
        owner(of: languageIdentifier, feature: .callHierarchy, \.callHierarchy)
    }
    public func methodHierarchy(for languageIdentifier: String?) -> (any MethodHierarchyProviding)? {
        owner(of: languageIdentifier, feature: .methodHierarchy, \.methodHierarchy)
    }

    /// Services claiming `languageIdentifier` that are ready for `feature`, highest tier first.
    func readyServices(for languageIdentifier: String?, feature: LanguageFeature) -> [any LanguageService] {
        services(for: languageIdentifier).filter { !$0.unavailableFeatures.contains(feature) }
    }

    /// The first ready provider of a feature among the services claiming `languageIdentifier`.
    func owner<Provider>(
        of languageIdentifier: String?,
        feature: LanguageFeature,
        _ keyPath: KeyPath<LanguageProviders, Provider?>
    ) -> Provider? {
        for service in readyServices(for: languageIdentifier, feature: feature) {
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
