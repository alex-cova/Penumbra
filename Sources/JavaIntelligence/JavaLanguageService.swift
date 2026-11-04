import EditorIntelligence
import Foundation

/// Everything Java contributes to an editor, as one ``LanguageService``.
///
/// It bundles provider instances the host constructed: they share an index, index paths and a Gradle
/// scope, and the host (Umbra's `IDEJavaSupport`) owns their lifecycle. What belongs here is what
/// "Java" means to the router: the identifier it answers for, which providers feed which engine
/// (the order within an engine is the order given here), and the generic name-based features it
/// replaces. The providers still guard on `languageIdentifier == "java"` themselves.
public struct JavaLanguageService: LanguageService {
    public let name = "java"
    public let languageIdentifiers: Set<String> = ["java"]
    public let tier: LanguageServiceTier = .semantic
    /// Java's own completion, hover and navigation answer better than the name-based ones, and the
    /// built-in snippets are JavaScript-flavored. Duplicate-symbol warnings stay on.
    public let policy = LanguagePolicy(disabling: [.snippets, .symbolHover, .symbolNavigation])
    public let providers: LanguageProviders

    // The providers `start(environment:)` configures. The rest need nothing from the host.
    private let hover: JavaHoverProvider
    private let navigation: JavaGoToDefinitionProvider
    private let findUsages: JavaFindUsagesProvider
    private let formatting: JavaFormattingProvider
    private let rename: JavaRenameProvider
    private let refactoring: JavaRefactoringProvider
    private let inlayHints: JavaInlayHintProvider
    private let lineMarkers: JavaLineMarkerProvider
    private let typeHierarchy: JavaTypeHierarchyProvider
    private let callHierarchy: any CallHierarchyProviding & JavaOpenBufferReading

    public init(
        completion: JavaCompletionProvider,
        hover: JavaHoverProvider,
        compilerDiagnostics: JavaCompilerDiagnosticsService,
        inspections: JavaInspectionService,
        buildDiagnostics: JavaBuildDiagnosticsService? = nil,
        navigation: JavaGoToDefinitionProvider,
        findUsages: JavaFindUsagesProvider,
        formatting: JavaFormattingProvider,
        codeActions: JavaCodeActionProvider,
        rename: JavaRenameProvider,
        refactoring: JavaRefactoringProvider,
        codeGeneration: JavaCodeGenerationProvider = JavaCodeGenerationProvider(),
        breadcrumbs: JavaBreadcrumbProvider,
        inlayHints: JavaInlayHintProvider,
        codeVision: JavaCodeVisionProvider,
        semanticTokens: JavaSemanticTokenProvider,
        lineMarkers: JavaLineMarkerProvider,
        structure: JavaStructureProvider,
        typeHierarchy: JavaTypeHierarchyProvider,
        callHierarchy: any CallHierarchyProviding & JavaOpenBufferReading,
        symbolReference: JavaSymbolReferenceProvider? = nil
    ) {
        self.hover = hover
        self.navigation = navigation
        self.findUsages = findUsages
        self.formatting = formatting
        self.rename = rename
        self.refactoring = refactoring
        self.inlayHints = inlayHints
        self.lineMarkers = lineMarkers
        self.typeHierarchy = typeHierarchy
        self.callHierarchy = callHierarchy
        let syntax = JavaSyntaxDiagnostics.provider(cache: inspections.documentParseCache)
        var diagnosticsProviders: [any DiagnosticProvider] = [
            JavaSyntaxAwareDiagnostics(syntax: syntax, compiler: compilerDiagnostics, inspections: inspections),
        ]
        // Last-build rows for open files, so a compile also paints squiggles and the error
        // stripe -- not just the Problems list. The engine deduplicates rows live checks restate.
        if let buildDiagnostics { diagnosticsProviders.append(buildDiagnostics) }
        providers = LanguageProviders(
            completion: [completion],
            hover: [hover],
            diagnostics: diagnosticsProviders,
            navigation: [navigation, findUsages],
            formatting: formatting,
            // `JavaCompletionProvider` doubles as parameter info.
            signatureHelp: completion,
            codeActions: codeActions,
            rename: rename,
            refactoring: refactoring,
            codeGeneration: codeGeneration,
            breadcrumbs: breadcrumbs,
            inlayHints: inlayHints,
            codeVision: codeVision,
            semanticTokens: semanticTokens,
            lineMarkers: lineMarkers,
            structure: structure,
            typeHierarchy: typeHierarchy,
            callHierarchy: callHierarchy,
            methodHierarchy: JavaMethodHierarchyProvider(typeHierarchy: typeHierarchy),
            symbolReference: symbolReference
        )
    }

    // MARK: - Lifecycle

    /// The providers that read other files, which read them through the open buffer first so a
    /// rename, a hierarchy or a hover sees unsaved edits. The registered call hierarchy is the bytecode
    /// wrapper (which falls back to the source provider for every non-class file); the buffer reaches
    /// the source index behind it through its own `setOpenBufferLookup`.
    private var openBufferReaders: [any JavaOpenBufferReading] {
        [navigation, hover, findUsages, rename, refactoring, inlayHints, lineMarkers, typeHierarchy, callHierarchy]
    }

    public func start(environment: LanguageEnvironment) async {
        let openBuffer: @Sendable (URL) async -> String? = environment.openBufferText
        for reader in openBufferReaders { await reader.setOpenBufferLookup(openBuffer) }
        await formatting.setIndentUnitProvider(environment.indentUnit)
        // Decompiling class files needs the user's agreement; only a manual navigation may ask.
        await navigation.setDecompilerConsent(
            accepted: await environment.hasConsent(.javaDecompiler),
            request: { await environment.requestConsent(.javaDecompiler) }
        )
    }

    public func stop() async {
        for reader in openBufferReaders { await reader.setOpenBufferLookup(nil) }
        await formatting.setIndentUnitProvider(nil)
        await navigation.setDecompilerConsent(accepted: false, request: nil)
    }
}

/// A Java provider that is handed the window's open-buffer reader when the service starts and drops it
/// when the service stops (see ``JavaLanguageService``).
public protocol JavaOpenBufferReading: Sendable {
    func setOpenBufferLookup(_ lookup: (@Sendable (URL) async -> String?)?) async
}

extension JavaHoverProvider: JavaOpenBufferReading {}
extension JavaGoToDefinitionProvider: JavaOpenBufferReading {}
extension JavaFindUsagesProvider: JavaOpenBufferReading {}
extension JavaRenameProvider: JavaOpenBufferReading {}
extension JavaRefactoringProvider: JavaOpenBufferReading {}
extension JavaInlayHintProvider: JavaOpenBufferReading {}
extension JavaLineMarkerProvider: JavaOpenBufferReading {}
extension JavaTypeHierarchyProvider: JavaOpenBufferReading {}
extension JavaCallHierarchyProvider: JavaOpenBufferReading {}
extension JavaBytecodeCallHierarchyProvider: JavaOpenBufferReading {}

public extension ConsentTopic {
    /// Decompiling a dependency's class files when no source is attached (see `JavaDecompilerAgreement`).
    static let javaDecompiler: ConsentTopic = "java.decompiler"
}
