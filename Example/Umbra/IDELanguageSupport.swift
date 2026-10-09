import Penumbra
import PenumbraLanguages

enum IDELanguageSupport {
    /// One entry in the user-facing "Set Syntax" picker (status bar menu, View > Syntax).
    struct SyntaxOption: Identifiable {
        /// `nil` means plain text — no `TreeSitterLanguage`, no highlighting.
        let id: String?
        let displayName: String
    }

    /// Every syntax the user can pick from ``IDEWorkspace/setLanguage(identifier:in:)``, in the
    /// order Sublime Text-style syntax menus list them: Plain Text first, then alphabetical. Built from
    /// the selectable ``LanguageDefinition``s in ``LanguageDefinitionRegistry/shared``, so a language
    /// registered there shows up here without an edit. Read on each use, not cached.
    static var selectableSyntaxes: [SyntaxOption] {
        [SyntaxOption(id: nil, displayName: "Plain Text")]
            + LanguageDefinitionRegistry.shared.selectableDefinitions.map {
                SyntaxOption(id: $0.id, displayName: $0.displayName)
            }
    }

    /// Display name for `identifier`: its definition's name, falling back to a capitalized identifier
    /// for one nobody defined (e.g. a language a host app used without registering it).
    static func displayName(forIdentifier identifier: String?) -> String {
        guard let identifier else { return "Plain Text" }
        return LanguageDefinitionRegistry.shared.definition(forIdentifier: identifier)?.displayName
            ?? identifier.capitalized
    }

    /// True when the document's language is inferred from its path and must not be overridden
    /// (e.g. a `.java` file). Untitled buffers and files with unrecognized extensions stay editable.
    static func isLanguageLocked(for document: WorkbenchDocument) -> Bool {
        guard document.contentKind == .text, let url = document.url else { return false }
        return LanguageIdentifier.identifier(for: url) != nil
    }

    static func language(forIdentifier identifier: String?) -> TreeSitterLanguage? {
        BundledLanguages.language(forIdentifier: identifier)
    }

    static func languageResolver(snapshot: WorkbenchDocumentSnapshot) -> TreeSitterLanguage? {
        language(forIdentifier: snapshot.languageIdentifier)
    }

    static func fileBackedLanguageResolver(document: WorkbenchDocument) -> TreeSitterLanguage? {
        language(forIdentifier: document.languageIdentifier)
    }
}
