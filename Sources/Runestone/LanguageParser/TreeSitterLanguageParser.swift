import Foundation
import TreeSitter
import EditorIntelligence

/// Tree-sitter-based `LanguageParser` that produces a `TreeSitterSyntaxTree`.
///
/// The parser is an actor because the underlying `TreeSitterParser` is not thread-safe. Each
/// document is fully parsed on demand; incremental tree parsing can be added in a later phase.
public actor TreeSitterLanguageParser: LanguageParser {
    private let languageMode: TreeSitterLanguageMode
    private let parser: TreeSitterParser
    private let languageConfigurations: LanguageConfigurationRegistry

    public init(
        language: TreeSitterLanguage,
        languageConfigurations: LanguageConfigurationRegistry = .builtIns
    ) {
        let mode = TreeSitterLanguageMode(language: language)
        self.languageMode = mode
        self.languageConfigurations = languageConfigurations
        self.parser = TreeSitterParser(encoding: .treeSitterUTF16)
        self.parser.language = mode.language.languagePointer
    }

    public init(
        languageMode: TreeSitterLanguageMode,
        languageConfigurations: LanguageConfigurationRegistry = .builtIns
    ) {
        self.languageMode = languageMode
        self.languageConfigurations = languageConfigurations
        self.parser = TreeSitterParser(encoding: .treeSitterUTF16)
        self.parser.language = languageMode.language.languagePointer
    }

    public func parse(document: Document) async -> SyntaxTree {
        let text = document.contentSnapshot.text ?? ""
        let tree = parser.parse(text as NSString)
        let configuration = languageConfigurations.configuration(for: document.languageIdentifier)
        return TreeSitterSyntaxTree(
            tree: tree,
            documentID: document.id,
            text: text,
            languageConfiguration: configuration
        )
    }
}
