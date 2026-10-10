import EditorIntelligence
import Foundation

/// How a host describes one LSP-backed language. The server process stays in the host; this
/// service only answers requests while a connection is present.
public struct LSPLanguageConfiguration: Sendable {
    public var name: String
    public var languageIdentifiers: Set<String>
    /// Maps a document URL and Umbra language identifier to the LSP language id (`typescriptreact` for `.tsx`).
    public var lspLanguageID: @Sendable (URL?, String) -> String
    public var policy: LanguagePolicy
    public var enabledFeatures: Set<LanguageFeature>
    public var diagnosticSource: DiagnosticSourceID

    public static let semanticFeatures: Set<LanguageFeature> = [
        .completion, .hover, .diagnostics, .definition, .references, .implementation, .typeDefinition, .formatting
    ]

    public init(
        name: String,
        languageIdentifiers: Set<String>,
        lspLanguageID: @escaping @Sendable (URL?, String) -> String = { _, identifier in identifier },
        policy: LanguagePolicy = .none,
        enabledFeatures: Set<LanguageFeature> = LSPLanguageConfiguration.semanticFeatures,
        diagnosticSource: DiagnosticSourceID
    ) {
        self.name = name
        self.languageIdentifiers = languageIdentifiers
        self.lspLanguageID = lspLanguageID
        self.policy = policy
        self.enabledFeatures = enabledFeatures
        self.diagnosticSource = diagnosticSource
    }
}

/// The host's current server connection. `current` is read on every request and must not await.
public protocol LSPConnectionProviding: Sendable {
    var current: (any LSPClient)? { get }
    /// Features `initialize` advertised. Nil until that result arrives. A property, so a read through
    /// the existential uses the box's value.
    var supportedFeatures: Set<LanguageFeature>? { get }
}

public extension LSPConnectionProviding {
    var supportedFeatures: Set<LanguageFeature>? { nil }
}

/// A lock-backed connection the host replaces when a server starts, crashes, or restarts.
public final class LSPConnectionBox: LSPConnectionProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var client: (any LSPClient)?
    private var features: Set<LanguageFeature>?

    public init(client: (any LSPClient)? = nil) {
        self.client = client
    }

    public var current: (any LSPClient)? {
        lock.lock()
        defer { lock.unlock() }
        return client
    }

    public var supportedFeatures: Set<LanguageFeature>? {
        lock.lock()
        defer { lock.unlock() }
        return features
    }

    public func setCurrent(_ client: (any LSPClient)?) {
        lock.lock()
        defer { lock.unlock() }
        self.client = client
        if client == nil { features = nil }
    }

    public func setSupportedFeatures(_ features: Set<LanguageFeature>?) {
        lock.lock()
        defer { lock.unlock() }
        self.features = features
    }
}

/// Semantic-tier language service over an LSP connection. While `current` is nil the registry
/// treats every enabled feature as unavailable, so the native tier answers.
public final class LSPLanguageService: LanguageService, @unchecked Sendable {
    public let configuration: LSPLanguageConfiguration
    private let connections: any LSPConnectionProviding
    public let providers: LanguageProviders
    private let publish = LSPPublishBox()

    public init(configuration: LSPLanguageConfiguration, connections: any LSPConnectionProviding) {
        self.configuration = configuration
        self.connections = connections
        let features = configuration.enabledFeatures
        let languages = configuration.languageIdentifiers
        let name = configuration.name
        var completion: [any CompletionProvider] = []
        var hover: [any HoverProvider] = []
        var diagnostics: [any DiagnosticProvider] = []
        var navigation: [any NavigationProvider] = []
        var formatting: (any FormattingProviding)?
        var signatureHelp: (any SignatureHelpProviding)?
        var codeActions: (any CodeActionProviding)?
        var rename: (any RenameProviding)?
        var semanticTokens: (any SemanticTokenProviding)?
        var inlayHints: (any InlayHintProviding)?
        var typeHierarchy: (any TypeHierarchyProviding)?
        var callHierarchy: (any CallHierarchyProviding)?
        if features.contains(.completion) {
            completion = [LSPReadyCompletion(name: name, languages: languages, connections: connections)]
        }
        if features.contains(.hover) {
            hover = [LSPReadyHover(name: name, languages: languages, connections: connections)]
        }
        if features.contains(.diagnostics) {
            diagnostics = [LSPReadyDiagnostics(
                name: name, languages: languages, source: configuration.diagnosticSource,
                connections: connections, publish: publish
            )]
        }
        let navigationFeatures: Set<LanguageFeature> = [.definition, .references, .implementation, .typeDefinition]
        if !features.isDisjoint(with: navigationFeatures) {
            navigation = [LSPReadyNavigation(name: name, languages: languages, connections: connections)]
        }
        if features.contains(.formatting) {
            formatting = LSPReadyFormatting(languages: languages, connections: connections)
        }
        if features.contains(.signatureHelp) {
            signatureHelp = LSPReadySignatureHelp(languages: languages, connections: connections)
        }
        if features.contains(.codeActions) {
            codeActions = LSPReadyCodeActions(languages: languages, connections: connections)
        }
        if features.contains(.rename) {
            rename = LSPReadyRename(languages: languages, connections: connections)
        }
        if features.contains(.semanticTokens) {
            semanticTokens = LSPReadySemanticTokens(languages: languages, connections: connections)
        }
        if features.contains(.inlayHints) {
            inlayHints = LSPReadyInlayHints(languages: languages, connections: connections)
        }
        if features.contains(.typeHierarchy) {
            typeHierarchy = LSPReadyTypeHierarchy(languages: languages, connections: connections)
        }
        if features.contains(.callHierarchy) {
            callHierarchy = LSPReadyCallHierarchy(languages: languages, connections: connections)
        }
        providers = LanguageProviders(
            completion: completion, hover: hover, diagnostics: diagnostics, navigation: navigation,
            formatting: formatting, signatureHelp: signatureHelp, codeActions: codeActions, rename: rename,
            inlayHints: inlayHints, semanticTokens: semanticTokens,
            typeHierarchy: typeHierarchy, callHierarchy: callHierarchy
        )
    }

    public var name: String { configuration.name }
    public var languageIdentifiers: Set<String> { configuration.languageIdentifiers }
    public var policy: LanguagePolicy { configuration.policy }
    public let tier: LanguageServiceTier = .semantic

    public var unavailableFeatures: Set<LanguageFeature> {
        guard connections.current != nil else { return configuration.enabledFeatures }
        guard let supported = connections.supportedFeatures else { return [] }
        return configuration.enabledFeatures.subtracting(supported)
    }

    public func lspLanguageID(for document: Document) -> String {
        configuration.lspLanguageID(document.url, document.languageIdentifier ?? "")
    }

    public func start(environment: LanguageEnvironment) async {
        publish.set(environment.publishDiagnostics)
    }

    public func stop() async {
        publish.set { _ in }
    }
}

private final class LSPPublishBox: @unchecked Sendable {
    private let lock = NSLock()
    private var publish: @Sendable (DiagnosticPublication) -> Void = { _ in }

    func set(_ publish: @escaping @Sendable (DiagnosticPublication) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.publish = publish
    }

    func send(_ publication: DiagnosticPublication) {
        let publish: @Sendable (DiagnosticPublication) -> Void
        lock.lock()
        publish = self.publish
        lock.unlock()
        publish(publication)
    }
}

private struct LSPReadyCompletion: CompletionProvider {
    let name: String
    let languages: Set<String>
    let connections: any LSPConnectionProviding

    func isPrimary(for context: CompletionContext) -> Bool {
        connections.current != nil && languages.contains(context.document.languageIdentifier ?? "")
    }

    func provide(context: CompletionContext) async -> [CompletionItem] {
        guard isPrimary(for: context), let client = connections.current else { return [] }
        return await LSPCompletionProvider(client: client).provide(context: context)
    }
}

private struct LSPReadyHover: HoverProvider {
    let name: String
    let languages: Set<String>
    let connections: any LSPConnectionProviding

    func provide(context: HoverContext) async -> HoverResult? {
        guard languages.contains(context.document.languageIdentifier ?? ""), let client = connections.current else { return nil }
        return await LSPHoverProvider(client: client).provide(context: context)
    }
}

private struct LSPReadyDiagnostics: DiagnosticProvider {
    let name: String
    let languages: Set<String>
    let source: DiagnosticSourceID
    let connections: any LSPConnectionProviding
    let publish: LSPPublishBox

    func diagnostics(for document: Document) async -> [Diagnostic] {
        guard languages.contains(document.languageIdentifier ?? ""), let client = connections.current else { return [] }
        let items = (try? await client.requestDiagnostics(for: document)) ?? []
        let mapped = items.map { diagnostic(from: $0, source: source.rawValue) }
        if let url = document.url {
            publish.send(DiagnosticPublication(
                source: source, url: url, documentVersion: document.version, diagnostics: mapped
            ))
        }
        return mapped
    }
}

private struct LSPReadyNavigation: NavigationProvider {
    let name: String
    let languages: Set<String>
    let connections: any LSPConnectionProviding

    func isPrimary(for context: NavigationContext) -> Bool {
        connections.current != nil && languages.contains(context.document.languageIdentifier ?? "")
    }

    func provide(context: NavigationContext) async -> NavigationResult? {
        guard isPrimary(for: context), let client = connections.current else { return nil }
        switch context.kind {
        case .definition:
            return await LSPDefinitionProvider(client: client).provide(context: context)
        case .references:
            return await LSPReferencesProvider(client: client).provide(context: context)
        case .implementation:
            return await LSPImplementationProvider(client: client).provide(context: context)
        case .typeDefinition:
            return await LSPTypeDefinitionProvider(client: client).provide(context: context)
        case .superMethod:
            return nil
        }
    }
}

private struct LSPReadyFormatting: FormattingProviding {
    let languages: Set<String>
    let connections: any LSPConnectionProviding

    func supportsFormatting(_ document: Document) -> Bool {
        connections.current != nil && languages.contains(document.languageIdentifier ?? "")
    }

    func formatDocument(_ document: Document) async -> [TextEdit] {
        guard supportsFormatting(document), let client = connections.current else { return [] }
        return await LSPFormattingProvider(client: client).formatDocument(document)
    }

    func formatSelection(in document: Document, range: EditorIntelligence.TextRange) async -> [TextEdit] {
        guard supportsFormatting(document), let client = connections.current else { return [] }
        return await LSPFormattingProvider(client: client).formatSelection(in: document, range: range)
    }
}
