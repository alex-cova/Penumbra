import EditorIntelligence
import Foundation

public extension EditorIntelligenceServices {
    /// Services whose single-slot providers (formatting, signature help, code actions, rename,
    /// refactoring, code generation, breadcrumbs, inlay hints, code vision) route by the document's
    /// language through `languages`, so one editor can hold several languages' providers.
    ///
    /// A language with no service claiming it gets what a provider with nothing to say gives: no
    /// formatting, no actions, no hints. The controller treats that exactly as it treated a Java-only
    /// provider asked about a non-Java file.
    init(
        languages: LanguageServiceRegistry,
        foldingProvider: (any FoldingProviding)? = nil,
        symbolIndex: SymbolIndex? = nil,
        workspace: Workspace? = nil,
        projectSearchEngine: ProjectSearchEngine? = nil
    ) {
        self.init(
            formattingProvider: languages.formatting,
            signatureHelpProvider: languages.signatureHelp,
            codeActionProvider: languages.codeActions,
            renameProvider: languages.rename,
            refactoringProvider: languages.refactoring,
            codeGenerationProvider: languages.codeGeneration,
            breadcrumbProvider: languages.breadcrumbs,
            inlayHintProvider: languages.inlayHints,
            foldingProvider: foldingProvider,
            codeVisionProvider: languages.codeVision,
            symbolIndex: symbolIndex,
            workspace: workspace,
            projectSearchEngine: projectSearchEngine
        )
    }
}
