import Runestone
import RunestoneMarkdownLanguage

enum IDELanguageSupport {
    private static let languageCache = TreeSitterLanguageCache<String>()

    static func language(forIdentifier identifier: String?) -> TreeSitterLanguage? {
        guard let identifier else { return nil }
        return languageCache.language(for: identifier) {
            if identifier == "markdown" {
                return .markdown
            }
            return TreeSitterLanguage.bundled(forIdentifier: identifier)
        }
    }

    static func languageResolver(snapshot: WorkbenchDocumentSnapshot) -> TreeSitterLanguage? {
        language(forIdentifier: snapshot.languageIdentifier)
    }

    static func fileBackedLanguageResolver(document: WorkbenchDocument) -> TreeSitterLanguage? {
        language(forIdentifier: document.languageIdentifier)
    }
}
