import EditorIntelligence
import Foundation

/// Spring's contribution to Java files: diagnostics, navigation from injection points to beans, quick fixes
/// and name completion.
///
/// It is a **semantic-tier** service on purpose. `LanguageServiceRegistry` asks the highest tier first for
/// navigation and lets the highest tier's completion replace lower tiers' items, so a syntactic-tier service
/// would never win a navigation request against Java and its completion items would be dropped when Java's
/// answer arrived (found by `SpringEditorIntegrationTests`). Within a tier services run in registration
/// order, so register it *before* Java's service: its navigation then answers first, and only where Java
/// has nothing better (an injection point's own name); everywhere else it returns `nil`.
public struct SpringLanguageService: LanguageService {
    public let name = "umbra.spring"
    public let languageIdentifiers: Set<String> = ["java"]
    public let providers: LanguageProviders
    public let policy = LanguagePolicy.none
    public var tier: LanguageServiceTier { .semantic }

    public static func make(indexer: SpringWorkspaceIndexer) -> SpringLanguageService {
        SpringLanguageService(providers: LanguageProviders(
            completion: [SpringCompletionProvider(indexer: indexer)],
            diagnostics: [SpringDiagnosticProvider(indexer: indexer)],
            navigation: [SpringNavigationProvider(indexer: indexer), SpringConfigNavigationProvider(indexer: indexer), SpringEndpointNavigationProvider(indexer: indexer)],
            codeActions: SpringCodeActionProvider(indexer: indexer),
            lineMarkers: SpringLineMarkerProvider(indexer: indexer)))
    }

    public var lineMarkerDescriptors: [LineMarkerDescriptor] { SpringMarkers.all }
}

/// Spring Boot configuration files (`application*.properties|yml|yaml`): completion, hover, diagnostics,
/// navigation to and from Java, and key quick fixes. Semantic tier, for the same routing reason as
/// ``SpringLanguageService``.
public struct SpringConfigLanguageService: LanguageService {
    public let name = "umbra.spring-config"
    public let languageIdentifiers: Set<String> = ["properties", "yaml"]
    public let providers: LanguageProviders
    public let policy = LanguagePolicy.none
    public var tier: LanguageServiceTier { .semantic }

    public static func make(indexer: SpringWorkspaceIndexer) -> SpringConfigLanguageService {
        SpringConfigLanguageService(providers: LanguageProviders(
            completion: [SpringConfigCompletionProvider(indexer: indexer)],
            hover: [SpringConfigHoverProvider(indexer: indexer)],
            diagnostics: [SpringConfigDiagnosticProvider(indexer: indexer)],
            navigation: [SpringConfigNavigationProvider(indexer: indexer)],
            codeActions: SpringConfigCodeActionProvider(indexer: indexer)))
    }
}
