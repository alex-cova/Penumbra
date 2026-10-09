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
    private let callHierarchy: JavaCallHierarchyProvider

    public init(
        completion: JavaCompletionProvider,
        hover: JavaHoverProvider,
        compilerDiagnostics: JavaCompilerDiagnosticsService,
        inspections: JavaInspectionService,
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
        callHierarchy: JavaCallHierarchyProvider
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
        providers = LanguageProviders(
            completion: [completion],
            hover: [hover],
            diagnostics: [compilerDiagnostics, inspections],
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
            callHierarchy: callHierarchy
        )
    }

    // MARK: - Lifecycle

    public func start(environment: LanguageEnvironment) async {
        // Every provider that reads another file reads it through the open buffer first, so a rename,
        // a hierarchy or a hover sees unsaved edits.
        let openBuffer: @Sendable (URL) async -> String? = environment.openBufferText
        await navigation.setOpenBufferLookup(openBuffer)
        await hover.setOpenBufferLookup(openBuffer)
        await findUsages.setOpenBufferLookup(openBuffer)
        await rename.setOpenBufferLookup(openBuffer)
        await refactoring.setOpenBufferLookup(openBuffer)
        await inlayHints.setOpenBufferLookup(openBuffer)
        await lineMarkers.setOpenBufferLookup(openBuffer)
        await typeHierarchy.setOpenBufferLookup(openBuffer)
        await callHierarchy.setOpenBufferLookup(openBuffer)
        await formatting.setIndentUnitProvider(environment.indentUnit)
        // Decompiling class files needs the user's agreement; only a manual navigation may ask.
        await navigation.setDecompilerConsent(
            accepted: await environment.hasConsent(.javaDecompiler),
            request: { await environment.requestConsent(.javaDecompiler) }
        )
    }

    public func stop() async {
        await navigation.setOpenBufferLookup(nil)
        await hover.setOpenBufferLookup(nil)
        await findUsages.setOpenBufferLookup(nil)
        await rename.setOpenBufferLookup(nil)
        await refactoring.setOpenBufferLookup(nil)
        await inlayHints.setOpenBufferLookup(nil)
        await lineMarkers.setOpenBufferLookup(nil)
        await typeHierarchy.setOpenBufferLookup(nil)
        await callHierarchy.setOpenBufferLookup(nil)
        await formatting.setIndentUnitProvider(nil)
        await navigation.setDecompilerConsent(accepted: false, request: nil)
    }
}

public extension ConsentTopic {
    /// Decompiling a dependency's class files when no source is attached (see `JavaDecompilerAgreement`).
    static let javaDecompiler: ConsentTopic = "java.decompiler"
}
