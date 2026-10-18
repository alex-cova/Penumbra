import Foundation

/// Perform syntax highlighting with Tree-sitter.
///
/// Use this language mode to perform syntax highlighting using [Tree-sitter](https://tree-sitter.github.io/tree-sitter/).
///
/// Refer to <doc:AddingATreeSitterLanguage> for more information on adding a Tree-sitter language to your project.
public final class TreeSitterLanguageMode {
    /// Tree-sitter language to use with the language mode.
    public let language: TreeSitterLanguage
    /// RefeAn object that can provide embedded languages on demand. A strong reference will be stored to the language provider.
    public let languageProvider: TreeSitterLanguageProvider?

    /// Temporary language injections (the Inject-language action) for the document. A strong
    /// reference is stored. `nil` (the default) keeps comment-discovered injections working while
    /// disabling temporary ones, so existing call sites compile unchanged.
    public let manualInjectionProvider: ManualInjectionProviding?

    /// Create a language mode for the specified Tree-sitter language.
    /// - Parameters:
    ///   - language: Tree-sitter language to use with the language mode.
    ///   - languageProvider: An object that can provide embedded languages on demand. A strong reference will be stored to the language provider.
    ///   - manualInjectionProvider: Temporary language injections for the document. A strong reference will be stored to the provider.
    public init(language: TreeSitterLanguage,
                languageProvider: TreeSitterLanguageProvider? = nil,
                manualInjectionProvider: ManualInjectionProviding? = nil) {
        self.language = language
        self.languageProvider = languageProvider
        self.manualInjectionProvider = manualInjectionProvider
    }
}

extension TreeSitterLanguageMode: LanguageMode {
    func makeInternalLanguageMode(stringView: StringView, lineManager: LineManager) -> InternalLanguageMode {
        TreeSitterInternalLanguageMode(
            language: language.internalLanguage,
            languageProvider: languageProvider,
            stringView: stringView,
            lineManager: lineManager,
            manualInjectionProvider: manualInjectionProvider)
    }
}
