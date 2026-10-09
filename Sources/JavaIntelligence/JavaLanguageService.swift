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
}
